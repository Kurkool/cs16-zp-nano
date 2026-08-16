#include <amxmodx>
#include <engine>
#include <fakemeta>
#include <fun>
#include <hamsandwich>
#include <cstrike>
#include <zombieplague>

/*
	Ownership keyed off the weapon, not off the player.

	This plugin used to hold ownership only in g_HasGalil[], cleared on connect,
	disconnect and death - but NOT on drop, even though drop_prim() drops the
	gun on every purchase. So the flag outlived the weapon: drop the galil and
	you still counted as holding a FrozenLava until you next died.

	That mattered once a second extra item started hijacking weapon_galil.
	cso_at15hw drops all primaries before handing over its own galil, so buying
	an AT15 while holding a FrozenLava left BOTH plugins believing they owned the
	same gun, and both wrote pev_viewmodel2 on deploy.

	The fix is the convention the rest of the server already uses: stamp the
	weapon entity's pev_impulse on drop and read it back on pickup, so the
	identity travels with the gun instead of with the player. Keys in use, all of
	which this must avoid: 5 (Scar_Born_Beast), 834 (balrogm4), 899 (cso_at15hw),
	1997 (zp_frost_m4a1), 110918273 (bak47p), 748120931 (Iron Beast) and the two
	51415444783563/564 that ak47_transformers_extra and the Angelic use.

	Unlike the Angelic this keeps its g_HasGalil[] flag rather than deriving
	everything from the entity - that would mean rewriting a dozen call sites in
	a plugin we did not write. The flag is now correct on drop, which is what the
	clash needed.
*/
#define EV_INT_WEAPONKEY   EV_INT_impulse
#define FROZENLAVA_KEY     20260816

#define is_valid_player(%1) (1 <= %1 <= 32)
new GALIL_V_MODEL[64] = "models/zombie_amxx_ru/v_blue_knight.mdl"
new GALIL_P_MODEL[64] = "models/zombie_amxx_ru/p_blue_knight.mdl"

new GL_V_MODEL[64] = "models/zombie_amxx_ru/v_buffm4_flx.mdl"
new GL_P_MODEL[64] = "models/zombie_amxx_ru/p_buffm4.mdl"
new cvar_dmgmultiplier, cvar_goldbullets,  cvar_custommodel, cvar_uclip
new dark_exp
new red_exp
new mod[33]
new userdd[33]
new bool:g_HasGalil[33], g_hasZoom[33]
 
new m_spriteTexture
new g_itemid
 
/*
	drop_prim used to test this mask, which is just the galil - so buying this while
	holding an extra item built on another base left both primaries in hand. give_item
	does not enforce the one-primary rule the buy menu does, and cso_at15hw is on the
	galil, Scar_Born_Beast on the ump45, yt_weapon_balrogm4_0 on the m249.

	Kept because checkModel and the damage paths still read it as "is this the base
	weapon we hijack"; the dropping now uses the full primary set below.
*/
const Wep_galil = ((1<<CSW_GALIL))

const PRIMARY_WEAPONS_BIT_SUM =
	(1<<CSW_SCOUT)|(1<<CSW_XM1014)|(1<<CSW_MAC10)|(1<<CSW_AUG)|(1<<CSW_UMP45)|
	(1<<CSW_SG550)|(1<<CSW_GALIL)|(1<<CSW_FAMAS)|(1<<CSW_AWP)|(1<<CSW_MP5NAVY)|
	(1<<CSW_M249)|(1<<CSW_M3)|(1<<CSW_M4A1)|(1<<CSW_TMP)|(1<<CSW_G3SG1)|
	(1<<CSW_SG552)|(1<<CSW_AK47)|(1<<CSW_P90)
 
new const GUNSHOT_DECALS[] = { 41, 42, 43, 44, 45 }
 
