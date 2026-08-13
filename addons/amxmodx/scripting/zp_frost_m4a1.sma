#include <amxmodx>
#include <zombieplague>
#include <dhudmessage>
#include <hamsandwich>
#include <fakemeta>
#include <cstrike>
#include <engine>
#include <fun>

#define write_coord_fl(%1) engfunc(EngFunc_WriteCoord, %1)
#define message_begin_fl(%1,%2,%3,%4) engfunc(EngFunc_MessageBegin, %1, %2, %3, %4)

new Ham:Ham_Player_ResetMaxSpeed = Ham_Item_PreFrame

new const V_M4A1_MODEL[] = "models/zombie_plague/v_frost_m4a1.mdl"
new const P_M4A1_MODEL[] = "models/zombie_plague/p_frost_m4a1.mdl"
new const W_M4A1_MODEL[]    = "models/zombie_plague/w_frost_m4a1.mdl"
new const W_OLD_M4A1_MODEL[]    = "models/w_m4a1.mdl"
new const ICE_MODEL[] = "models/zombie_plague/icecube_frozen.mdl"
new const MODEL_GLASSGIBS[]	= "models/glassgibs.mdl"
new const SOUND_UNFROZEN[]	= "debris/glass3.wav"

enum _:Sprites
{
	SPRITE_FROST,
	SPRITE_FROST2,
	SPRITE_FLAKE
}

new g_iSprites[Sprites]

new g_iItemID, g_iM4A1FrostSpr, g_iMsgScreenFade, g_iMaxPlayers, g_iHudSync, g_iSpriteLaser, g_iGlassGibs, g_iFreezeDmg, g_fFrostTime, g_iDmgMultiplier, g_iStatusIcon, g_iDmgWhileFrozen
/*
	Ownership lives on the weapon entity, not on the player - rewritten by
	setup 2026-08-13.

	This plugin already stamped pev_impulse with 1997, but only while the
	weapon was lying on the ground: fw_SetModel set it on drop and
	fw_FrostM4A1AddToPlayer wiped it again the moment somebody picked the gun
	up, handing the identity back to a per-player bool. So for the whole time
	the weapon was actually held - the only time it matters - nothing on the
	entity said what it was.

	That is what let zp_extra_angelic_beast collide with it. Both plugins hook
	weapon_m4a1, both kept a bool per player, and neither cleared the other's:
	buying one then the other left both sets of hooks live on one weapon, so
	the models fought and the clip came out wrong.

	Keeping the stamp permanently fixes it and removes code rather than adding
	any. An entity holds one key, so two plugins can never both claim it, and
	neither needs to know the other exists. The identity now simply travels
	with the gun - drop it and it is still a Frost M4A1 on the ground, and
	whoever picks it up gets a Frost M4A1, which is what a dropped weapon
	should do.

	ak47_transformers_extra, zp_weapon_ak47_beast, zp_extra_bak47p and
	zombie_plague40 all key off pev_impulse the same way.
*/
#define FROST_KEY                 1997
#define Is_Frost(%0)              (pev_valid(%0) && pev(%0, pev_impulse) == FROST_KEY)
#define OFF_WEAPON_PLAYER         41
#define OFF_PLAYER_ACTIVE_ITEM   373
#define LINUX_WEAPON               4
#define LINUX_PLAYER               5

new g_bIsFrozen[33]
new g_iDmg[33]

