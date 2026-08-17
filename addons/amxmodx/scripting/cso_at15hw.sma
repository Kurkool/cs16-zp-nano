#include <amxmodx>
#include <engine>
#include <fakemeta>
#include <fun>
#include <hamsandwich>
#include <xs>
#include <cstrike>
#include <zombieplague>
/*
	reapi is a HARD dependency from here on, the same way zp_round_rules depends on
	it - there is no #if defined guard, so this plugin will not load without the
	module. modules.ini has reapi enabled.

	It is here for one reason: bullet spread. CS computes the cone inside each
	weapon's own fire code from m_flAccuracy and there is no way to reach the number
	from outside, which is why clamping m_flAccuracy was the only lever available
	and why it could never be shown to move anything. ReGameDLL exposes the call
	that actually uses the cone, so the cone itself becomes editable.
*/
#include <reapi>

#define ENG_NULLENT			-1
#define EV_INT_WEAPONKEY	EV_INT_impulse
#define aks74u_WEAPONKEY 	899

/*
	Identity lives on the weapon, not on the player.

	The pack held it in g_has_aks74u[] and stamped pev_impulse only while the gun
	was on the ground, clearing the key again the moment somebody picked it up. So
	a held weapon carried no mark at all and every stat - the damage multiplier,
	the kickback table, the 42-round clip, the spread scale - keyed off a per-player
	bool instead. Any path that lost the weapon without producing a galil weaponbox
	left that bool set, and the next plain galil the player touched inherited the
	whole gun.

	The key is now set when the weapon is handed over and never cleared, so the test
	is a property of the entity in front of us. Hold a galil and you get galil stats;
	hold this and you get its stats. Same rule the Angelic and the Iron Beast use.
*/
#define Is_AT15(%0)  (pev_valid(%0) && pev(%0, pev_impulse) == aks74u_WEAPONKEY)
#define MAX_PLAYERS  		32
#define IsValidUser(%1) (1 <= %1 <= g_MaxPlayers)

const USE_STOPPED = 0
const OFFSET_ACTIVE_ITEM = 373
const OFFSET_WEAPONOWNER = 41
const OFFSET_LINUX = 5
const OFFSET_LINUX_WEAPONS = 4

#define WEAP_LINUX_XTRA_OFF		4
#define m_fKnown					44
#define m_flNextPrimaryAttack 		46
#define m_flTimeWeaponIdle			48
#define m_iClip					51
#define m_fInReload				54
/*
	Bullet grouping, which is NOT the kick table.

	punchangle moves the camera; this moves the bullets. m_flAccuracy lives on the
	weapon entity, grows while the trigger is held, and the weapon's own fire code
	multiplies it into the spread cone - so a gun can sit perfectly still on screen
	and still throw its rounds all over the target, which is exactly what this one
	did once the recoil was tamed.

	71 and not 62: docs/M4A1-S_stats.md records that the two pdata tables on this
	machine disagree about where this member lives, and 71 is the one the working
	plugins use. This file is on that same table - its m_iClip 51 and m_fInReload
	54 match the Angelic's OFF_WEAPON_CLIP and OFF_WEAPON_IN_RELOAD exactly.
*/
#define m_flAccuracy				71
#define PLAYER_LINUX_XTRA_OFF	5
#define m_flNextAttack				83

// Measured off v_at15hw.mdl: sequence 1 "reload" is 97 frames at 57 fps = 1.702s.
// The pack shipped 2.4 here, which left the player locked out for 0.7s after the
// hands had already finished - the reverse of the Angelic's problem, where the
// animation outlasted the time and got cut off. See tools/check_reload_timing.ps1.
#define aks74u_RELOAD_TIME	1.7
#define aks74u_RELOAD		1
#define aks74u_DRAW		2
#define aks74u_SHOOT		3

#define write_coord_f(%1)	engfunc(EngFunc_WriteCoord,%1)

new const Fire_Sounds[][] = { "YouTuber/at15hw-1.wav" }

new aks74u_V_MODEL[64] = "models/YouTuber/v_at15hw.mdl"
new aks74u_P_MODEL[64] = "models/YouTuber/p_at15hw.mdl"
new aks74u_W_MODEL[64] = "models/YouTuber/w_at15hw.mdl"

new const GUNSHOT_DECALS[] = { 41, 42, 43, 44, 45 }

/*
	Recoil.

	The pack shipped only zp_aks74u_recoil, which scales whatever kick the galil
	happened to apply. That cannot make a gun feel planted: scaling the per-shot
	kick scales the climb with it, so a long burst still walks off the target,
	just more slowly.

	What makes the Angelic and the Iron Beast sit still is the CAP. Their table
	is CrossFire's [M4A1_S_PRISMBEAST] block, transcribed in docs/M4A1-S_stats.md,
	and its trick is a per-shot kick in the normal range against an accumulation
	ceiling of 0.8 up / 0.5 lateral where stock CS runs about 3.5 / 2.5. The gun
	takes a small fixed offset on the first round and then stays there.

	There is no CrossFire table for the AT15 to copy - the Yasou 3.0 build ships
	its icons but no [AT15_*] section in SUIC_WEAPON_MAIN.RC, checked - so this
	borrows the Prism Beast numbers and scales them with zp_aks74u_kick_scale,
	default 0.55 - a 40% reduction on the first pass, then another 5 off.

	The scale deliberately does NOT touch column 6. That one is direction_change,
	which the engine uses as !RANDOM_LONG(0, n) - a probability of flipping the
	lateral direction, not a magnitude. Scaling it would make the gun wander more
	rather than kick less.
*/
#define KB_STAND 0
#define KB_DUCK  1
#define KB_WALK  2
#define KB_AIR   3