public plugin_init()
{
    cvar_dmgmultiplier = register_cvar("zp_darknight_dmg_multiplier", "3.5")
    cvar_custommodel = register_cvar("zp_darknight_custom_model", "1")
    cvar_goldbullets = register_cvar("zp_darknight_gold_bullets", "1")
    cvar_uclip = register_cvar("zp_darknight_unlimited_clip", "1")
   
    register_plugin("M4a1 FrozenLava", "1.5", "Korab & Dazz")
 
    register_event("DeathMsg", "Death", "a")
    register_event("WeapPickup","checkModel","b","1=19")
    register_event("CurWeapon","checkWeapon","be","1=1")
 
    RegisterHam(Ham_TakeDamage, "player", "fw_TakeDamage")
    RegisterHam(Ham_Spawn, "player", "fwHamPlayerSpawnPost", 1)
    RegisterHam(Ham_TraceAttack, "worldspawn", "Fw_TraceAttack", 1)
    RegisterHam(Ham_TraceAttack, "func_breakable", "Fw_TraceAttack", 1)
    RegisterHam(Ham_TraceAttack, "func_wall", "Fw_TraceAttack", 1)
    RegisterHam(Ham_TraceAttack, "func_door", "Fw_TraceAttack", 1)
    RegisterHam(Ham_TraceAttack, "func_door_rotating", "Fw_TraceAttack", 1)
    RegisterHam(Ham_TraceAttack, "func_plat", "Fw_TraceAttack", 1)
    RegisterHam(Ham_TraceAttack, "func_rotating", "Fw_TraceAttack", 1)
 //   register_concmd("getgunofdeath","zp_flm4", ADMIN_ADMIN)
    register_forward(FM_CmdStart, "fw_CmdStart")

    // ownership follows the gun - see the note at the top of the file
    register_forward(FM_SetModel, "fw_SetModel")
    RegisterHam(Ham_Item_AddToPlayer, "weapon_galil", "fw_GalilAddToPlayer")
    // Keep this name at 31 characters or fewer. ZP holds item captions in an
    // ArrayCreate(32, 1) and compares the full name it was handed against the
    // truncated copy it read back from zp_extraitems.ini, so a 32-character
    // name never matches its own ini section: the override is ignored and a
    // fresh duplicate block is appended on every single map load. This was
    // "Zombie-Amxx.Ru - FrozenLava M4a1", exactly 32, and it had grown 41
    // copies of itself in the ini before anyone noticed.
    g_itemid = zp_register_extra_item("Zombie-Amxx.Ru - FrozenLava M4", 120, ZP_TEAM_HUMAN)
}
public plugin_natives()
{    
    register_native("give_flm4a1","zp_flm4")
}
public zp_extra_item_selected(player, itemid)
{
	if ( itemid == g_itemid )
	{
		zp_flm4(player)
	}
}