public plugin_init()
{
	register_plugin("[ZP] Extra Item: Frost M4A1", "1.4", "Raheem")
	
	// Cvars
	g_fFrostTime = register_cvar("zp_frost_m4a1_time", "7.0") // Freeze Time. It's Float you can make it 0.5
	g_iFreezeDmg = register_cvar("zp_freezing_m4a1_damage", "2000") // Damage Requried So Zombie got Frozen
	g_iDmgMultiplier = register_cvar("zp_multiplier_m4a1_damage", "10") // Multiplie Weapon Damage
	g_iDmgWhileFrozen = register_cvar("zp_frost_m4a1_dmg_while_frozen", "1") // added by setup: 1 = frozen zombies can be shot, 0 = original behaviour (invulnerable)

	// Message IDS
	g_iHudSync = CreateHudSyncObj()
	g_iMsgScreenFade = get_user_msgid("ScreenFade")
	g_iStatusIcon = get_user_msgid("StatusIcon")

	// Server Max Slots
	g_iMaxPlayers = get_maxplayers()
	
	// ITEM NAME & COST
	g_iItemID = zp_register_extra_item("Zombie-Amxx.Ru - Frost M4A1", 30, ZP_TEAM_HUMAN) // It's cost 30 Ammo Pack
	
	// Events
	register_event("HLTV", "event_round_start", "a", "1=0", "2=0")
	register_event("WeapPickup","CheckModel","b","1=19")
	register_event("CurWeapon","CurrentWeapon","be","1=1")
	register_event("DeathMsg", "EventDeathMsg", "a")
	
	// Forwards
	register_forward(FM_PlayerPreThink, "fw_PlayerPreThink")
	register_forward(FM_SetModel, "fw_SetModel")
	
	// Hams
	RegisterHam(Ham_TakeDamage, "player", "fw_TakeDamage")
	RegisterHam(Ham_TraceAttack, "player", "TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "worldspawn", "TraceAttack", 1)
	// Ham_Item_AddToPlayer is no longer hooked: it existed only to convert the
	// on-the-ground key back into a per-player bool on pickup. The key is
	// permanent now, so picking the weapon up needs no special handling.
	RegisterHam(Ham_Item_Deploy, "weapon_m4a1", "fw_M4A1_Deploy_Post", 1)   // added by setup: reapply custom model on every deploy
}

public plugin_precache() 
{
	// Models
	precache_model(V_M4A1_MODEL)
	precache_model(P_M4A1_MODEL)
	precache_model(W_M4A1_MODEL)
	precache_model(ICE_MODEL)
	g_iGlassGibs = precache_model(MODEL_GLASSGIBS)
	
	// Sounds
	precache_sound("warcraft3/impalehit.wav")
	precache_sound(SOUND_UNFROZEN)
	
	// Sprites
	g_iM4A1FrostSpr = precache_model("sprites/shockwave.spr")
	g_iSpriteLaser = precache_model( "sprites/Newlightning.spr")
	g_iSprites[SPRITE_FROST] = precache_model("sprites/frostexp_1.spr");
	g_iSprites[SPRITE_FROST2] = precache_model("sprites/frostexp_2.spr");
	g_iSprites[SPRITE_FLAKE] = precache_model("sprites/snowflake_1.spr");
}

public client_putinserver(id)
{
	g_bIsFrozen[id] = false
}

public client_disconnect(id)
{
	g_bIsFrozen[id] = false
	RemoveEntity(id)
}

public zp_extra_item_selected(player, itemid)
{
	if (itemid == g_iItemID) 
	{
		/*
			Drop the old M4A1 through the engine rather than stripping it.

			ham_strip_weapon destroys the entity while m_pActiveItem still
			points at it, leaving every later read of the player's weapon
			state looking at something that no longer exists. The tell was
			that dropping the gun with G and then buying worked, while buying
			directly gave a Frost-looking rifle with none of the behaviour.
			engclient_cmd "drop" is what G runs, so the purchase now takes the
			path that already worked.
		*/
		if (FindOwnedM4A1(player))
			engclient_cmd(player, "drop", "weapon_m4a1")

		give_item(player, "weapon_m4a1")

		// stamp the entity - this is what makes it a Frost M4A1 from here on.
		// FindOwnedM4A1 matches on m_pPlayer rather than pev_owner, which
		// reads 0 on a freshly deployed weapon.
		new frostEnt = FindOwnedM4A1(player)

		if (!frostEnt)
			return

		set_pev(frostEnt, pev_impulse, FROST_KEY)

		// give_item deploys the weapon inside its own call, before the key was
		// set, so that first deploy saw an unstamped entity and the model hook
		// skipped it. Run deploy once more now that the key is readable.
		ExecuteHamB(Ham_Item_Deploy, frostEnt)

		cs_set_user_bpammo(player, CSW_M4A1, 90)

		// one line per purchase - proves the key landed and that the
		// player-side checks, which are what the damage and freeze code uses,
		// agree with it. Not on any per-frame or per-shot path.
		log_amx("[FROST] bought id=%d ent=%d keyed=%d holding=%d weapon=%d",
			player, frostEnt,
			Is_Frost(frostEnt) ? 1 : 0,
			HoldingFrost(player) ? 1 : 0,
			get_user_weapon(player))
		new sName[32]
		get_user_name(player, sName, 31)
		set_hudmessage(random(255), random(255), random(255), -1.0, 0.17, 1, 0.0, 5.0, 1.0, 1.0, -1)
		show_hudmessage(0, "%s ????? Frost M4A1!", sName)
		ColorPrint(player, "^1[^4Zombie-Amxx.Ru^1] ^3?? ?????? Frost M4A1^1!")
	}
}

public TraceAttack(iEnt, iAttacker, Float:flDamage, Float:fDir[3], ptr, iDamageType)
{
	if(!is_user_alive(iAttacker))
		return 
	
	if(!HoldingFrost(iAttacker))
		return
	
	set_hudmessage(34, 138, 255, -1.0, 0.17, 1, 0.0, 2.0, 1.0, 1.0, -1)
	ShowSyncHudMsg(iAttacker, g_iHudSync, "????? ?? ?????????^n%d/%d", g_iDmg[iAttacker], get_pcvar_num(g_iFreezeDmg))
	
	new vec1[3], vec2[3]
	get_user_origin(iAttacker, vec1, 1) 
	get_user_origin(iAttacker, vec2, 4)

	make_beam(vec1, vec2, g_iSpriteLaser, 0, 50, 200, 200)
}

public zp_user_infected_post(infected, infector)
{
	// nothing to clear - ZP strips the weapon on infection and the identity
	// goes with it
}

public zp_user_humanized_post(id)
{
	g_iDmg[id] = 0
	RemoveEntity(id)
}

public event_round_start()
{
	for (new i = 1; i <= g_iMaxPlayers; i++)
	{
		g_bIsFrozen[i] = false
		g_iDmg[i] = 0
		
		if(is_user_alive(i))
		{
			Remove_Rendering(i)
		}
	}
}

public EventDeathMsg()
{
	new iVictim = read_data(2)
	RemoveEntity(iVictim)
	Remove_Rendering(iVictim)
	g_bIsFrozen[iVictim] = false
}

public fw_TakeDamage(victim, inflictor, attacker, Float:damage, damage_type)
{
	if(!is_user_connected(victim) || !is_user_connected(attacker) || zp_get_user_nemesis(victim) || attacker == victim || !attacker)
		return HAM_IGNORED

	if(g_bIsFrozen[victim] && !get_pcvar_num(g_iDmgWhileFrozen))
		return HAM_SUPERCEDE

	if(HoldingFrost(attacker))
		SetHamParamFloat(4, damage * get_pcvar_num(g_iDmgMultiplier))
	
	// For Frost Effect Ring
	static Float:originF[3]
	pev(victim, pev_origin, originF)
	
	// For Frost Effect Sound
	static originF2[3] 
	get_user_origin(victim, originF2)
	
	if(HoldingFrost(attacker))
	{
		g_iDmg[attacker] += (floatround(damage) * get_pcvar_num(g_iDmgMultiplier))
	}
	
	if((g_iDmg[attacker] >= get_pcvar_num(g_iFreezeDmg)) && HoldingFrost(attacker))
	{
		new sName[32]
		get_user_name(victim, sName, charsmax(sName))
		FrostEffect(victim)
		FrostEffectRing(originF)
		FrostEffectSound(originF2)
		g_iDmg[attacker] = 0
		set_dhudmessage(34, 138, 255, -1.0, 0.25, 2, 6.0, 3.0, 0.1, 1.5)
		show_dhudmessage(attacker, "%s ??? ?????????!", sName)
	}
	return HAM_IGNORED
}

public CheckModel(id)
{
	if(zp_get_user_survivor(id))
		return PLUGIN_HANDLED
	
	if (is_user_alive(id))
	{
		set_pev(id, pev_viewmodel2, V_M4A1_MODEL)
		set_pev(id, pev_weaponmodel2, P_M4A1_MODEL)
	}
	return PLUGIN_HANDLED
}

public CurrentWeapon(id)
{
	if (HoldingFrost(id))
	{
		CheckModel(id)
	}
	else
	{
		ClearSyncHud(id, g_iHudSync)
	}
	return PLUGIN_HANDLED
}

public FrostEffect(id)
{
	// Only effect alive unfrozen zombies
	if (!is_user_alive(id) || !zp_get_user_zombie(id) || g_bIsFrozen[id])
		return
	
	message_begin(MSG_ONE_UNRELIABLE, g_iMsgScreenFade, _, id)
	write_short(4096*1) // duration
	write_short(4096*1) // hold time
	write_short(0x0000) // fade type
	write_byte(0) // red
	write_byte(50) // green
	write_byte(200) // blue
	write_byte(100) // alpha
	message_end()

	message_begin(MSG_ONE, g_iStatusIcon, {0,0,0}, id)
	write_byte(1) // Status [0=Hide, 1=Show, 2=Flash]
	write_string("dmg_cold") // Sprite Name
	write_byte(000) // Red
	write_byte(206) // Green
	write_byte(209) // Blue
	message_end()
	
	new ent = create_entity("info_target")
	
	UTIL_Explosion(id, g_iSprites[SPRITE_FROST], 40, 30, 4)
	UTIL_Explosion(id, g_iSprites[SPRITE_FROST2], 20, 30, 4)
	UTIL_SpriteTrail(id, g_iSprites[SPRITE_FLAKE], 30, 3, 2, 30, 0)
	
	new Float:iOrigin[3]
	entity_get_vector(id, EV_VEC_origin, iOrigin)
	set_pev(ent, pev_body, 1)
	entity_set_model(ent, ICE_MODEL)
	iOrigin[2] -= 35
	entity_set_origin(ent, iOrigin)
	set_pev(ent, pev_owner, id)
	set_rendering(ent, kRenderFxNone, 255, 255, 255, kRenderTransAdd, 255)
	entity_set_string(ent, EV_SZ_classname, "ent_frozen")
	entity_set_int(ent, EV_INT_solid, 2)
	new Float: iOriginNew[3]
	entity_get_vector(id, EV_VEC_origin, iOriginNew)
	set_user_rendering(id, kRenderFxGlowShell, 0, 100, 200, kRenderNormal, 25)
	g_bIsFrozen[id] = true
	set_task(get_pcvar_float(g_fFrostTime), "RemoveFrost", id) // Time to Remove Frost Effect 
}

public fw_PlayerPreThink(id)
{
	// Not alive or Not Zombie
	if (!is_user_alive(id) || !g_bIsFrozen[id])
		return

	// Stop motion
	set_pev(id, pev_velocity, Float:{0.0,0.0,0.0})
	set_user_maxspeed(id, 1.0)
	
	// Stop Moving Mouse
	set_pev(id , pev_v_angle , Float:{0.0,0.0,0.0})
	set_pev(id , pev_fixangle , 1)
}

// Frost Effect Sound
public FrostEffectSound(iOrigin[3])
{
	new Entity = create_entity("info_target")

	new Float:flOrigin[3]
	IVecFVec(iOrigin, flOrigin)
	entity_set_origin(Entity, flOrigin)
	emit_sound(Entity, CHAN_WEAPON, "warcraft3/impalehit.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
	remove_entity(Entity)
}

UTIL_Explosion(iEnt, iSprite, iScale, iFramerate, Flags)
{
	new Float:vOrigin[3]
	pev(iEnt, pev_origin, vOrigin)
	
	message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
	write_byte(TE_EXPLOSION)
	engfunc(EngFunc_WriteCoord, vOrigin[0])
	engfunc(EngFunc_WriteCoord, vOrigin[1])
	engfunc(EngFunc_WriteCoord, vOrigin[2])
	write_short(iSprite)
	write_byte(iScale)
	write_byte(iFramerate)
	write_byte(Flags)
	message_end()
}

UTIL_SpriteTrail(iEnt, iSprite, iCount, iLife, iScale, iVelocity, iVary)
{
	new Float:vOrigin[3]
	pev(iEnt, pev_origin, vOrigin)
	
	message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
	write_byte(TE_SPRITETRAIL)
	engfunc(EngFunc_WriteCoord, vOrigin[0])
	engfunc(EngFunc_WriteCoord, vOrigin[1])
	engfunc(EngFunc_WriteCoord, vOrigin[2] + 100)
	engfunc(EngFunc_WriteCoord, vOrigin[0] + random_float( -200.0, 200.0 ))
	engfunc(EngFunc_WriteCoord, vOrigin[1] + random_float( -200.0, 200.0 ))
	engfunc(EngFunc_WriteCoord, vOrigin[2])
	write_short(iSprite)
	write_byte(iCount)
	write_byte(iLife)
	write_byte(iScale)
	write_byte(iVelocity)
	write_byte(iVary)
	message_end()
}

// Frost Effect Ring
FrostEffectRing(const Float:originF3[3])
{
	// Largest ring
	engfunc(EngFunc_MessageBegin, MSG_PVS, SVC_TEMPENTITY, originF3, 0)
	write_byte(TE_BEAMCYLINDER) // TE id
	engfunc(EngFunc_WriteCoord, originF3[0]) // x
	engfunc(EngFunc_WriteCoord, originF3[1]) // y
	engfunc(EngFunc_WriteCoord, originF3[2]) // z
	engfunc(EngFunc_WriteCoord, originF3[0]) // x axis
	engfunc(EngFunc_WriteCoord, originF3[1]) // y axis
	engfunc(EngFunc_WriteCoord, originF3[2]+100.0) // z axis
	write_short(g_iM4A1FrostSpr) // sprite
	write_byte(0) // startframe
	write_byte(0) // framerate
	write_byte(4) // life
	write_byte(60) // width
	write_byte(0) // noise
	write_byte(41) // red
	write_byte(138) // green
	write_byte(255) // blue
	write_byte(200) // brightness
	write_byte(0) // speed
	message_end()
}

// Remove Frost Effect
public RemoveFrost(id)
{
	// Not alive or not frozen anymore
	if (!is_user_alive(id) || !g_bIsFrozen[id])
		return
	
	// Unfreeze
	g_bIsFrozen[id] = false;
	set_task(0.1, "remove_jibs", id)

	// Rest Player Speed
	ExecuteHamB(Ham_Player_ResetMaxSpeed, id)
	
	Remove_Rendering(id)
	RemoveStatusIcon(id)
}

public remove_jibs(id)
{
	RemoveEntity(id)
	
	new Float:origin[3]
	pev(id,pev_origin,origin)
	
	message_begin_fl(MSG_PVS,SVC_TEMPENTITY,origin,0)
	write_byte(TE_IMPLOSION)
	write_coord_fl(origin[0]) // x
	write_coord_fl(origin[1]) // y
	write_coord_fl(origin[2] + 8.0) // z
	write_byte(64) // radius
	write_byte(10) // count
	write_byte(3) // duration
	message_end()
	
	message_begin_fl(MSG_PVS,SVC_TEMPENTITY,origin,0)
	write_byte(TE_SPARKS)
	write_coord_fl(origin[0]) // x
	write_coord_fl(origin[1]) // y
	write_coord_fl(origin[2]) // z
	message_end()
	
	message_begin_fl(MSG_PAS,SVC_TEMPENTITY,origin,0)
	write_byte(TE_BREAKMODEL)
	write_coord_fl(origin[0]) // x
	write_coord_fl(origin[1]) // y
	write_coord_fl(origin[2] + 24.0) // z
	write_coord_fl(16.0) // size x
	write_coord_fl(16.0) // size y
	write_coord_fl(16.0) // size z
	write_coord(random_num(-50,50)) // velocity x
	write_coord(random_num(-50,50)) // velocity y
	write_coord_fl(25.0) // velocity z
	write_byte(10) // random velocity
	write_short(g_iGlassGibs) // model
	write_byte(10) // count
	write_byte(25) // life
	write_byte(0x01) // flags
	message_end()
	
	emit_sound(0,CHAN_ITEM,SOUND_UNFROZEN,VOL_NORM,ATTN_NORM,0,PITCH_LOW)
}

stock ColorPrint(const id, const input[], any: ...)
{
	new count = 1, players[32]
	static msg[192]
	vformat(msg, 191, input, 3)
	
	replace_all(msg, 191, "!g", "^4")
	replace_all(msg, 191, "!y", "^1")
	replace_all(msg, 191, "!t", "^3")
	replace_all(msg, 191, "!t2", "^0")
	
	if (id) players[0] = id;else get_players(players, count, "ch")
	{
		for (new i = 0; i < count; i++)
		{
			if (is_user_connected( players[i]))
			{
				message_begin(MSG_ONE_UNRELIABLE, get_user_msgid("SayText"), _, players[i])
				write_byte(players[i])
				write_string(msg)
				message_end()
			}
		}
	}
}

/*
	The player's M4A1 entity, matched on m_pPlayer. Deliberately not a
	pev_owner scan: pev_owner reads 0 on a freshly deployed weapon, so a
	search based on it silently finds nothing.
*/
FindOwnedM4A1(id)
{
	new ent = -1

	while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", "weapon_m4a1")) > 0)
	{
		if (get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON) == id)
			return ent
	}

	return 0
}

/*
	Does this player hold a Frost M4A1?

	Deliberately the same m_pPlayer search the model hook already relies on,
	rather than reading m_pActiveItem. m_pActiveItem was tried first and the
	result was a Frost-looking rifle with none of the Frost behaviour: the
	entity-side hook worked and every player-side one silently did not. Rather
	than keep guessing at an offset, this reuses the lookup that is already
	proven to work in this plugin.

	The cost is an entity search, so callers on a hot path must cheap-test
	first - get_user_weapon() is the usual guard. Nothing here runs per frame:
	the callers are damage and trace events.
*/
bool:HoldingFrost(id)
{
	if (!is_user_alive(id) || get_user_weapon(id) != CSW_M4A1)
		return false

	return Is_Frost(FindOwnedM4A1(id))
}

stock ham_strip_weapon(id,weapon[])
{
    if(!equal(weapon,"weapon_",7)) return 0

    new wId = get_weaponid(weapon)
    if(!wId) return 0

    new wEnt
    while((wEnt = engfunc(EngFunc_FindEntityByString,wEnt,"classname",weapon)) && pev(wEnt,pev_owner) != id) {}
    if(!wEnt) return 0

    if(get_user_weapon(id) == wId) ExecuteHamB(Ham_Weapon_RetireWeapon,wEnt)

    if(!ExecuteHamB(Ham_RemovePlayerItem,id,wEnt)) return 0
    ExecuteHamB(Ham_Item_Kill,wEnt)

    set_pev(id,pev_weapons,pev(id,pev_weapons) & ~(1<<wId))

    return 1
}

make_beam(const origin2[3], const origin[3], sprite, red, green, blue, alpha)
{
	//BEAMENTPOINTS
	message_begin( MSG_BROADCAST,SVC_TEMPENTITY)
	write_byte (0) //TE_BEAMENTPOINTS 0
	write_coord(origin2[0])
	write_coord(origin2[1])
	write_coord(origin2[2])
	write_coord(origin[0])
	write_coord(origin[1])
	write_coord(origin[2])
	write_short(sprite) // sprite
	write_byte(1) // framestart
	write_byte(5) // framerate
	write_byte(2) // life
	write_byte(20) // width
	write_byte(0) // noise 
	write_byte(red) // r, g, b
	write_byte(green) // r, g, b 
	write_byte(blue) // r, g, b 
	write_byte(alpha) // brightness
	write_byte(150) // speed
	message_end()
}

public RemoveStatusIcon(id)
{
	// Remove Status Icon
	message_begin(MSG_ONE, g_iStatusIcon, {0,0,0}, id)
	write_byte(0) // Status [0=Hide, 1=Show, 2=Flash]
	write_string("dmg_cold") // Sprite Name
	message_end()
}

public fw_SetModel(entity, model[])
{
	
	if(!is_valid_ent(entity)) 
		return FMRES_IGNORED

	if(!equali(model, W_OLD_M4A1_MODEL)) 
		return FMRES_IGNORED

	// the weaponbox on the ground wraps the actual weapon entity, and that is
	// what carries the key
	static iStoredM4A1ID
	iStoredM4A1ID = find_ent_by_owner(-1, "weapon_m4a1", entity)

	/*
		Show the frost world model if the wrapped weapon is a Frost M4A1.

		This used to stamp the key here and clear the owner's bool, with
		fw_FrostM4A1AddToPlayer stamping it back on pickup - the key existed
		only while the gun lay on the ground. It is permanent now, so there is
		nothing to set and nothing to reset: the drop just needs drawing.
	*/
	if(Is_Frost(iStoredM4A1ID))
	{
		entity_set_model(entity, W_M4A1_MODEL)
		return FMRES_SUPERCEDE
	}
	return FMRES_IGNORED
}

stock Remove_Rendering(id)
{
	set_user_rendering(id, kRenderFxNone, 255, 255, 255, kRenderNormal, 16)
}

public RemoveEntity(id)
{
	if(!is_user_connected(id))
		return
		
	new iEnt = find_ent_by_owner(-1, "ent_frozen", id);
	
	if(pev_valid(iEnt))
		remove_entity(iEnt)
}

// added by setup - the plugin only set the view model from the CurWeapon event,
// which races with the engine's own Deploy and gets overwritten on weapon switch.
public fw_M4A1_Deploy_Post(iEnt)
{
	if(!pev_valid(iEnt))
		return

	new id = pev(iEnt, pev_owner)

	if(!is_user_alive(id) || !Is_Frost(iEnt))
		return

	CheckModel(id)
}