new const Float:KICKBACK[4][7] = {
	// up_base, lat_base, up_mod, lat_mod, up_max, lat_max, dir_change
	{ 0.8, 0.30, 0.11, 0.03, 0.8, 0.5, 3.0 },   // standing
	{ 0.8, 0.25, 0.02, 0.03, 0.8, 0.5, 3.0 },   // ducking
	{ 0.8, 0.50, 0.50, 0.05, 0.8, 0.5, 3.0 },   // walking
	{ 3.5, 0.00, 0.50, 0.00, 0.3, 0.0, 0.0 }    // airborne
}

new g_iShotsFired[33], g_iKickDir[33]
new Float:g_fLastShot[33]
new cvar_recoilmode_aks74u, cvar_kickscale_aks74u

/*
	The accuracy question, and how it ended.

	Clamping m_flAccuracy was the only lever CS appeared to offer, and it never
	worked. It was measured on 2026-08-17 from the Angelic side: the cone ReGameDLL
	hands FireBullets3 still climbs 0.004 -> 0.020 across a burst with the value
	forced to 0 on every shot, which is m_flAccuracy growing as though nothing had
	been written. Offset 71 is the right slot - the write lands - but something
	recomputes it between the write and the shot.

	The clamp, its cvar and the trace built to answer this are all gone. Spread is
	zp_aks74u_spread_scale now, which was measured working: 2.46 units of group at
	scale 0 against 5.36 at 1.0, the remainder at 0 being camera kick rather than
	cone.

	Worth keeping in mind: nobody could have caught this earlier, because the bullet
	holes were being drawn straight down v_angle and never showed the spread they
	were supposed to be flattering.
*/
new cvar_spreadscale_aks74u

new cvar_dmg_aks74u, cvar_recoil_aks74u, g_itemid_aks74u, cvar_clip_aks74u, cvar_spd_aks74u, cvar_aks74u_ammo
new g_MaxPlayers, g_orig_event_aks74u, g_IsInPrimaryAttack
new Float:cl_pushangle[MAX_PLAYERS + 1][3], m_iBlood[2]
new g_clip_ammo[33], g_aks74u_TmpClip[33], oldweap[33]

// true only for the window inside the original PrimaryAttack where the bullet
// traces run. The per-bullet hooks read this instead of looking the weapon up
// again - the attack hook is handed the entity, so it can test it once and cache.
new bool:g_bFiringAT15[33]
new gmsgWeaponList

const PRIMARY_WEAPONS_BIT_SUM = 
(1<<CSW_SCOUT)|(1<<CSW_XM1014)|(1<<CSW_MAC10)|(1<<CSW_AUG)|(1<<CSW_UMP45)|(1<<CSW_SG550)|(1<<CSW_GALIL)|(1<<CSW_FAMAS)|(1<<CSW_AWP)|(1<<
CSW_MP5NAVY)|(1<<CSW_M249)|(1<<CSW_M3)|(1<<CSW_M4A1)|(1<<CSW_TMP)|(1<<CSW_G3SG1)|(1<<CSW_SG552)|(1<<CSW_AK47)|(1<<CSW_P90)
new const WEAPONENTNAMES[][] = { "", "weapon_p228", "", "weapon_scout", "weapon_hegrenade", "weapon_xm1014", "weapon_c4", "weapon_mac10",
			"weapon_aug", "weapon_smokegrenade", "weapon_elite", "weapon_fiveseven", "weapon_ump45", "weapon_sg550",
			"weapon_galil", "weapon_famas", "weapon_usp", "weapon_glock18", "weapon_awp", "weapon_mp5navy", "weapon_m249",
			"weapon_m3", "weapon_m4a1", "weapon_tmp", "weapon_g3sg1", "weapon_flashbang", "weapon_deagle", "weapon_sg552",
			"weapon_ak47", "weapon_knife", "weapon_p90" }