public Fw_TraceAttack(iEnt, iAttacker, Float:flDamage, Float:fDir[3], ptr, iDamageType)
{
    if(!is_valid_player(iAttacker))
        return
   
    static Float:flEnd[3]
    get_tr2(ptr, TR_vecEndPos, flEnd)
   
    if(get_user_weapon(iAttacker) == CSW_GALIL && g_HasGalil[iAttacker])
    {
        if(iEnt)
        {
            message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
            write_byte(TE_DECAL)
            engfunc(EngFunc_WriteCoord, flEnd[0])
            engfunc(EngFunc_WriteCoord, flEnd[1])
            engfunc(EngFunc_WriteCoord, flEnd[2])
            write_byte(GUNSHOT_DECALS[random_num (0, charsmax(GUNSHOT_DECALS))])
            write_short(iEnt)
            message_end()
        }
        else
        {
            message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
            write_byte(TE_WORLDDECAL)
            engfunc(EngFunc_WriteCoord, flEnd[0])
            engfunc(EngFunc_WriteCoord, flEnd[1])
            engfunc(EngFunc_WriteCoord, flEnd[2])
            write_byte(GUNSHOT_DECALS[random_num (0, charsmax(GUNSHOT_DECALS))])
            message_end()
        }
        message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
        write_byte(TE_GUNSHOTDECAL)
        engfunc(EngFunc_WriteCoord, flEnd[0])
        engfunc(EngFunc_WriteCoord, flEnd[1])
        engfunc(EngFunc_WriteCoord, flEnd[2])
        write_short(iAttacker)
        write_byte(GUNSHOT_DECALS[random_num (0, charsmax(GUNSHOT_DECALS))])
        message_end()
	
        engfunc(EngFunc_MessageBegin, MSG_PVS, SVC_TEMPENTITY, flEnd, 0)
        if(mod[iAttacker] == 2)
        {
        write_byte(TE_SPRITE)
        engfunc(EngFunc_WriteCoord,flEnd[0])
        engfunc(EngFunc_WriteCoord,flEnd[1])
        engfunc(EngFunc_WriteCoord,flEnd[2])
        write_short(red_exp)
        write_byte(5)
        write_byte(150)
        message_end()
        }
        else
        {
        write_byte(TE_SPRITE)
        engfunc(EngFunc_WriteCoord,flEnd[0])
        engfunc(EngFunc_WriteCoord,flEnd[1])
        engfunc(EngFunc_WriteCoord,flEnd[2])
        write_short(dark_exp)
        write_byte(5)
        write_byte(150)
        message_end()
        }
        if (get_pcvar_num(cvar_goldbullets))
        {
            new vec1[3], vec2[3]
            get_user_origin(iAttacker, vec1, 1)
            get_user_origin(iAttacker, vec2, 3)
           
           
            //BEAMENTPOINTS
if (mod[iAttacker] == 1)
        {
            message_begin( MSG_BROADCAST,SVC_TEMPENTITY)
            write_byte(0)
            write_coord(vec1[0])
            write_coord(vec1[1])
            write_coord(vec1[2])
            write_coord(vec2[0])
            write_coord(vec2[1])
            write_coord(vec2[2])
            write_short(m_spriteTexture)
            write_byte(1) // framestart
            write_byte(5) // framerate
            write_byte(2) // life
            write_byte(1) // width
            write_byte(0) // noise
            write_byte(0)     // r
            write_byte(0)       // g
            write_byte(255)       // b
            write_byte(200) // brightness
            write_byte(150) // speed
            message_end()
	}
        else
	{
        if(mod[iAttacker] == 2)
	{ 
            message_begin( MSG_BROADCAST,SVC_TEMPENTITY)
            write_byte(0)
            write_coord(vec1[0])
            write_coord(vec1[1])
            write_coord(vec1[2])
            write_coord(vec2[0])
            write_coord(vec2[1])
            write_coord(vec2[2])
            write_short(m_spriteTexture)
            write_byte(1) // framestart
            write_byte(5) // framerate
            write_byte(2) // life
            write_byte(3) // width
            write_byte(6) // noise
            write_byte(255)     // r
            write_byte(0)       // g
            write_byte(0)       // b
            write_byte(200) // brightness
            write_byte(150) // speed
            message_end()
	}
	}
        }
    }
}
 
public client_connect(id)
{
    g_HasGalil[id] = false
    mod[id] = 0
}
 
public client_disconnect(id)
{
    g_HasGalil[id] = false
    mod[id] = 0
}
 
/*
	Death deliberately does NOT clear ownership any more.

	It used to, and that raced the drop: dying makes CS build a weaponbox for the
	primary, fw_SetModel fires to model it, and by then this had already zeroed the
	flag it tests - so the FROZENLAVA_KEY was never stamped and the identity was
	destroyed instead of handed to the gun on the ground. Dying is the most common
	way this weapon changes hands, so that was the main path, not an edge case.

	fw_SetModel clears the flag itself once the key is on the weapon, and
	zp_user_infected_post clears it when you turn. Between them every real way of
	losing the gun is covered, and it now matches what the comment in
	zp_user_infected_post has claimed all along: kept across death and respawn.
*/
public Death()
{
}
 
