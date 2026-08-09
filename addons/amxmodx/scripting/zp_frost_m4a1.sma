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
new bool:g_bHasFrostM4A1[33], g_bIsFrozen[33]
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
	RegisterHam(Ham_Item_AddToPlayer, "weapon_m4a1", "fw_FrostM4A1AddToPlayer")
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
	g_bHasFrostM4A1[id] = false
	g_bIsFrozen[id] = false
}

public client_disconnect(id)
{
	g_bHasFrostM4A1[id] = false
	g_bIsFrozen[id] = false
	RemoveEntity(id)
}

public zp_extra_item_selected(player, itemid)
{
	if (itemid == g_iItemID) 
	{
		g_bHasFrostM4A1[player] = true
		ham_strip_weapon(player, "weapon_m4a1")
		give_item(player, "weapon_m4a1")
		cs_set_user_bpammo(player, CSW_M4A1, 90)
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
	
	if(get_user_weapon(iAttacker) != CSW_M4A1 || !g_bHasFrostM4A1[iAttacker])
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
	if (g_bHasFrostM4A1[infected])
	{
		g_bHasFrostM4A1[infected] = false   // restored by setup: infection = you lose the weapon (ZP strips it anyway). Still kept across humanize/death/respawn/round.
	}
}

public zp_user_humanized_post(id)
{
	// g_bHasFrostM4A1[id] = false   // unified by setup: ownership survives infect/humanize/death/respawn/round; cleared only on connect, disconnect, drop
	g_iDmg[id] = 0
	RemoveEntity(id)
}

public event_round_start()
{
	for (new i = 1; i <= g_iMaxPlayers; i++)
	{
		// g_bHasFrostM4A1[i] = false   // disabled by setup: every other weapon plugin keeps ownership across rounds; it is still cleared on infection / humanize / disconnect / drop
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

	if(g_bHasFrostM4A1[attacker] && (get_user_weapon(attacker) == CSW_M4A1))
		SetHamParamFloat(4, damage * get_pcvar_num(g_iDmgMultiplier))
	
	// For Frost Effect Ring
	static Float:originF[3]
	pev(victim, pev_origin, originF)
	
	// For Frost Effect Sound
	static originF2[3] 
	get_user_origin(victim, originF2)
	
	if((get_user_weapon(attacker) == CSW_M4A1) && g_bHasFrostM4A1[attacker])
	{
		g_iDmg[attacker] += (floatround(damage) * get_pcvar_num(g_iDmgMultiplier))
	}
	
	if((g_iDmg[attacker] >= get_pcvar_num(g_iFreezeDmg)) && (get_user_weapon(attacker) == CSW_M4A1) && g_bHasFrostM4A1[attacker])
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
	if ((get_user_weapon(id) == CSW_M4A1) && g_bHasFrostM4A1[id] == true)
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

	new className[33]
	entity_get_string(entity, EV_SZ_classname, className, 32)

	static iOwner, iStoredM4A1ID

	// Frost M4A1 Owner
	iOwner = entity_get_edict(entity, EV_ENT_owner)

	// Get drop weapon index (Frost M4A1) to use in fw_FrostM4A1AddToPlayer forward
	iStoredM4A1ID = find_ent_by_owner(-1, "weapon_m4a1", entity)

	// If Player Has Frost M4A1 and It's weapon_m4a1
	if(g_bHasFrostM4A1[iOwner] && is_valid_ent(iStoredM4A1ID))
	{
		// Setting weapon options
		entity_set_int(iStoredM4A1ID, EV_INT_impulse, 1997)

		// Rest Var
		g_bHasFrostM4A1[iOwner] = false
		
		// Set weaponbox new model
		entity_set_model(entity, W_M4A1_MODEL)
		return FMRES_SUPERCEDE
	}
	return FMRES_IGNORED
}

public fw_FrostM4A1AddToPlayer(FrostM4A1, id)
{
	// Make sure that this is M4A1
	if(is_valid_ent(FrostM4A1) && is_user_connected(id) && entity_get_int(FrostM4A1, EV_INT_impulse) == 1997)
	{
		// Update Var
		g_bHasFrostM4A1[id] = true

		// Reset weapon options
		entity_set_int(FrostM4A1, EV_INT_impulse, 0)
		return HAM_HANDLED
	}
	return HAM_IGNORED
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

	if(!is_user_alive(id) || !g_bHasFrostM4A1[id])
		return

	CheckModel(id)
}