public plugin_init()
{
	// The pack is an AKS74U plugin with the AT15 models dropped onto it, so every
	// internal name below still says aks74u. Left alone deliberately - renaming
	// them all is a large diff for no behaviour change, and the base weapon it
	// hijacks is weapon_galil either way.
	register_plugin("[ZP] Extra Item: AT15 HW", "1.0", "LARS-DAY[BR]EAKER")
	register_message(get_user_msgid("DeathMsg"), "message_DeathMsg")
	register_event("CurWeapon","CurrentWeapon","be","1=1")
	RegisterHam(Ham_Item_AddToPlayer, "weapon_galil", "fw_aks74u_AddToPlayer")
	RegisterHam(Ham_Use, "func_tank", "fw_UseStationary_Post", 1)
	RegisterHam(Ham_Use, "func_tankmortar", "fw_UseStationary_Post", 1)
	RegisterHam(Ham_Use, "func_tankrocket", "fw_UseStationary_Post", 1)
	RegisterHam(Ham_Use, "func_tanklaser", "fw_UseStationary_Post", 1)
	for (new i = 1; i < sizeof WEAPONENTNAMES; i++)
	if (WEAPONENTNAMES[i][0]) RegisterHam(Ham_Item_Deploy, WEAPONENTNAMES[i], "fw_Item_Deploy_Post", 1)
	RegisterHam(Ham_Weapon_PrimaryAttack, "weapon_galil", "fw_aks74u_PrimaryAttack")
	RegisterHam(Ham_Weapon_PrimaryAttack, "weapon_galil", "fw_aks74u_PrimaryAttack_Post", 1)
	RegisterHam(Ham_Item_PostFrame, "weapon_galil", "aks74u_ItemPostFrame")
	RegisterHam(Ham_Weapon_Reload, "weapon_galil", "aks74u_Reload")
	RegisterHam(Ham_Weapon_Reload, "weapon_galil", "aks74u_Reload_Post", 1)
	RegisterHam(Ham_TakeDamage, "player", "fw_TakeDamage")
	register_forward(FM_SetModel, "fw_SetModel")
	register_forward(FM_UpdateClientData, "fw_UpdateClientData_Post", 1)
	register_forward(FM_PlaybackEvent, "fwPlaybackEvent")
	
	RegisterHam(Ham_TraceAttack, "worldspawn", "fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_breakable", "fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_wall", "fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_door", "fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_door_rotating", "fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_plat", "fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_rotating", "fw_TraceAttack", 1)

	cvar_dmg_aks74u = register_cvar("zp_aks74u_dmg", "2.1")
	cvar_recoil_aks74u = register_cvar("zp_aks74u_recoil", "1.0")
	cvar_clip_aks74u = register_cvar("zp_aks74u_clip", "42")
	// 1 = the KickBack table above, 0 = the pack's original zp_aks74u_recoil
	// scaling, kept so the two can be compared without a recompile
	cvar_recoilmode_aks74u = register_cvar("zp_aks74u_recoil_mode", "1")
	cvar_kickscale_aks74u  = register_cvar("zp_aks74u_kick_scale", "0.55")

	/*
		The real spread control. 1.0 leaves the galil's own cone alone, 0.5 halves
		it. Unlike zp_aks74u_accuracy_cap this multiplies the cone the engine is
		about to fire with, so it is a straight percentage and it does not care
		whether m_flAccuracy is reachable.
	*/
	cvar_spreadscale_aks74u = register_cvar("zp_aks74u_spread_scale", "0.5")

	// registration is checked, because a hook that silently fails to attach would
	// leave a cvar in the config that quietly does nothing - which is the exact
	// trap zp_aks74u_accuracy_cap turned out to be
	if (!RegisterHookChain(RG_CBaseEntity_FireBullets3, "Fw_FireBullets3_Pre", false))
		log_amx("[AT15] RegisterHookChain(FireBullets3) FAILED - zp_aks74u_spread_scale will do nothing")
	cvar_spd_aks74u = register_cvar("zp_aks74u_spd", "1.0")
	cvar_aks74u_ammo = register_cvar("zp_aks74u_ammo", "180")
	
	// Price as a cvar read at map start, the way the Angelic and Iron Beast do it,
	// rather than the 43 the pack hardcoded. zp_register_extra_item takes the
	// value once here, so changing the cvar mid-map does nothing until the next one.
	new pCost = register_cvar("zp_at15hw_cost", "43")
	g_itemid_aks74u = zp_register_extra_item("\r[\wAT15 HW\r]", get_pcvar_num(pCost), ZP_TEAM_HUMAN)
	g_MaxPlayers = get_maxplayers()
        gmsgWeaponList = get_user_msgid("WeaponList")
}

public plugin_precache()
{
	precache_model(aks74u_V_MODEL)
	precache_model(aks74u_P_MODEL)
	precache_model(aks74u_W_MODEL)
	for(new i = 0; i < sizeof Fire_Sounds; i++)
		precache_sound(Fire_Sounds[i])
	precache_sound("YouTuber/at15hw_clipin.wav")
	precache_sound("YouTuber/at15hw_clipout.wav")
	precache_sound("YouTuber/at15hw_draw.wav")
	precache_sound("YouTuber/at15hw_idle1.wav")
	m_iBlood[0] = precache_model("sprites/blood.spr")
	m_iBlood[1] = precache_model("sprites/bloodspray.spr")
	// sprites/weapon_at15hw.txt is a copy of the stock weapon_galil.txt, so the
	// HUD slot resolves against sprites the game already ships. The pack asked
	// for sprites/weapon_aks74u.txt and never included it.
	precache_generic("sprites/weapon_at15hw.txt")
	// removed: sprites/zm/640hud16.spr and sprites/zm/640hud7.spr - neither
	// exists under cstrike/ or valve/, and nothing here draws with them.
	
        register_clcmd("weapon_at15hw", "weapon_hook")	
	register_forward(FM_PrecacheEvent, "fwPrecacheEvent_Post", 1)
}