public fwHamPlayerSpawnPost(id)
{
    // Ownership survives respawn - cleared on connect, disconnect, infection and
    // drop. But mod[] is the rage tier and it has to be rebuilt in step with it:
    // zeroing mod while g_HasGalil stayed set left the two halves disagreeing, and
    // fw_TakeDamage reads mod == 1 for the 3.5x tier and treats ANYTHING ELSE as
    // "charge finished" - so mod 0 jumped straight to the 5.25x tier on the first
    // bullet after every respawn, with no charge-up and on a gun the player may no
    // longer even be carrying.
    mod[id] = g_HasGalil[id] ? 1 : 0
}
 
public plugin_precache()
{
    precache_model(GALIL_V_MODEL)
    precache_model(GALIL_P_MODEL)
    precache_model(GL_V_MODEL)
    precache_model(GL_P_MODEL)
    m_spriteTexture = precache_model("sprites/dot.spr")
    precache_sound("weapons/zoom.wav")
    dark_exp=precache_model("sprites/zombie_amxx_ru/blue_explode.spr")
    red_exp=precache_model("sprites/zombie_amxx_ru/red_explode.spr")
}
 
public zp_user_infected_post(id)
{
    if (zp_get_user_zombie(id))
    {
        g_HasGalil[id] = false   // restored by setup: infection = you lose the weapon (ZP strips it anyway). Still kept across humanize/death/respawn/round.
        mod[id] = 0
    }
}
 
public checkModel(id)
{
    if ( zp_get_user_zombie(id) )
        return PLUGIN_HANDLED
   
    new szWeapID = read_data(2)
   
    if ( szWeapID == CSW_GALIL && g_HasGalil[id] == true && get_pcvar_num(cvar_custommodel) )
    {	
    if(mod[id] == 1)
    {
        set_pev(id, pev_viewmodel2, GALIL_V_MODEL)
        set_pev(id, pev_weaponmodel2, GALIL_P_MODEL)
    }
    else
    {
        set_pev(id, pev_viewmodel2, GL_V_MODEL)
        set_pev(id, pev_weaponmodel2, GL_P_MODEL)    	
    }
    }
    return PLUGIN_HANDLED
}
 
public checkWeapon(id)
{
    new plrClip, plrAmmo, plrWeap[32]
    new plrWeapId
   
    plrWeapId = get_user_weapon(id, plrClip , plrAmmo)
   
    if (plrWeapId == CSW_GALIL && g_HasGalil[id])
    {
        checkModel(id)
    }
    else
    {
        return PLUGIN_CONTINUE
    }
   
    if (plrClip == 0 && get_pcvar_num(cvar_uclip))
    {
        // If the user is out of ammo..
        get_weaponname(plrWeapId, plrWeap, 31)
        // Get the name of their weapon
        give_item(id, plrWeap)
        engclient_cmd(id, plrWeap)
        engclient_cmd(id, plrWeap)
        engclient_cmd(id, plrWeap)
    }
    return PLUGIN_HANDLED
}
 
 
 
public fw_TakeDamage(victim, inflictor, attacker, Float:damage)
{
    if ( is_valid_player( attacker ) && get_user_weapon(attacker) == CSW_GALIL && g_HasGalil[attacker] )
    {
	if(mod[attacker] == 1)
	{
        SetHamParamFloat(4, damage * get_pcvar_float( cvar_dmgmultiplier ) )
	}
	else
	{
	if(mod[attacker] == 2)
	{
        SetHamParamFloat(4, damage * get_pcvar_float( cvar_dmgmultiplier ) * 1.5 )
	}
	}
    }
    if ( is_valid_player( attacker ) && get_user_weapon(attacker) == CSW_GALIL && g_HasGalil[attacker] )
	{
	if(mod[attacker] == 1 && userdd[attacker] < 50)
	{
	userdd[attacker] += 1
	}
	else
	{
	mod[attacker] = 2
	userdd[attacker] = 0
	set_task(5.5 , "backtnormal", attacker)
	}
	}

}
public backtnormal(attacker)
{
	mod[attacker] = 1
}
public fw_CmdStart( id, uc_handle, seed )
{
    if( !is_user_alive( id ) )
        return PLUGIN_HANDLED
   
    if( ( get_uc( uc_handle, UC_Buttons ) & IN_ATTACK2 ) && !( pev( id, pev_oldbuttons ) & IN_ATTACK2 ) )
    {
        new szClip, szAmmo
        new szWeapID = get_user_weapon( id, szClip, szAmmo )
       
        if( szWeapID == CSW_GALIL && g_HasGalil[id] == true && !g_hasZoom[id] == false)
        {
            g_hasZoom[id] = false
            cs_set_user_zoom( id, CS_SET_AUGSG552_ZOOM, 0 )
            emit_sound( id, CHAN_ITEM, "weapons/zoom.wav", 0.20, 2.40, 0, 100 )
        }
       
        else if ( szWeapID == CSW_GALIL && g_HasGalil[id] == true && g_hasZoom[id])
        {
            g_hasZoom[ id ] = false
            cs_set_user_zoom( id, CS_RESET_ZOOM, 0 )
           
        }
       
    }
    return PLUGIN_HANDLED
}
 