public weapon_hook(id)
{
    	engclient_cmd(id, "weapon_galil")
    	return PLUGIN_HANDLED
}

public fw_TraceAttack(iEnt, iAttacker, Float:flDamage, Float:fDir[3], ptr, iDamageType)
{
	if(!is_user_alive(iAttacker))
		return

	new g_currentweapon = get_user_weapon(iAttacker)

	if(g_currentweapon != CSW_GALIL) return

	// the cached flag, not a lookup - this runs once per bullet
	if(!g_bFiringAT15[iAttacker]) return

	// These mark the REAL impact point, spread and all - the only set of holes
	// now, since the client's own copy of the fire event is no longer replayed.

	static Float:flEnd[3]
	get_tr2(ptr, TR_vecEndPos, flEnd)
	
	/*
		ONE decal per impact.

		The pack sent two: TE_DECAL or TE_WORLDDECAL, and then an unconditional
		TE_GUNSHOTDECAL - each rolling its own texture out of GUNSHOT_DECALS. So
		every hole was stamped twice with two different textures, and the gunshot
		variant rang a ricochet on top. TE_GUNSHOTDECAL is the one to keep: it is
		what the stock weapons use and it carries the ricochet the others lack.

		Its entity field was also being handed iAttacker - the SHOOTER's index -
		where it wants the entity the decal is being applied to. On a hit against
		a brush entity that pinned the hole to the wrong edict; iEnt is what the
		hook was already given.
	*/
	new decal = GUNSHOT_DECALS[random_num(0, sizeof GUNSHOT_DECALS - 1)]

	message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
	write_byte(TE_GUNSHOTDECAL)
	write_coord_f(flEnd[0])
	write_coord_f(flEnd[1])
	write_coord_f(flEnd[2])
	write_short(iEnt > 0 && pev_valid(iEnt) ? iEnt : 0)
	write_byte(decal)
	message_end()
}

/*
	These reset per-player state only. There is no ownership left to clear: the
	weapon carries that, and it goes away with the weapon - stripped on infection,
	gone on disconnect, and simply not held any more once dropped. Dropping it also
	no longer erases it, which is the behaviour that was asked for: the gun on the
	ground is still an AT15 and whoever picks it up gets one.

	Same wording as the Angelic and the Iron Beast, because it is now the same rule.
*/
public zp_user_humanized_post(id)
{
	g_bFiringAT15[id] = false
}

public plugin_natives ()
{
	register_native("give_weapon_at15hw", "native_give_weapon_add", 1)
}
public native_give_weapon_add(id)
{
	give_aks74u(id)
}

public fwPrecacheEvent_Post(type, const name[])
{
	if (equal("events/galil.sc", name))
	{
		g_orig_event_aks74u = get_orig_retval()
		return FMRES_HANDLED
	}
	return FMRES_IGNORED
}

public client_connect(id)
{
	g_bFiringAT15[id] = false
	g_iShotsFired[id] = 0
	g_iKickDir[id] = 0
}

public client_disconnect(id)
{
	g_bFiringAT15[id] = false
}

public zp_user_infected_post(id)
{
	if (zp_get_user_zombie(id))
	{
		g_bFiringAT15[id] = false
	}
}

public fw_SetModel(entity, model[])
{
	if(!is_valid_ent(entity))
		return FMRES_IGNORED
	
	static szClassName[33]
	entity_get_string(entity, EV_SZ_classname, szClassName, charsmax(szClassName))
		
	if(!equal(szClassName, "weaponbox"))
		return FMRES_IGNORED
	
	if(equal(model, "models/w_galil.mdl"))
	{
		static iStoredAugID

		iStoredAugID = find_ent_by_owner(ENG_NULLENT, "weapon_galil", entity)

		if(!is_valid_ent(iStoredAugID))
			return FMRES_IGNORED

		/*
			Nothing to stamp and no flag to clear any more - the key was put on the
			weapon when it was handed over and it is still there. All this has to do
			is give the box the right world model.

			Reading the entity also settles the collision with za_ru_lavam4a1, which
			hijacks weapon_galil too: its dropped gun carries FROZENLAVA_KEY, not
			this one, so Is_AT15 is simply false and we leave it alone. The previous
			version tested a per-player flag and, loading last, converted a dropped
			120-pack FrozenLava into a 43-pack AT15.
		*/
		if(Is_AT15(iStoredAugID))
		{
			entity_set_model(entity, aks74u_W_MODEL)
			return FMRES_SUPERCEDE
		}
	}
	return FMRES_IGNORED
}

public give_aks74u(id)
{
	drop_weapons(id, 1)
	new iWep2 = give_item(id,"weapon_galil")
	if( iWep2 > 0 )
	{
		// this is what makes it an AT15 - every stat keys off it, and it stays on
		// the entity for the life of the weapon
		set_pev(iWep2, pev_impulse, aks74u_WEAPONKEY)

		cs_set_weapon_ammo(iWep2, get_pcvar_num(cvar_clip_aks74u))
		cs_set_user_bpammo (id, CSW_GALIL, get_pcvar_num(cvar_aks74u_ammo))	
		UTIL_PlayWeaponAnimation(id, aks74u_DRAW)
		set_pdata_float(id, m_flNextAttack, 1.0, PLAYER_LINUX_XTRA_OFF)

                message_begin(MSG_ONE, gmsgWeaponList, {0,0,0}, id)
		write_string("weapon_at15hw")
		write_byte(4)
		write_byte(90)
		write_byte(-1)
		write_byte(-1)
		write_byte(0)
		write_byte(17)
		write_byte(CSW_GALIL)
		message_end()

	}
	g_iShotsFired[id] = 0
	g_iKickDir[id] = 0
}

public zp_extra_item_selected(id, itemid)
{
	if(itemid != g_itemid_aks74u)
		return

	give_aks74u(id)
}

public fw_aks74u_AddToPlayer(aks74u, id)
{
	if(!is_valid_ent(aks74u) || !is_user_connected(id))
		return HAM_IGNORED
	
	/*
		Not ours - say nothing.

		The pack had an else branch here that pushed a WeaponList record at anybody
		picking up ANY plain galil, overwriting whatever CS had registered for
		CSW_GALIL with this plugin's hardcoded slot and ammo numbers. Somebody who
		had never touched the AT15 got their HUD entry for the stock galil rewritten
		for the rest of the map. A galil that is not this gun is none of our
		business.
	*/
	if(!Is_AT15(aks74u))
		return HAM_IGNORED

	// the key is NOT cleared here any more - it is the identity, and clearing it
	// was what forced everything else onto a per-player flag

	message_begin(MSG_ONE, gmsgWeaponList, {0,0,0}, id)
	write_string("weapon_at15hw")
	write_byte(4)          // ammo1 type
	write_byte(90)         // max ammo1
	write_byte(-1)         // ammo2 type
	write_byte(-1)         // max ammo2
	write_byte(0)          // slot
	write_byte(17)         // position
	write_byte(CSW_GALIL)  // id
	write_byte(0)          // flags - the pack omitted this and the client read past the end
	message_end()

	return HAM_IGNORED
}

public fw_UseStationary_Post(entity, caller, activator, use_type)
{
	if (use_type == USE_STOPPED && is_user_connected(caller))
		replace_weapon_models(caller, get_user_weapon(caller))
}

public fw_Item_Deploy_Post(weapon_ent)
{
	static owner
	owner = fm_cs_get_weapon_ent_owner(weapon_ent)
	
	static weaponid
	weaponid = cs_get_weapon_id(weapon_ent)
	
	replace_weapon_models(owner, weaponid)
}

public CurrentWeapon(id)
{
     replace_weapon_models(id, read_data(2))

     if(read_data(2) != CSW_GALIL)
          return

     // the lookup was already here, so test the entity it found rather than a flag
     static weapon[32], Ent
     get_weaponname(read_data(2), weapon, 31)
     Ent = find_ent_by_owner(-1, weapon, id)

     if(!Is_AT15(Ent))
          return

     static Float:Delay
     Delay = get_pdata_float(Ent, 46, 4) * get_pcvar_float(cvar_spd_aks74u)

     if (Delay > 0.0)
          set_pdata_float(Ent, 46, Delay, 4)
}

replace_weapon_models(id, weaponid)
{
	switch (weaponid)
	{
		case CSW_GALIL:
		{
			if (zp_get_user_zombie(id) || zp_get_user_survivor(id))
				return

			if(HoldingAT15(id))
			{
				set_pev(id, pev_viewmodel2, aks74u_V_MODEL)
				set_pev(id, pev_weaponmodel2, aks74u_P_MODEL)
				if(oldweap[id] != CSW_GALIL) 
				{
					UTIL_PlayWeaponAnimation(id, aks74u_DRAW)
					set_pdata_float(id, m_flNextAttack, 1.0, PLAYER_LINUX_XTRA_OFF)

                                        message_begin(MSG_ONE, gmsgWeaponList, {0,0,0}, id)
					write_string("weapon_at15hw")
					write_byte(4)
					write_byte(90)
					write_byte(-1)
					write_byte(-1)
					write_byte(0)
					write_byte(17)
					write_byte(CSW_GALIL)
					message_end()

				}
			}
		}
	}
	oldweap[id] = weaponid
}

public fw_UpdateClientData_Post(Player, SendWeapons, CD_Handle)
{
	if(!HoldingAT15(Player))
		return FMRES_IGNORED
	
	set_cd(CD_Handle, CD_flNextAttack, halflife_time () + 0.001)
	return FMRES_HANDLED
}