public zp_flm4(player)
{
        if (user_has_weapon(player, CSW_GALIL))
            drop_prim(player)
	    
        give_item(player, "weapon_galil")
        // was "Ты купил FrozenLava DarkM4a1" in the shipped source; the
        // Cyrillic did not survive being saved back out and had turned into
        // "?? ?????". Same meaning, in a charset the client can draw.
        client_print(player, print_chat, "[ZA.RU] You bought the FrozenLava DarkM4a1")
        g_HasGalil[player] = true
	   mod[player] = 1
}
 
/*
	Dropped: hand the identity to the weapon entity and stop claiming it.

	The weaponbox model is deliberately left alone. This gun has no w_ model of
	its own - only v_ and p_ - so there is nothing to swap in, and returning
	IGNORED rather than SUPERCEDE keeps cso_at15hw's own hook on this same event
	working for its galil.
*/
public fw_SetModel(entity, model[])
{
	if (!is_valid_ent(entity))
		return FMRES_IGNORED

	static szClassName[33]
	entity_get_string(entity, EV_SZ_classname, szClassName, charsmax(szClassName))

	if (!equal(szClassName, "weaponbox"))
		return FMRES_IGNORED

	if (!equal(model, "models/w_galil.mdl"))
		return FMRES_IGNORED

	static iOwner, iStored
	iOwner = entity_get_edict(entity, EV_ENT_owner)

	if (!is_valid_player(iOwner) || !g_HasGalil[iOwner])
		return FMRES_IGNORED

	iStored = find_ent_by_owner(-1, "weapon_galil", entity)

	if (!is_valid_ent(iStored))
		return FMRES_IGNORED

	// do not overwrite a claim cso_at15hw already stamped in this same slot - it
	// hijacks weapon_galil too and its hook runs on the same weaponbox
	if (entity_get_int(iStored, EV_INT_WEAPONKEY) != 0)
		return FMRES_IGNORED

	entity_set_int(iStored, EV_INT_WEAPONKEY, FROZENLAVA_KEY)

	g_HasGalil[iOwner] = false
	mod[iOwner] = 0

	return FMRES_IGNORED
}

// Picked up: if this galil is the one that was dropped, it is a FrozenLava again
public fw_GalilAddToPlayer(galil, id)
{
	if (!is_valid_ent(galil) || !is_user_connected(id))
		return HAM_IGNORED

	if (entity_get_int(galil, EV_INT_WEAPONKEY) != FROZENLAVA_KEY)
		return HAM_IGNORED

	g_HasGalil[id] = true
	mod[id] = 1

	// consumed, so a later plain galil in this entity slot is not mistaken for one
	entity_set_int(galil, EV_INT_WEAPONKEY, 0)

	return HAM_IGNORED
}

stock drop_prim(id)
{
    new weapons[32], num
    get_user_weapons(id, weapons, num)
    for (new i = 0; i < num; i++) {
        if (PRIMARY_WEAPONS_BIT_SUM & (1<<weapons[i]))
        {
            static wname[32]
            get_weaponname(weapons[i], wname, sizeof wname - 1)
            engclient_cmd(id, "drop", wname)
	   mod[id] = 0
        }
    }
}