public fw_aks74u_PrimaryAttack(Weapon)
{
	new Player = get_pdata_cbase(Weapon, 41, 4)

	// tested on the entity we were handed, then cached for the per-bullet hooks
	if (!Is_AT15(Weapon) || !IsValidUser(Player))
		return

	g_bFiringAT15[Player] = true

	g_IsInPrimaryAttack = 1
	pev(Player,pev_punchangle,cl_pushangle[Player])

	g_clip_ammo[Player] = cs_get_weapon_ammo(Weapon)
}

public fwPlaybackEvent(flags, invoker, eventid, Float:delay, Float:origin[3], Float:angles[3], Float:fparam1, Float:fparam2, iParam1, iParam2, bParam1, bParam2)
{
	if ((eventid != g_orig_event_aks74u) || !g_IsInPrimaryAttack)
		return FMRES_IGNORED
	if (!(1 <= invoker <= g_MaxPlayers))
    return FMRES_IGNORED

	/*
		Dropped entirely rather than replayed HOSTONLY, which is what the pack did.

		The client's own copy of events/galil.sc is what drew the spread-out bullet
		holes: it traces the shot client-side using the galil's spread and stamps a
		decal wherever each round actually lands. Replaying it for the shooter meant
		those holes were drawn no matter what the server did, which is why clamping
		m_flAccuracy changed nothing on screen.

		Dropping the event takes the stock report, the shell and the muzzle flash
		with it. The flash is put back by hand below; the report is already replaced
		by this plugin's own fire sound, which was previously being buried under it.
		Same trade the Angelic makes, and its comment says so.
	*/
	return FMRES_SUPERCEDE
}

public fw_aks74u_PrimaryAttack_Post(Weapon)
{
	g_IsInPrimaryAttack = 0
	new Player = get_pdata_cbase(Weapon, 41, 4)

	// closed before the early returns below, so an empty-clip trigger pull cannot
	// leave the per-bullet window open into somebody else's shots
	if(IsValidUser(Player))
		g_bFiringAT15[Player] = false

	new szClip, szAmmo
	get_user_weapon(Player, szClip, szAmmo)

	if(!is_user_alive(Player))
		return

	if(Is_AT15(Weapon))
	{
		if (!g_clip_ammo[Player])
			return

		g_iShotsFired[Player]++
		g_fLastShot[Player] = get_gametime()

		if (get_pcvar_num(cvar_recoilmode_aks74u))
		{
			// discard the kick the galil just applied and put the scaled
			// CrossFire one on instead, rather than scaling what the engine
			// happened to produce
			set_pev(Player, pev_punchangle, cl_pushangle[Player])
			ApplyKickBack(Player, GetStance(Player))
		}
		else
		{
			new Float:push[3]
			pev(Player,pev_punchangle,push)
			xs_vec_sub(push,cl_pushangle[Player],push)

			xs_vec_mul_scalar(push,get_pcvar_float(cvar_recoil_aks74u),push)
			xs_vec_add(push,cl_pushangle[Player],push)
			set_pev(Player,pev_punchangle,push)
		}

		// the dropped fire event took the muzzle flash with it; the holes still
		// come from fw_TraceAttack, at the real impact points
		set_pev(Player, pev_effects, pev(Player, pev_effects) | EF_MUZZLEFLASH)

		emit_sound(Player, CHAN_WEAPON, Fire_Sounds[0], VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
		UTIL_PlayWeaponAnimation(Player, aks74u_SHOOT)
	}
}

/*
	The damagebits parameter is the point of declaring it.

	The pack's version stopped at "is the attacker holding the AT15", which is true
	while he is also cooking a grenade - so the 1.9x was multiplying his HE damage
	as well, and because this plugin loads last it had the final say over the number
	every other plugin had already agreed on. DMG_BULLET keeps it to what the gun
	actually fires.
*/
public fw_TakeDamage(victim, inflictor, attacker, Float:damage, damagebits)
{
	if (!(damagebits & DMG_BULLET))
		return HAM_IGNORED

	// HoldingAT15 does the get_user_weapon test itself, so a plain galil - or any
	// other weapon - never reaches the multiplier
	if (victim != attacker && is_user_connected(attacker) && HoldingAT15(attacker))
		SetHamParamFloat(4, damage * get_pcvar_float(cvar_dmg_aks74u))

	return HAM_IGNORED
}

public message_DeathMsg(msg_id, msg_dest, id)
{
	static szTruncatedWeapon[33], iAttacker, iVictim
	
	get_msg_arg_string(4, szTruncatedWeapon, charsmax(szTruncatedWeapon))
	
	iAttacker = get_msg_arg_int(1)
	iVictim = get_msg_arg_int(2)
	
	if(!is_user_connected(iAttacker) || iAttacker == iVictim)
		return PLUGIN_CONTINUE
	
	if(equal(szTruncatedWeapon, "galil") && HoldingAT15(iAttacker))
		set_msg_arg_string(4, "galil")
	return PLUGIN_CONTINUE
}

/*
	Which of the four KICKBACK rows applies. Same order of tests the engine uses
	in the weapon's own fire code - moving is checked before ducking, so shuffling
	while crouched gets the walking row, not the ducking one.
*/
/*
	Scale the bullet cone, in the one place the engine actually uses it.

	Params, from reapi_gamedll_const.inc, 1-based and counting pEntity:

	    1 pEntity  2 vecSrc  3 vecDirShooting  4 vecSpread  5 flDistance
	    6 iPenetration  7 iBulletType  8 iDamage  9 flRangeModifier
	    10 pevAttacker  11 bPistol  12 shared_rand

	so arg 4 is the cone, and here it is a scalar rather than the Float[3] that
	FireBuckshots takes. This runs for every entity that fires a bullet on the
	server, so the guards below are not optional: without them this would narrow
	every gun in the game.
*/
public Fw_FireBullets3_Pre(pEntity, Float:vecSrc[3], Float:vecDirShooting[3], Float:vecSpread, Float:flDistance,
                           iPenetration, iBulletType, iDamage, Float:flRangeModifier, pevAttacker, bool:bPistol, shared_rand)
{
	// the cached flag, not a lookup - this runs once per bullet, for every entity
	// on the server that fires one
	if (!IsValidUser(pEntity) || !g_bFiringAT15[pEntity])
		return HC_CONTINUE

	new Float:scale = get_pcvar_float(cvar_spreadscale_aks74u)

	if (scale < 0.0)
		scale = 0.0

	// nothing to do at 1.0, and skipping the write keeps the untouched case free
	if (scale == 1.0)
		return HC_CONTINUE

	SetHookChainArg(4, ATYPE_FLOAT, vecSpread * scale)

	return HC_CONTINUE
}

GetStance(id)
{
	new flags = pev(id, pev_flags)

	if (!(flags & FL_ONGROUND))
		return KB_AIR

	static Float:vel[3]
	pev(id, pev_velocity, vel)

	if (vel[0] * vel[0] + vel[1] * vel[1] > 0.0)
		return KB_WALK

	if (flags & FL_DUCKING)
		return KB_DUCK

	return KB_STAND
}

// a transcription of CBasePlayer::KickBack fed from KICKBACK, with every
// magnitude scaled by zp_aks74u_kick_scale. Column 6 is left alone - see the
// note beside the table.
ApplyKickBack(id, stance)
{
	static Float:punch[3]
	pev(id, pev_punchangle, punch)

	new Float:scale = get_pcvar_float(cvar_kickscale_aks74u)
	if (scale < 0.0)
		scale = 0.0

	new Float:upMax  = KICKBACK[stance][4] * scale
	new Float:latMax = KICKBACK[stance][5] * scale
	new Float:up, Float:lateral
	new shots = g_iShotsFired[id]

	if (shots <= 1)
	{
		up      = KICKBACK[stance][0] * scale
		lateral = KICKBACK[stance][1] * scale
	}
	else
	{
		up      = (KICKBACK[stance][0] + float(shots) * KICKBACK[stance][2]) * scale
		lateral = (KICKBACK[stance][1] + float(shots) * KICKBACK[stance][3]) * scale
	}

	punch[0] -= up

	if (punch[0] < -upMax)
		punch[0] = -upMax

	if (g_iKickDir[id])
	{
		punch[1] += lateral

		if (punch[1] > latMax)
			punch[1] = latMax
	}
	else
	{
		punch[1] -= lateral

		if (punch[1] < -latMax)
			punch[1] = -latMax
	}

	// engine does !RANDOM_LONG(0, direction_change), so 0 flips every shot
	// rather than never
	if (random_num(0, floatround(KICKBACK[stance][6])) == 0)
		g_iKickDir[id] = 1 - g_iKickDir[id]

	set_pev(id, pev_punchangle, punch)
}

/*
	"Is this player holding an AT15 right now."

	The get_user_weapon test first is not just an optimisation - it throws out every
	call where no galil is held, which is nearly all of them, before any entity
	search happens. FindOwnedWeapon is the same lookup the Angelic uses; offset 373
	would be cheaper but nothing on this machine has ever exercised it, and the
	Angelic's notes are explicit about not trusting an untested pdata offset.

	The genuinely hot paths - once per bullet - do not call this at all. They read
	g_bFiringAT15, which the attack hook sets from the weapon entity it is handed.
*/
bool:HoldingAT15(id)
{
	if (!is_user_alive(id) || get_user_weapon(id) != CSW_GALIL)
		return false

	return Is_AT15(FindOwnedGalil(id))
}

FindOwnedGalil(id)
{
	new ent = -1

	while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", "weapon_galil")) > 0)
	{
		if (get_pdata_cbase(ent, OFFSET_WEAPONOWNER, OFFSET_LINUX_WEAPONS) == id)
			return ent
	}

	return 0
}

stock fm_cs_get_current_weapon_ent(id)
{
	return get_pdata_cbase(id, OFFSET_ACTIVE_ITEM, OFFSET_LINUX)
}

stock fm_cs_get_weapon_ent_owner(ent)
{
	return get_pdata_cbase(ent, OFFSET_WEAPONOWNER, OFFSET_LINUX_WEAPONS)
}

stock UTIL_PlayWeaponAnimation(const Player, const Sequence)
{
	set_pev(Player, pev_weaponanim, Sequence)
	
	message_begin(MSG_ONE_UNRELIABLE, SVC_WEAPONANIM, .player = Player)
	write_byte(Sequence)
	write_byte(pev(Player, pev_body))
	message_end()
}

public aks74u_ItemPostFrame(weapon_entity) 
{
     // m_pPlayer, not pev_owner - the Angelic's notes record pev_owner reading 0 on
     // a held weapon here, which silently breaks every player-side operation while
     // leaving the entity-side ones working
     new id = get_pdata_cbase(weapon_entity, OFFSET_WEAPONOWNER, OFFSET_LINUX_WEAPONS)
     if (!is_user_connected(id))
          return HAM_IGNORED

     if (!Is_AT15(weapon_entity))
          return HAM_IGNORED

     // end the burst once the trigger has been off for a moment, so the next one
     // starts from the base kick again instead of the top of the climb
     if (g_iShotsFired[id] && get_gametime() - g_fLastShot[id] > 0.25)
          g_iShotsFired[id] = 0

     static iClipExtra

     iClipExtra = get_pcvar_num(cvar_clip_aks74u)
     new Float:flNextAttack = get_pdata_float(id, m_flNextAttack, PLAYER_LINUX_XTRA_OFF)

     new iBpAmmo = cs_get_user_bpammo(id, CSW_GALIL)
     new iClip = get_pdata_int(weapon_entity, m_iClip, WEAP_LINUX_XTRA_OFF)

     new fInReload = get_pdata_int(weapon_entity, m_fInReload, WEAP_LINUX_XTRA_OFF) 

     if( fInReload && flNextAttack <= 0.0 )
     {
	     new j = min(iClipExtra - iClip, iBpAmmo)
	
	     set_pdata_int(weapon_entity, m_iClip, iClip + j, WEAP_LINUX_XTRA_OFF)
	     cs_set_user_bpammo(id, CSW_GALIL, iBpAmmo-j)
		
	     set_pdata_int(weapon_entity, m_fInReload, 0, WEAP_LINUX_XTRA_OFF)
	     fInReload = 0
     }
     return HAM_IGNORED
}

public aks74u_Reload(weapon_entity) 
{
     // m_pPlayer, not pev_owner - the Angelic's notes record pev_owner reading 0 on
     // a held weapon here, which silently breaks every player-side operation while
     // leaving the entity-side ones working
     new id = get_pdata_cbase(weapon_entity, OFFSET_WEAPONOWNER, OFFSET_LINUX_WEAPONS)
     if (!is_user_connected(id))
          return HAM_IGNORED

     if (!Is_AT15(weapon_entity))
          return HAM_IGNORED

     // Is_AT15 above already returned if this was not our weapon, so the clip size
     // is unconditional here. It was guarded by the same flag as the check above,
     // which left iClipExtra holding the PREVIOUS call's value on the paths where
     // the flag was false - a static read before it was written.
     new iClipExtra = get_pcvar_num(cvar_clip_aks74u)

     g_aks74u_TmpClip[id] = -1

     new iBpAmmo = cs_get_user_bpammo(id, CSW_GALIL)
     new iClip = get_pdata_int(weapon_entity, m_iClip, WEAP_LINUX_XTRA_OFF)

     if (iBpAmmo <= 0)
          return HAM_SUPERCEDE

     if (iClip >= iClipExtra)
          return HAM_SUPERCEDE

     g_aks74u_TmpClip[id] = iClip

     return HAM_IGNORED
}

public aks74u_Reload_Post(weapon_entity) 
{
	// m_pPlayer, not pev_owner - see the note in aks74u_ItemPostFrame
	new id = get_pdata_cbase(weapon_entity, OFFSET_WEAPONOWNER, OFFSET_LINUX_WEAPONS)
	if (!is_user_connected(id))
		return HAM_IGNORED

	if (!Is_AT15(weapon_entity))
		return HAM_IGNORED

	if (g_aks74u_TmpClip[id] == -1)
		return HAM_IGNORED

	set_pdata_int(weapon_entity, m_iClip, g_aks74u_TmpClip[id], WEAP_LINUX_XTRA_OFF)

	set_pdata_float(weapon_entity, m_flTimeWeaponIdle, aks74u_RELOAD_TIME, WEAP_LINUX_XTRA_OFF)

	set_pdata_float(id, m_flNextAttack, aks74u_RELOAD_TIME, PLAYER_LINUX_XTRA_OFF)

	set_pdata_int(weapon_entity, m_fInReload, 1, WEAP_LINUX_XTRA_OFF)

	UTIL_PlayWeaponAnimation(id, aks74u_RELOAD)

	return HAM_IGNORED
}

stock drop_weapons(id, dropwhat)
{
     static weapons[32], num, i, weaponid
     num = 0
     get_user_weapons(id, weapons, num)
     
     for (i = 0; i < num; i++)
     {
          weaponid = weapons[i]
          
          if (dropwhat == 1 && ((1<<weaponid) & PRIMARY_WEAPONS_BIT_SUM))
          {
               static wname[32]
               get_weaponname(weaponid, wname, sizeof wname - 1)
               engclient_cmd(id, "drop", wname)
          }
     }
}