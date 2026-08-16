/*
	[ZP] Extra Item: M4A1-S Angelic Beast
	-------------------------------------
	Built for this server from the CrossFire M4A1-S model pack.

	Matches the CrossFire wiki entry where the engine allows it: 52 round clip
	in mutation modes, movement speed up under 30% ammo, buttplate melee, and
	ultra-fast reload. The team buffs (Awakening on M, jump boost, +2 rifle
	ammo, Energy Absorb) have no equivalent in ZP and are not implemented.

	Behaviour
	    - base weapon is the M4A1, clip raised to 52
	    - right click stabs instead of toggling the silencer, reaching 3.5m
	      rather than the stock knife's metre or so, for a flat 1000 that
	      lands as 750 once ZP's zombie armor has taken its cut
	    - under 30% ammo the gun "awakens": second animation set, faster
	      movement, and a short centre-screen line
	    - recoil and rate of fire are CrossFire's own numbers for the
	      M4A1-S Prism Beast, and accuracy is pinned

	Notes on the assets
	    The pack shipped its models under the stock names (v_m4a1.mdl etc), so
	    they were renamed into models/angelic/ during install. Dropping them in
	    as-is would have reskinned every M4A1 in the game instead of just this
	    item. Sounds were moved to sound/angelic/ for the same reason.

	    The model has two animation sets, 0-6 and 7-13. They are NOT copies -
	    seq 4 racks the charging handle while seq 11 thumbs the bolt release.
	    Firing and idle follow the awakened state; the reload alternates
	    between the two instead, because a reload almost always happens while
	    awakened and seq 4 would otherwise never be seen.

	    v_angelic.mdl has been edited: the two reload sequences were re-timed
	    from 52fps to 76.2fps so the animation finishes inside the 2.1s reload
	    rather than being cut off. Original kept as v_angelic.mdl.orig.

	Load order
	    No longer constrained. zp_round_rules used to read the damage value
	    to decide whether a lethal hit was allowed to land, so anything with
	    a damage multiplier had to load first. It no longer inspects damage
	    at all.

	Ownership follows the same rule as every other weapon on this server:
	lost on infection, connect, disconnect and drop - kept across rounds.

	cvars
	    zp_angelic_cost         menu price in ammo packs (read at map start)
	    zp_angelic_dmg          bullet damage multiplier
	    zp_angelic_clip         rounds per clip
	    zp_angelic_ammo         reserve ammo
	    zp_angelic_stab_dmg     flat stab damage, before ZP's zombie armor
	    zp_angelic_stab_range   stab reach in units (39.37 units = 1 metre)
	    zp_angelic_recoil_mode  0 = scale the stock kick by zp_angelic_recoil
	                            1 = CrossFire Prism Beast KickBack numbers
	    zp_angelic_recoil       punch multiplier for mode 0 only
	    zp_angelic_interval     seconds between shots, 0.0 = weapon's own
	    zp_angelic_deploy_time  draw time in seconds, 0.0 = weapon's own
	    zp_angelic_speed        speed multiplier while awakened
	    zp_angelic_threshold    clip fraction that triggers the awakened state
	    zp_angelic_reload_time  must match the re-timed animation length
	    zp_angelic_decals       hand-drawn bullet holes
	    zp_angelic_awaken_msg   centre-screen line on awakening
*/

#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <cstrike>
#include <engine>       // playback_event
#include <fun>          // give_item
#include <xs>
#include <zombieplague>
/*
	reapi is a HARD dependency from here on, like zp_round_rules - there is no
	#if defined guard, so this plugin will not load without the module. modules.ini
	has reapi enabled.

	It is here for the one CrossFire number that could never be ported: bullet
	spread. The Prism Beast controls it with moderator 0.5 and resetTime 0.3, an
	accuracy-recovery model CS has no equivalent for - CS bakes the cone into each
	weapon's own fire code, computed from m_flAccuracy, and the only lever from
	outside is to pin that value. Which this has been doing, and which has never
	been shown to move anything. ReGameDLL exposes the call that uses the cone, so
	the cone itself becomes editable.
*/
#include <reapi>

#define PLUGIN  "[ZP] Extra Item: M4A1-S Angelic Beast"
#define VERSION "1.0"
#define AUTHOR  "setup"

new const V_MODEL[] = "models/angelic/v_angelic.mdl"
new const P_MODEL[] = "models/angelic/p_angelic.mdl"
new const W_MODEL[] = "models/angelic/w_angelic.mdl"
new const W_STOCK[] = "models/w_m4a1.mdl"

new const SND_FIRE[2][] = { "angelic/fire1.wav", "angelic/fire2.wav" }
new const SND_STAB[]    = "angelic/stab.wav"
new const SND_DRAW[]    = "angelic/draw.wav"
new const SND_CLIPIN[]   = "angelic/clipin.wav"
new const SND_CLIPOUT[]  = "angelic/clipout.wav"
new const SND_BLOWBACK[] = "angelic/blowback.wav"

/*
	A reload is three beats - magazine out, magazine in, bolt - and each is
	expressed as a fraction of whatever zp_angelic_reload_time is set to, so
	they stay lined up if that number is changed.

	The fractions are not tuned by ear. The model carries the animator's own
	studio events, id 5004 with a frame number, and

	    fraction = event frame / sequence frame count

	makes fraction * reload_time land exactly on the event's own time, given
	the sequence has been re-timed so that frames/fps equals the reload time -
	which is the case here, 160 frames at 76.19 fps = 2.1s.

	The bolt needs one fraction per animation. Both reloads pull and seat the
	magazine on frames 20 and 60, but seq 4 blows the bolt back on frame 116
	and seq 11 on frame 106, 131ms apart, so any single constant is right for
	one of them and wrong for the other. That was the defect: 0.71 for both put
	seq 4 within 31ms and left seq 11 100ms late. Note this is the opposite way
	round from what docs/2026-08-16-handoff.md recorded by ear.

	tools/check_reload_timing.ps1 reads the events back out of the model and
	compares them against these cvars, so they cannot drift apart unnoticed.
*/
#define TASK_CLIPOUT 7000
#define TASK_CLIPIN  7100
#define TASK_BOLT    7200

// bullet holes come from the fire event, which is blocked to kill the stock
// report - so they have to be drawn by hand
new g_iDecals[5]
new bool:g_bDecalsOk

// two animation sets baked into the model: calm 0-6, awakened 7-13
#define ANIM_IDLE   0
#define ANIM_FIRE   1
#define ANIM_RELOAD 4
#define ANIM_DRAW   5
#define ANIM_STAB   6
#define ANIM_AWAKE_OFFSET 7

/*
	The stab lockout is a cvar now, and 0.85 was too long.

	Measured off v_angelic.mdl: sequence 6 "knife-attack" is 67 frames at 100 fps =
	0.670s. The 0.85 this used to hold came from CrossFire's Born Beast variant
	(intervalTime 0.070|0.85), not the Prism Beast the rest of this gun is matched
	to - that one's melee cooldown is 0.55. So the gun sat locked for 180ms after
	the hands were already back on it, with BOTH mouse buttons dead, which at 3.5m
	is long enough for the next zombie to reach you.

	0.55 is not available here: it is shorter than the animation, and cutting the
	stab off is the defect the reload work was undone by. The animation length is
	the floor, so 0.67. The Iron Beast's own stab is shorter and does get 0.55.

	If the model is ever re-timed this has to follow it, the same way
	zp_angelic_reload_time does.
*/

// what the reload ran at before it was re-timed: 160 frames at 52 fps. The
// sequences are 76.19 fps now so those same frames finish on
// zp_angelic_reload_time's 2.1s. Unused, kept as the record of the original.
#define RELOAD_TIME 3.08

/*
	Recoil lifted from the CrossFire source data.

	Taken out of SUIC_WEAPON_MAIN.RC in the CSCF Yasou 3.0 package, section
	[M4A1_S_PRISMBEAST]. The seven numbers per stance map one to one onto the
	engine's own

	    CBasePlayer::KickBack( up_base, lateral_base, up_modifier,
	                           lateral_modifier, up_max, lateral_max,
	                           direction_change )

	and the whole character of the gun is in the last two of them. Stock CS
	lets an M4A1 accumulate to roughly 3.5 up and 2.5 sideways; this caps at
	0.8 and 0.5. Note that up_base is itself 0.8, so the vertical punch is
	already sitting on its ceiling from the very first round and simply stays
	there - the gun does not climb, it just holds a small fixed offset that
	decays between shots. That is the "steady" feel, and it is why up_modifier
	barely matters.
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

// the burst counter is kept here rather than read out of the engine's
// m_iShotsFired: the two offset tables on this machine disagree about where
// that lives, and nothing about this model needs the engine's copy
new g_iShotsFired[33]
new g_iKickDir[33]
new Float:g_fLastShot[33]

/*
	Recoil tracing, buffered.

	The obvious place to log a recoil curve is next to the code that produces
	it - which is the firing path, and a log_amx there is what put the frame
	rate on the floor last time. At 0.070 between shots that would now be
	fourteen synchronous disk writes a second.

	So nothing is written while the trigger is down. Each shot drops two
	floats into an array, and the whole burst goes out as a single line once
	the trigger has been released. One write per burst instead of per round.
*/
#define KICK_TRACE_MAX 24

new const STANCE_NAME[4][] = { "stand", "duck", "walk", "air" }

new Float:g_fTraceX[33][KICK_TRACE_MAX]
new Float:g_fTraceY[33][KICK_TRACE_MAX]
new g_iTraceN[33]
new g_iTraceStance[33]
new g_iTraceFlips[33]
new bool:g_bTraceMixed[33]

// pdata offsets - the usual CS 1.6 ones
#define OFF_WEAPON_PLAYER         41
#define OFF_WEAPON_NEXT_PRIMARY   46
#define OFF_WEAPON_NEXT_SECONDARY 47
#define OFF_WEAPON_TIME_IDLE      48
#define OFF_WEAPON_CLIP           51
#define OFF_WEAPON_IN_RELOAD      54
#define OFF_WEAPON_ACCURACY       71
#define OFF_PLAYER_NEXT_ATTACK    83
#define OFF_PLAYER_ACTIVE_ITEM   373
#define LINUX_WEAPON               4
#define LINUX_PLAYER               5

/*
	Ownership lives on the weapon, not on the player.

	The obvious shape - a bool per player saying "this one bought the Angelic"
	- cannot answer the question that actually matters, because more than one
	plugin claims weapon_m4a1. zp_frost_m4a1 does too. With a flag each and no
	knowledge of one another, buying both leaves both flags set: every hook in
	both plugins fires on the same weapon, the models overwrite each other and
	the clip ends up whichever plugin enforces it hardest. Buying Angelic then
	Frost gave a Frost-looking rifle with Angelic's 52-round clip.

	Stamping the entity fixes it structurally rather than case by case. An
	entity carries exactly one key, so two plugins can never both own it, and
	neither has to know the other exists. Replacing the weapon replaces the
	identity along with it. A third M4A1 item could be added tomorrow and
	nothing here would need touching.

	This is already the convention on this server - ak47_transformers_extra,
	zp_weapon_ak47_beast, zp_extra_bak47p and zombie_plague40 itself all key
	off pev_impulse. This plugin and zp_frost_m4a1 were the two that did not.

	Consequence worth stating: the identity now travels with the gun. Drop it
	and it is still an Angelic on the ground; whoever picks it up gets the
	Angelic. That replaces the old "ownership is lost on drop" rule, and it is
	the behaviour every other weapon in the game already has.
*/
#define ANGELIC_KEY          51415444783564
#define Is_Angelic(%0)       (pev_valid(%0) && pev(%0, pev_impulse) == ANGELIC_KEY)
new bool:g_bAwake[33]

/*
	Raised only around the stab's own TakeDamage call, so the damage hook can
	tell a stab from a bullet.

	The obvious test - comparing the incoming damage against
	zp_angelic_stab_dmg - looks like it should work and never fires. ZP loads
	first, so its own TakeDamage hook runs first, and on a normal zombie it
	multiplies the damage by zp_zombie_armor and writes it back with
	SetHamParamFloat before this plugin sees anything. The number that arrives
	is 0.75 of the one that was sent, the comparison misses, and the stab
	picks up the bullet multiplier on top of itself.
*/
new bool:g_bStabbing[33]
new Float:g_fPushAngle[33][3]
new g_iFireIndex[33]
new bool:g_bInPrimaryAttack

// true only for the window inside the original PrimaryAttack where the bullet
// traces run, so Fw_TraceAttack can test it instead of searching for the weapon
new bool:g_bFiringAngelic[33]

// reload bookkeeping: CS refills to the M4A1's own 30 round cap, so the real
// clip has to be rebuilt afterwards from values captured before it ran
new g_iTmpClip[33]   // clip captured before CS refills it, -1 = no reload running

// the model ships two different reload animations - seq 4 racks the charging
// handle, seq 11 thumbs the bolt release. The showcase video alternates them,
// so this flips on every reload instead of following the awakened state,
// which in practice is always on by the time anyone reloads.
new bool:g_bAltReload[33]

// the stock M4A1 fire event, captured at precache time so only that one event
// gets superceded instead of everything that fires during an attack
new g_iOrigFireEvent

new g_iItemId, g_iMaxPlayers
new g_pDmg, g_pClip, g_pAmmo, g_pStabDmg, g_pStabRange, g_pRecoil, g_pSpeed, g_pThreshold, g_pReloadTime, g_pDecals, g_pAwakenMsg
new g_pDebug, g_pRecoilMode, g_pInterval, g_pDeployTime, g_pDecalReal, g_pStabDelay, g_pSpreadScale
new g_pFracClipOut, g_pFracClipIn, g_pFracBolt, g_pFracBoltAlt

public plugin_precache()
{
	precache_model(V_MODEL)
	precache_model(P_MODEL)
	precache_model(W_MODEL)

	for (new i = 0; i < sizeof SND_FIRE; i++)
		precache_sound(SND_FIRE[i])

	precache_sound(SND_STAB)
	precache_sound(SND_DRAW)
	precache_sound(SND_CLIPIN)
	precache_sound(SND_CLIPOUT)
	precache_sound(SND_BLOWBACK)

	g_iDecals[0] = engfunc(EngFunc_DecalIndex, "{bigshot1")
	g_iDecals[1] = engfunc(EngFunc_DecalIndex, "{bigshot2")
	g_iDecals[2] = engfunc(EngFunc_DecalIndex, "{bigshot3")
	g_iDecals[3] = engfunc(EngFunc_DecalIndex, "{bigshot4")
	g_iDecals[4] = engfunc(EngFunc_DecalIndex, "{bigshot5")

	// an index of -1 means the decal was not found, and writing that into a
	// temp entity message hands the client a decal slot that does not exist -
	// which is a crash, not a missing texture
	g_bDecalsOk = true

	for (new i = 0; i < sizeof g_iDecals; i++)
	{
		if (g_iDecals[i] <= 0)
			g_bDecalsOk = false
	}

	log_amx("[ANGELIC] decal indices %d %d %d %d %d -> usable=%d",
		g_iDecals[0], g_iDecals[1], g_iDecals[2], g_iDecals[3], g_iDecals[4], g_bDecalsOk ? 1 : 0)
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	g_pDmg       = register_cvar("zp_angelic_dmg", "2.5")
	g_pClip      = register_cvar("zp_angelic_clip", "52")
	g_pAmmo      = register_cvar("zp_angelic_ammo", "156")
	/*
		1000 sent, 750 landed. ZP takes zp_zombie_armor (0.75) off any damage
		a human deals to a normal zombie, so this number is pre-armor. A
		nemesis is exempt from the armor and eats the full 1000.
	*/
	g_pStabDmg   = register_cvar("zp_angelic_stab_dmg", "1000.0")

	// 3.5 metres. GoldSrc measures in units of one inch, so a metre is 39.37
	// of them - the stock knife reaches 48, which is a bit over a metre.
	g_pStabRange = register_cvar("zp_angelic_stab_range", "137.8")

	g_pRecoil    = register_cvar("zp_angelic_recoil", "0.15")

	/*
		0 = the old model, which just scales down whatever kick the stock
		    M4A1 produced, using zp_angelic_recoil
		1 = CrossFire's own KickBack numbers for the Prism Beast

		Both paths are kept so the two can be compared live without a
		recompile - the point of this was to match a feel, and a feel is
		judged by flipping between them.
	*/
	g_pRecoilMode = register_cvar("zp_angelic_recoil_mode", "1")

	// CrossFire fires this at 0.070 (~857 rpm) against the stock M4A1's
	// 0.0875 (~686). 0.0 leaves the weapon's own rate alone.
	g_pInterval = register_cvar("zp_angelic_interval", "0.070")

	g_pDeployTime = register_cvar("zp_angelic_deploy_time", "0.81")
	g_pSpeed     = register_cvar("zp_angelic_speed", "1.30")
	g_pThreshold = register_cvar("zp_angelic_threshold", "0.30")
	g_pReloadTime = register_cvar("zp_angelic_reload_time", "2.1")   // wiki: Ultra-Fast Reload

	// Where the three reload sounds sit, as fractions of the reload time. Read
	// straight off the model's studio events - see the note beside TASK_CLIPOUT.
	// The sound files need no transient correction: measured, every one of them
	// has its onset inside its first 0.02s and its peak by 0.05s.
	g_pFracClipOut = register_cvar("zp_angelic_frac_clipout",  "0.125")    // frame 20 of 160, both animations
	g_pFracClipIn  = register_cvar("zp_angelic_frac_clipin",   "0.375")    // frame 60 of 160, both animations
	g_pFracBolt    = register_cvar("zp_angelic_frac_bolt",     "0.725")    // seq 4,  frame 116 of 160
	g_pFracBoltAlt = register_cvar("zp_angelic_frac_bolt_alt", "0.6625")   // seq 11, frame 106 of 160

	// verified in game: the five {bigshot decals resolve to 199-203 and draw
	// without upsetting the client. plugin_precache still checks them and
	// disables the whole thing if any comes back <= 0.
	g_pDecals = register_cvar("zp_angelic_decals", "1")

	// 1 = a hole at each real impact, spread and all
	// 0 = the old single hole on the crosshair, which flattered the gun
	g_pDecalReal = register_cvar("zp_angelic_decal_real", "1")

	// seconds both mouse buttons stay locked after a stab - see the note beside
	// ANIM_STAB. 0.67 is the measured length of sequence 6.
	g_pStabDelay = register_cvar("zp_angelic_stab_delay", "0.67")

	/*
		Bullet cone multiplier. 1.0 leaves the M4A1's own spread alone.

		This is a real percentage on the cone the engine is about to fire with, so
		unlike zp_angelic_accuracy_cap-style levers it does not depend on
		m_flAccuracy being reachable at all.
	*/
	g_pSpreadScale = register_cvar("zp_angelic_spread_scale", "0.5")

	// checked, because a hook that silently fails to attach would leave a cvar in
	// the config doing nothing - the exact trap the accuracy pin turned out to be
	if (!RegisterHookChain(RG_CBaseEntity_FireBullets3, "Fw_FireBullets3_Pre", false))
		log_amx("[ANGELIC] RegisterHookChain(FireBullets3) FAILED - zp_angelic_spread_scale will do nothing")

	g_pAwakenMsg = register_cvar("zp_angelic_awaken_msg", "1")

	// stab tracing. Live switch rather than a recompile, so it can be turned
	// off the moment the answer is in.
	g_pDebug = register_cvar("zp_angelic_debug", "1")

	new pCost = register_cvar("zp_angelic_cost", "85")
	g_iItemId = zp_register_extra_item("M4A1-S Angelic Beast", get_pcvar_num(pCost), ZP_TEAM_HUMAN)

	RegisterHam(Ham_Item_Deploy,            "weapon_m4a1", "Fw_Deploy_Post",    1)
	RegisterHam(Ham_Weapon_PrimaryAttack,   "weapon_m4a1", "Fw_Primary_Pre",    0)
	RegisterHam(Ham_Weapon_PrimaryAttack,   "weapon_m4a1", "Fw_Primary_Post",   1)
	RegisterHam(Ham_Weapon_SecondaryAttack, "weapon_m4a1", "Fw_Secondary_Pre",  0)
	RegisterHam(Ham_Weapon_Reload,          "weapon_m4a1", "Fw_Reload_Pre",     0)
	RegisterHam(Ham_Weapon_Reload,          "weapon_m4a1", "Fw_Reload_Post",    1)
	RegisterHam(Ham_Item_PostFrame,         "weapon_m4a1", "Fw_ItemPostFrame",  0)
	RegisterHam(Ham_TakeDamage,             "player",      "Fw_TakeDamage_Pre", 0)

	/*
		Real bullet holes.

		DrawBulletHole below stamps ONE hole straight down v_angle with no spread
		applied, so it marks where the player aimed rather than where the round
		went. That is what made this gun read as pinpoint accurate, and it is why
		clamping m_flAccuracy appeared to work - nobody could see the difference,
		because the holes never showed the spread in the first place.

		These hooks draw at the real trace endpoints instead. The fire event is
		blocked for this weapon, so there are no client-side holes to double up
		with and this is the only set.
	*/
	/*
		The classname list is not guesswork. DrawBulletHole marked anything solid
		it traced into, so replacing it with per-classname hooks can only lose
		coverage - I grepped the entity lumps of all 20 zm_cf_*.bsp on this server
		for solid brush entities and got:

		    func_wall 286, func_illusionary 137, func_breakable 59,
		    func_conveyor 27, func_buyzone 16, func_wall_toggle 9, func_water 8,
		    func_ladder 7, func_bomb_target 3, func_rotating 1, func_door 1

		func_conveyor and func_wall_toggle were the two solid ones missing. The
		rest of that list is deliberately not hooked: illusionary, buyzone, ladder
		and bomb_target are non-solid, so a bullet never traces against them, and
		water takes no decal. func_plat and func_door_rotating appear in none of
		these maps but are kept for maps added later.
	*/
	RegisterHam(Ham_TraceAttack, "worldspawn",         "Fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_breakable",     "Fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_wall",          "Fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_wall_toggle",   "Fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_conveyor",      "Fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_door",          "Fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_door_rotating", "Fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_plat",          "Fw_TraceAttack", 1)
	RegisterHam(Ham_TraceAttack, "func_rotating",      "Fw_TraceAttack", 1)

	register_forward(FM_SetModel,      "Fw_SetModel")
	register_forward(FM_PlaybackEvent, "Fw_PlaybackEvent")
	register_forward(FM_PrecacheEvent, "Fw_PrecacheEvent_Post", 1)
	register_forward(FM_UpdateClientData, "Fw_UpdateClientData_Post", 1)

	register_event("CurWeapon", "Event_CurWeapon", "be", "1=1")

	g_iMaxPlayers = get_maxplayers()
}

/*
	These reset per-player state only. There is no ownership left to clear:
	the weapon carries that, and it goes away with the weapon - stripped on
	infection, gone on disconnect, and simply not held any more once dropped.
*/
public client_connect(id)
{
	g_bAwake[id] = false
	g_bStabbing[id] = false
	g_iShotsFired[id] = 0
	g_iKickDir[id] = 0
}

public client_disconnected(id)
{
	g_bAwake[id] = false
	g_bStabbing[id] = false
	g_iShotsFired[id] = 0
	g_iKickDir[id] = 0
}

public zp_user_infected_post(id, infector)
{
	g_bAwake[id] = false
}

public zp_extra_item_selected(id, itemid)
{
	if (itemid != g_iItemId)
		return

	GiveAngelic(id)
}

GiveAngelic(id)
{
	if (!is_user_alive(id))
		return

	/*
		Drop the M4A1 already held, then hand over a fresh one.

		The plugin used to reuse whatever M4A1 was in hand and lean on
		engclient_cmd to force a redeploy. That only works when the player is
		holding something else: CS ignores a select command for the weapon
		already active, so no deploy fired and buying the item while holding a
		plain M4A1 left the stock skin, draw and sound in place.

		Removing the old weapon by hand - RetireWeapon, RemovePlayerItem,
		Item_Kill, clear the pev_weapons bit - was tried and is worse. It
		destroys the entity while m_pActiveItem still points at it, so every
		read of the player's weapon state afterwards is looking at something
		that no longer exists. The tell was that pressing G to drop the old
		gun and then buying worked perfectly, while buying directly did not.

		engclient_cmd "drop" runs the engine's own DropPlayerItem, which is
		exactly what G does: it unhooks the active item, updates pev_weapons
		and builds the weaponbox. Doing it this way means the purchase path
		and the path that already worked are the same path.

		The old gun lands on the floor as an ordinary M4A1, which is what it
		is - the key that marks an Angelic goes on the new entity below.

		Widened from "drop weapon_m4a1" to "drop every primary". Dropping only
		this gun's own base weapon is correct right up until the player is holding
		an extra item built on a DIFFERENT base - cso_at15hw is a galil,
		Scar_Born_Beast a ump45, yt_weapon_balrogm4_0 an m249. There is no m4a1 to
		drop in that case, give_item hands over a second primary, and the player
		walks away carrying two guns. give_item does not enforce the one-primary
		rule the buy menu does.
	*/
	DropPrimaries(id)

	g_bAwake[id] = false

	give_item(id, "weapon_m4a1")

	new ent = FindOwnedWeapon(id, "weapon_m4a1")

	if (!ent)
		return

	// this is what makes it an Angelic - everything else keys off it
	set_pev(ent, pev_impulse, ANGELIC_KEY)

	/*
		Deploy again now that the key is on.

		give_item() deploys the weapon inside its own call, which is before
		this line, so the first deploy saw an unstamped entity and
		Fw_Deploy_Post ignored it - stock model, stock draw, stock sound. The
		identity has to be readable at the instant deploy runs, and the
		cheapest way to guarantee that is to run deploy once more with it in
		place. engclient_cmd below cannot do this: the weapon is already
		active by then, and CS ignores a select command for the active weapon.
	*/
	ExecuteHamB(Ham_Item_Deploy, ent)

	cs_set_weapon_ammo(ent, get_pcvar_num(g_pClip))
	cs_set_user_bpammo(id, CSW_M4A1, get_pcvar_num(g_pAmmo))

	/*
		One line per purchase, read back from the weapon rather than echoing
		what was just written - the point is to prove the key landed and the
		identity checks agree, not to repeat the cvars. Safe to leave on: this
		runs once when somebody buys, never per frame or per shot.
	*/
	if (get_pcvar_num(g_pDebug))
		log_amx("[ANGELIC] bought id=%d ent=%d keyed=%d holding=%d clip=%d bpammo=%d",
			id, ent,
			Is_Angelic(ent) ? 1 : 0,
			HoldingAngelic(id) ? 1 : 0,
			get_pdata_int(ent, OFF_WEAPON_CLIP, LINUX_WEAPON),
			cs_get_user_bpammo(id, CSW_M4A1))


	// force a redeploy so the skin and draw animation land immediately
	engclient_cmd(id, "weapon_m4a1")

	client_print(id, print_chat, "[ZP] M4A1-S Angelic Beast - right click to stab. It awakens when the clip runs low.")
}

/*
	Match on m_pPlayer, not pev_owner. Logging showed pev_owner sitting at 0
	on a freshly deployed weapon, so an owner search based on it silently
	found nothing.
*/
/*
	Does this player hold an Angelic?

	Deliberately the same m_pPlayer search FindOwnedWeapon does for everything
	else here, rather than reading m_pActiveItem. m_pActiveItem was tried
	first and produced a weapon that looked right and behaved like a stock
	M4A1 - the entity-side hooks worked, every player-side one silently did
	not. This reuses the lookup already proven on this server instead of
	trusting an offset nothing here had exercised.

	get_user_weapon() is checked first and it is not just an optimisation.
	FM_UpdateClientData calls this once per player per frame, and an entity
	search on that path is the same shape of mistake as a log_amx on the
	firing path, which put this server's frame rate on the floor once already.
	The cheap test throws out every frame the player is not holding an M4A1,
	which is nearly all of them.
*/
bool:HoldingAngelic(id)
{
	if (!is_user_alive(id) || get_user_weapon(id) != CSW_M4A1)
		return false

	return Is_Angelic(FindOwnedWeapon(id, "weapon_m4a1"))
}

/*
	Drop every primary the player is carrying, by the same route G does.

	The mask is CS's own primary set, matching the one zombie_plague40 and
	cso_at15hw already use. get_user_weapons is read once and the list is walked -
	dropping changes pev_weapons, but the local copy was taken before that, so a
	player somehow holding two primaries loses both.
*/
#define PRIMARY_WEAPONS_BIT_SUM (\
	(1<<CSW_SCOUT)|(1<<CSW_XM1014)|(1<<CSW_MAC10)|(1<<CSW_AUG)|(1<<CSW_UMP45)|\
	(1<<CSW_SG550)|(1<<CSW_GALIL)|(1<<CSW_FAMAS)|(1<<CSW_AWP)|(1<<CSW_MP5NAVY)|\
	(1<<CSW_M249)|(1<<CSW_M3)|(1<<CSW_M4A1)|(1<<CSW_TMP)|(1<<CSW_G3SG1)|\
	(1<<CSW_SG552)|(1<<CSW_AK47)|(1<<CSW_P90))

DropPrimaries(id)
{
	static weapons[32], num, wname[32]
	num = 0
	get_user_weapons(id, weapons, num)

	for (new i = 0; i < num; i++)
	{
		if (!((1 << weapons[i]) & PRIMARY_WEAPONS_BIT_SUM))
			continue

		get_weaponname(weapons[i], wname, charsmax(wname))
		engclient_cmd(id, "drop", wname)
	}
}

FindOwnedWeapon(id, const classname[])
{
	new ent = -1

	while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", classname)) > 0)
	{
		if (get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON) == id)
			return ent
	}

	return 0
}

/*
	The model has to be reapplied on every deploy. Setting it once when the
	weapon is handed over is not enough: the engine writes the stock model
	during its own deploy, so a weapon switch would silently drop the skin.
*/
public Fw_Deploy_Post(ent)
{
	if (!pev_valid(ent))
		return

	new id = get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON)

	if (!is_user_alive(id) || !Is_Angelic(ent))
		return

	set_pev(id, pev_viewmodel2, V_MODEL)
	set_pev(id, pev_weaponmodel2, P_MODEL)

	SetAnim(id, ANIM_DRAW)
	emit_sound(id, CHAN_WEAPON, SND_DRAW, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)

	// a fresh draw starts a fresh burst - flush first so a burst cut short by
	// a weapon switch is not silently thrown away
	FlushKickTrace(id)
	g_iShotsFired[id] = 0

	new Float:deploy = get_pcvar_float(g_pDeployTime)

	if (deploy > 0.0)
	{
		set_pdata_float(ent, OFF_WEAPON_TIME_IDLE, deploy, LINUX_WEAPON)
		set_pdata_float(id,  OFF_PLAYER_NEXT_ATTACK, deploy, LINUX_PLAYER)
	}
}

/*
	Which of the four KICKBACK rows applies. Same order of tests the engine
	uses in the weapon's own fire code - moving is checked before ducking, so
	a player shuffling while crouched gets the walking row, not the ducking
	one.
*/
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

// a straight transcription of CBasePlayer::KickBack, fed from the KICKBACK
// table instead of the constants the stock weapon passes in
ApplyKickBack(id, stance)
{
	static Float:punch[3]
	pev(id, pev_punchangle, punch)

	new Float:up, Float:lateral
	new shots = g_iShotsFired[id]

	if (shots <= 1)
	{
		up      = KICKBACK[stance][0]
		lateral = KICKBACK[stance][1]
	}
	else
	{
		up      = KICKBACK[stance][0] + float(shots) * KICKBACK[stance][2]
		lateral = KICKBACK[stance][1] + float(shots) * KICKBACK[stance][3]
	}

	punch[0] -= up

	if (punch[0] < -KICKBACK[stance][4])
		punch[0] = -KICKBACK[stance][4]

	if (g_iKickDir[id])
	{
		punch[1] += lateral

		if (punch[1] > KICKBACK[stance][5])
			punch[1] = KICKBACK[stance][5]
	}
	else
	{
		punch[1] -= lateral

		if (punch[1] < -KICKBACK[stance][5])
			punch[1] = -KICKBACK[stance][5]
	}

	// engine does !RANDOM_LONG(0, direction_change), so a value of 0 flips
	// every single shot rather than never
	if (random_num(0, floatround(KICKBACK[stance][6])) == 0)
	{
		g_iKickDir[id] = 1 - g_iKickDir[id]
		g_iTraceFlips[id]++
	}

	set_pev(id, pev_punchangle, punch)
}

/*
	One line per burst, written after the trigger is released.

	X is the full vertical punch sequence, which is the thing worth reading:
	if the caps are doing their job it should hit its floor on the first round
	and sit there instead of walking off. Y is reported as a range because it
	swaps sign as the direction flips.
*/
FlushKickTrace(id)
{
	new n = g_iTraceN[id]

	if (!n || !get_pcvar_num(g_pDebug))
	{
		g_iTraceN[id] = 0
		g_iTraceFlips[id] = 0
		g_bTraceMixed[id] = false
		return
	}

	static szX[512]
	new len = 0
	szX[0] = 0

	new Float:ymin = 0.0, Float:ymax = 0.0

	for (new i = 0; i < n; i++)
	{
		len += format(szX[len], charsmax(szX) - len, "%s%.2f", i ? "," : "", g_fTraceX[id][i])

		if (g_fTraceY[id][i] < ymin) ymin = g_fTraceY[id][i]
		if (g_fTraceY[id][i] > ymax) ymax = g_fTraceY[id][i]
	}

	log_amx("[ANGELIC/KICK] mode=%d stance=%s%s shots=%d logged=%d flips=%d Y=[%.2f..%.2f] X=[%s]",
		get_pcvar_num(g_pRecoilMode),
		STANCE_NAME[g_iTraceStance[id]],
		g_bTraceMixed[id] ? "+mixed" : "",
		g_iShotsFired[id], n, g_iTraceFlips[id], ymin, ymax, szX)

	g_iTraceN[id] = 0
	g_iTraceFlips[id] = 0
	g_bTraceMixed[id] = false
}

public Fw_Primary_Pre(ent)
{
	if (!pev_valid(ent))
		return HAM_IGNORED

	new id = get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON)

	if (!is_user_alive(id) || !Is_Angelic(ent))
		return HAM_IGNORED

	// accuracy is stored on the weapon and grows as you hold the trigger -
	// pinning it to zero is what makes the gun feel locked on
	set_pdata_float(ent, OFF_WEAPON_ACCURACY, 0.0, LINUX_WEAPON)

	g_bInPrimaryAttack = true
	pev(id, pev_punchangle, g_fPushAngle[id])

	/*
		Set here so Fw_TraceAttack does not have to ask HoldingAngelic.

		The bullet traces run inside the original PrimaryAttack, between this hook
		and the post one, so this flag is live for exactly the window TraceAttack
		fires in. HoldingAngelic is cheap only because get_user_weapon throws out
		the frames where no M4A1 is held - on the firing path that test always
		passes, so what is left is FindOwnedWeapon walking the edict array once per
		bullet. That is the mistake the note above HoldingAngelic was written to
		forbid, and it would have run for every M4A1 holder on the server.
	*/
	g_bFiringAngelic[id] = true

	return HAM_IGNORED
}

public Fw_Primary_Post(ent)
{
	g_bInPrimaryAttack = false

	if (!pev_valid(ent))
		return HAM_IGNORED

	new id = get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON)

	// closed before any of the early returns below, so an empty-clip trigger pull
	// cannot leave the window open into the next player's bullets
	if (id >= 1 && id <= g_iMaxPlayers)
		g_bFiringAngelic[id] = false

	if (!is_user_alive(id) || !Is_Angelic(ent))
		return HAM_IGNORED

	if (cs_get_weapon_ammo(ent) <= 0)
		return HAM_IGNORED

	g_iShotsFired[id]++
	g_fLastShot[id] = get_gametime()

	new stance = GetStance(id)

	if (get_pcvar_num(g_pRecoilMode))
	{
		// throw away the kick the stock M4A1 just applied and put CrossFire's
		// on instead, rather than scaling what the engine happened to produce
		set_pev(id, pev_punchangle, g_fPushAngle[id])
		ApplyKickBack(id, stance)
	}
	else
	{
		// scale down the kick this shot just added
		new Float:push[3]
		pev(id, pev_punchangle, push)
		xs_vec_sub(push, g_fPushAngle[id], push)
		xs_vec_mul_scalar(push, get_pcvar_float(g_pRecoil), push)
		xs_vec_add(push, g_fPushAngle[id], push)
		set_pev(id, pev_punchangle, push)
	}

	// array write only - the line itself goes out when the burst ends
	if (get_pcvar_num(g_pDebug))
	{
		if (g_iTraceN[id] == 0)
			g_iTraceStance[id] = stance
		else if (g_iTraceStance[id] != stance)
			g_bTraceMixed[id] = true

		if (g_iTraceN[id] < KICK_TRACE_MAX)
		{
			static Float:seen[3]
			pev(id, pev_punchangle, seen)

			g_fTraceX[id][g_iTraceN[id]] = seen[0]
			g_fTraceY[id][g_iTraceN[id]] = seen[1]
			g_iTraceN[id]++
		}
	}

	set_pdata_float(ent, OFF_WEAPON_ACCURACY, 0.0, LINUX_WEAPON)

	// rate of fire. Both halves are set for the same reason the stab sets
	// them: the weapon gates the trigger, the player field gates everything,
	// and the client predicts against its own copy of the second one.
	new Float:interval = get_pcvar_float(g_pInterval)

	if (interval > 0.0)
	{
		set_pdata_float(ent, OFF_WEAPON_NEXT_PRIMARY, interval, LINUX_WEAPON)
		set_pdata_float(id,  OFF_PLAYER_NEXT_ATTACK,  interval, LINUX_PLAYER)
	}

	g_iFireIndex[id] = (g_iFireIndex[id] + 1) % sizeof SND_FIRE
	emit_sound(id, CHAN_WEAPON, SND_FIRE[g_iFireIndex[id]], VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
	SetAnim(id, ANIM_FIRE)

	// the blocked fire event took the muzzle flash and the bullet holes with
	// it - the flash comes back from the entity flag, the hole has to be
	// traced and drawn by hand
	set_pev(id, pev_effects, pev(id, pev_effects) | EF_MUZZLEFLASH)
	DrawBulletHole(id)

	return HAM_IGNORED
}

// right click is the stab, not the silencer toggle
public Fw_Secondary_Pre(ent)
{
	if (!pev_valid(ent))
		return HAM_IGNORED

	new id = get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON)

	if (!is_user_alive(id) || !Is_Angelic(ent))
		return HAM_IGNORED

	Stab(id, ent)

	return HAM_SUPERCEDE
}

Stab(id, ent)
{
	new bool:bLog = (get_pcvar_num(g_pDebug) != 0)

	// the flag is raised and lowered around one call further down, but a run
	// time error in between would abort this function and strand it raised -
	// which would quietly stop scaling that player's bullets. Clearing it on
	// the way in means the next swing repairs it.
	g_bStabbing[id] = false

	SetAnim(id, ANIM_STAB)
	emit_sound(id, CHAN_WEAPON, SND_STAB, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)

	if (bLog)
		log_amx("[ANGELIC/STAB] enter id=%d awake=%d wanted_anim=%d weaponanim_now=%d",
			id, g_bAwake[id] ? 1 : 0,
			g_bAwake[id] ? ANIM_STAB + ANIM_AWAKE_OFFSET : ANIM_STAB,
			pev(id, pev_weaponanim))

	new Float:stabDelay = get_pcvar_float(g_pStabDelay)

	set_pdata_float(ent, OFF_WEAPON_NEXT_PRIMARY,   stabDelay, LINUX_WEAPON)
	set_pdata_float(ent, OFF_WEAPON_NEXT_SECONDARY, stabDelay, LINUX_WEAPON)
	set_pdata_float(id,  OFF_PLAYER_NEXT_ATTACK,    stabDelay, LINUX_PLAYER)

	static Float:start[3], Float:view[3], Float:angles[3], Float:fwd[3], Float:reach[3], Float:dest[3]

	pev(id, pev_origin, start)
	pev(id, pev_view_ofs, view)
	xs_vec_add(start, view, start)

	// fwd stays a unit vector - it is handed to TraceAttack as the damage
	// direction, which is what TraceBleed sprays the blood along
	pev(id, pev_v_angle, angles)
	angle_vector(angles, ANGLEVECTOR_FORWARD, fwd)

	xs_vec_mul_scalar(fwd, get_pcvar_float(g_pStabRange), reach)
	xs_vec_add(start, reach, dest)

	/*
		Trace into a TraceResult of our own, not fakemeta's handle 0.

		Handle 0 is fakemeta shorthand for its own global TraceResult and
		get_tr2 takes it happily, so it looks like the obvious thing to hand
		to ExecuteHamB further down. It is not: Ham Sandwich keeps a separate
		handle space and reads that argument as a raw pointer, so 0 arrives
		as NULL and it answers with "Null traceresult provided" plus run time
		error 10.

		That error is much louder than it looks. It aborts the plugin in the
		middle of this function, so Fw_Secondary_Pre never gets to return
		HAM_SUPERCEDE, the stock M4A1 SecondaryAttack runs instead, and the
		silencer toggle animation replaces the stab. Stabbing air never
		reached ExecuteHamB at all, which is why only hits on a player looked
		broken while everything else seemed fine.
	*/
	new tr = create_tr2()

	engfunc(EngFunc_TraceLine, start, dest, DONT_IGNORE_MONSTERS, id, tr)

	// a bare ray is a lot easier to miss with at 3.5m than it was at 1.6m, so
	// widen the second attempt into a hull sweep - the same fallback, and the
	// same head_hull, that CKnife::Stab uses
	new Float:fraction
	get_tr2(tr, TR_flFraction, fraction)

	new bool:bHull = (fraction >= 1.0)

	if (bHull)
		engfunc(EngFunc_TraceHull, start, dest, DONT_IGNORE_MONSTERS, HULL_HEAD, id, tr)

	new hit = get_tr2(tr, TR_pHit)

	if (bLog)
	{
		new Float:f2
		get_tr2(tr, TR_flFraction, f2)
		log_amx("[ANGELIC/STAB] trace line_frac=%.3f hull_used=%d final_frac=%.3f hit=%d valid=%d alive=%d weaponanim=%d",
			fraction, bHull ? 1 : 0, f2, hit,
			pev_valid(hit) ? 1 : 0,
			(hit > 0 && is_user_alive(hit)) ? 1 : 0,
			pev(id, pev_weaponanim))
	}

	if (!pev_valid(hit) || !is_user_alive(hit) || hit == id)
	{
		if (bLog)
			log_amx("[ANGELIC/STAB] miss - no damage dealt, weaponanim=%d", pev(id, pev_weaponanim))

		free_tr2(tr)
		return
	}

	/*
		TraceAttack first, TakeDamage second - the order CKnife::Stab uses,
		and the reason it matters.

		Everything that makes a hit read as a hit lives in
		CBasePlayer::TraceAttack, not in TakeDamage: SpawnBlood puffs the
		blood at the impact point, TraceBleed splatters the surface behind
		it, and m_LastHitGroup is what separates head from body. Calling
		TakeDamage on its own took health off and produced nothing else - no
		blood, no reaction - and left zp_round_rules (headshot-triggered,
		before its melee rewrite) reading the hitgroup of whatever bullet
		happened to land last, so whether a lethal stab counted as a
		headshot was down to the previous shot.

		TraceAttack also queues its damage into the engine's multidamage
		accumulator, which nothing here flushes. That is harmless: every
		FireBullets call opens with ClearMultiDamage, so the queued copy is
		thrown away before anything can apply it a second time. The damage
		that actually lands is the TakeDamage call below, which keeps the
		stab flat at zp_angelic_stab_dmg instead of picking up TraceAttack's
		x4 headshot multiplier.
	*/
	new Float:damage = get_pcvar_float(g_pStabDmg)

	new Float:hpBefore
	pev(hit, pev_health, hpBefore)

	/*
		DMG_NEVERGIB|DMG_CLUB, not DMG_BULLET.

		DMG_CLUB is what marks this as a melee hit rather than a shot, and it
		is already the convention on this server - zp_weapon_ak47_beast tags
		its own stab exactly this way. zp_round_rules reads the bit to
		decide whether a kill was a melee kill.

		Nothing is lost by dropping DMG_BULLET here. ZP's TakeDamage hook does
		not look at the damage type at all, so the zombie armor multiplier
		still applies; its TraceAttack hook does gate on DMG_BULLET, but only
		for knockback, which is off server-wide. Blood survives too, since
		TraceBleed's mask includes DMG_CLUB.
	*/
	ExecuteHamB(Ham_TraceAttack, hit, id, damage, fwd, tr, DMG_NEVERGIB|DMG_CLUB)

	new animAfterTrace = pev(id, pev_weaponanim)

	g_bStabbing[id] = true
	ExecuteHamB(Ham_TakeDamage,  hit, id, id, damage, DMG_NEVERGIB|DMG_CLUB)
	g_bStabbing[id] = false

	if (bLog)
	{
		new Float:hpAfter
		pev(hit, pev_health, hpAfter)

		log_amx("[ANGELIC/STAB] hit=%d hp %.0f->%.0f | weaponanim after TraceAttack=%d after TakeDamage=%d | curweapon=%d alive=%d",
			hit, hpBefore, hpAfter,
			animAfterTrace, pev(id, pev_weaponanim),
			get_user_weapon(id), is_user_alive(hit) ? 1 : 0)
	}

	// every create_tr2 needs its pair, on this path and on the miss above -
	// this runs on every right click, so a leak here would be a leak per swing
	free_tr2(tr)
}

/*
	Custom clip sizes cannot be written straight into the weapon: CS refills
	to the M4A1's own 30 round cap and the client predicts against that same
	cap, which is why 52 kept collapsing to 30 the moment a shot was fired.

	The working shape - the same one the Balrog plugin on this server uses -
	is to let the reload start, immediately put the clip back to what it was,
	flag the weapon as reloading, and only hand over the rounds once the
	animation has actually finished. Item_PostFrame does that last part.
*/
public Fw_Reload_Pre(ent)
{
	if (!pev_valid(ent))
		return HAM_IGNORED

	new id = get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON)

	if (!is_user_alive(id) || !Is_Angelic(ent))
		return HAM_IGNORED

	g_iTmpClip[id] = -1

	new clip = get_pdata_int(ent, OFF_WEAPON_CLIP, LINUX_WEAPON)
	new bp   = cs_get_user_bpammo(id, CSW_M4A1)

	if (bp <= 0)
		return HAM_SUPERCEDE

	if (clip >= get_pcvar_num(g_pClip))
		return HAM_SUPERCEDE

	g_iTmpClip[id] = clip

	return HAM_IGNORED
}

public Fw_Reload_Post(ent)
{
	if (!pev_valid(ent))
		return HAM_IGNORED

	new id = get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON)

	if (!is_user_alive(id) || !Is_Angelic(ent) || g_iTmpClip[id] == -1)
		return HAM_IGNORED

	// undo the 30 round refill CS just did; the real rounds arrive when the
	// animation ends
	set_pdata_int(ent, OFF_WEAPON_CLIP, g_iTmpClip[id], LINUX_WEAPON)
	set_pdata_int(ent, OFF_WEAPON_IN_RELOAD, 1, LINUX_WEAPON)

	new Float:reload = get_pcvar_float(g_pReloadTime)

	set_pdata_float(ent, OFF_WEAPON_TIME_IDLE, reload, LINUX_WEAPON)
	set_pdata_float(id,  OFF_PLAYER_NEXT_ATTACK, reload, LINUX_PLAYER)

	// alternate the two reloads the way the showcase video does
	g_bAltReload[id] = !g_bAltReload[id]
	new anim = g_bAltReload[id] ? ANIM_RELOAD + ANIM_AWAKE_OFFSET : ANIM_RELOAD
	SetAnimExact(id, anim)

	// A reload is three beats, not one: mag out, mag in, bolt - and none of them
	// is at t=0, since the hands do not reach the magazine until frame 20. So
	// all three are scheduled, the first one included.
	//
	// The bolt fraction has to follow the animation that was just chosen above,
	// because the two do not blow the bolt back on the same frame.
	new Float:fracOut  = get_pcvar_float(g_pFracClipOut)
	new Float:fracBolt = get_pcvar_float(g_bAltReload[id] ? g_pFracBoltAlt : g_pFracBolt)

	// ScheduleBeat clears each task itself, so the three remove_task calls that
	// used to sit here are gone rather than duplicated.
	//
	// All three go through the same guard. It was written for the mag-out beat
	// only, which left the other two handing a possibly-zero delay straight to
	// set_task - the exact trap the guard exists to avoid.
	ScheduleBeat(id, reload * fracOut,                            "Task_ClipOut", TASK_CLIPOUT + id, SND_CLIPOUT)
	ScheduleBeat(id, reload * get_pcvar_float(g_pFracClipIn),     "Task_ClipIn",  TASK_CLIPIN  + id, SND_CLIPIN)
	ScheduleBeat(id, reload * fracBolt,                           "Task_Bolt",    TASK_BOLT    + id, SND_BLOWBACK)

	return HAM_IGNORED
}

// runs every frame the weapon is active - this is where the rounds are
// actually handed over, once the reload animation has run its course
public Fw_ItemPostFrame(ent)
{
	if (!pev_valid(ent))
		return HAM_IGNORED

	new id = get_pdata_cbase(ent, OFF_WEAPON_PLAYER, LINUX_WEAPON)

	if (!is_user_alive(id) || !Is_Angelic(ent))
		return HAM_IGNORED

	/*
		End the burst once the trigger has been off for a moment. CS decays
		m_iShotsFired gradually instead of clearing it, but the difference
		never reaches the screen here: up_base already equals up_max, so the
		vertical kick is pinned from the first round whatever the counter
		says, and the lateral one reaches its own cap by the second.
	*/
	if (g_iShotsFired[id] && get_gametime() - g_fLastShot[id] > 0.25)
	{
		FlushKickTrace(id)
		g_iShotsFired[id] = 0
	}

	new Float:next = get_pdata_float(id, OFF_PLAYER_NEXT_ATTACK, LINUX_PLAYER)
	new inReload   = get_pdata_int(ent, OFF_WEAPON_IN_RELOAD, LINUX_WEAPON)

	if (!inReload || next > 0.0)
		return HAM_IGNORED

	new clip = get_pdata_int(ent, OFF_WEAPON_CLIP, LINUX_WEAPON)
	new bp   = cs_get_user_bpammo(id, CSW_M4A1)
	new need = min(get_pcvar_num(g_pClip) - clip, bp)

	/*
		A negative need mints ammo.

		Lower zp_angelic_clip while a fuller magazine is already loaded and the
		subtraction goes negative - then clip + need takes rounds OUT of the
		magazine while bp - need puts them INTO the reserve, and the reserve grows
		every time the player reloads. Both cvars are live-tunable, so this is a
		reachable state and not a theoretical one.

		Clamped rather than returned early: the IN_RELOAD flag below still has to be
		cleared or the weapon stays stuck mid-reload for good. At need 0 the two
		writes are no-ops and only that flag changes.
	*/
	if (need < 0)
		need = 0

	set_pdata_int(ent, OFF_WEAPON_CLIP, clip + need, LINUX_WEAPON)
	cs_set_user_bpammo(id, CSW_M4A1, bp - need)
	set_pdata_int(ent, OFF_WEAPON_IN_RELOAD, 0, LINUX_WEAPON)

	return HAM_IGNORED
}

/*
	This is what makes every other custom value actually reach the screen.

	CS predicts weapons on the client, so the client keeps its own copy of the
	clip, the model, the animations and the sounds, and trusts that copy over
	anything the server says. Logging showed the server side was already
	correct - clip read back as 52, the fire event was blocked, the viewmodel
	was set - while the client still displayed 30 rounds, played the stock
	M4A1 report and had no sequence 11 to animate, because it was still
	running a plain M4A1 locally.

	Nudging m_flNextAttack on every client data update stops the prediction
	and forces the client to take the server's state instead.
*/
public Fw_UpdateClientData_Post(id, sendweapons, cd_handle)
{
	if (!HoldingAngelic(id))
		return FMRES_IGNORED

	if (get_user_weapon(id) != CSW_M4A1)
		return FMRES_IGNORED

	set_cd(cd_handle, CD_flNextAttack, halflife_time() + 0.001)

	return FMRES_HANDLED
}

public Fw_PrecacheEvent_Post(type, const name[])
{
	if (equal("events/m4a1.sc", name))
	{
		g_iOrigFireEvent = get_orig_retval()

		return FMRES_HANDLED
	}

	return FMRES_IGNORED
}

public Fw_TakeDamage_Pre(victim, inflictor, attacker, Float:damage, damagebits)
{
	if (attacker < 1 || attacker > g_iMaxPlayers || !HoldingAngelic(attacker))
		return HAM_IGNORED

	if (get_user_weapon(attacker) != CSW_M4A1)
		return HAM_IGNORED

	// the stab already carries its own flat number, only bullets get scaled
	if (g_bStabbing[attacker])
		return HAM_IGNORED

	SetHamParamFloat(4, damage * get_pcvar_float(g_pDmg))

	return HAM_IGNORED
}

// keep the muzzle flash and shell event local so the custom sound is not
// doubled up by the stock M4A1 one
public Fw_PlaybackEvent(flags, invoker, eventid, Float:delay, Float:origin[3], Float:angles[3],
                        Float:fparam1, Float:fparam2, iParam1, iParam2, bParam1, bParam2)
{
	// only the M4A1's own fire event, not every event that happens to fire
	// during the attack
	if (eventid != g_iOrigFireEvent || !g_bInPrimaryAttack)
		return FMRES_IGNORED

	if (!(1 <= invoker <= g_iMaxPlayers) || !HoldingAngelic(invoker))
		return FMRES_IGNORED

	/*
		Block the event outright instead of replaying it host-only.

		A host-only replay stops everyone ELSE hearing the stock M4A1, but the
		shooter's own client still runs events/m4a1.sc and plays it, which is
		why the custom sound kept getting buried. Dropping the event removes
		the stock report, the shell and the muzzle flash - the flash is put
		back by hand in Fw_Primary_Post.
	*/
	return FMRES_SUPERCEDE
}

// dropped weapon keeps the custom world model, and ownership ends there
public Fw_SetModel(ent, const model[])
{
	if (!equal(model, W_STOCK))
		return FMRES_IGNORED

	/*
		ent here is the weaponbox the engine just built, not the weapon. The
		box carries no identity of its own - the key is on the weapon_m4a1
		entity it wraps, which is the one that will be handed to whoever picks
		the box up. Asking the box directly is how the dropped gun ended up
		wearing the stock world model.
	*/
	new weapon = find_ent_by_owner(-1, "weapon_m4a1", ent)

	if (!Is_Angelic(weapon))
		return FMRES_IGNORED

	engfunc(EngFunc_SetModel, ent, W_MODEL)

	return FMRES_SUPERCEDE
}

/*
	CurWeapon fires on weapon changes and on every ammo change, so it is the
	natural place to watch the clip and flip the awakened state.
*/
public Event_CurWeapon(id)
{
	if (!HoldingAngelic(id))
		return

	if (get_user_weapon(id) != CSW_M4A1)
		return

	new clip = read_data(3)
	new max  = get_pcvar_num(g_pClip)

	if (max < 1)
		max = 1

	new bool:awake = (float(clip) / float(max)) < get_pcvar_float(g_pThreshold)

	if (awake != g_bAwake[id])
	{
		g_bAwake[id] = awake
		SetAnim(id, ANIM_IDLE)

		// announce the transition only on the way in, not when the clip is
		// topped back up and the gun settles down again
		if (awake && get_pcvar_num(g_pAwakenMsg))
		{
			set_dhudmessage(120, 200, 255, -1.0, 0.40, 0, 0.0, 0.5, 0.0, 0.0)
			show_dhudmessage(id, "The angelic beast has awakened")
		}
	}

	new Float:base = get_cvar_float("zp_human_speed")

	if (base < 1.0)
		base = 240.0

	set_pev(id, pev_maxspeed, awake ? base * get_pcvar_float(g_pSpeed) : base)
}

/*
	One reload beat: cancel any pending copy, then either play it now or schedule it.

	A fraction of zero has to be emitted immediately rather than scheduled, because
	set_task will not honour a delay of 0.0 - the sound arrives late or not at all.
	Every beat needs that guard, not just the first one.
*/
ScheduleBeat(id, Float:delay, const func[], taskid, const sound[])
{
	remove_task(taskid)

	if (delay <= 0.0)
		emit_sound(id, CHAN_ITEM, sound, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
	else
		set_task(delay, func, taskid)
}

public Task_ClipOut(taskid)
{
	new id = taskid - TASK_CLIPOUT

	if (HoldingAngelic(id))
		emit_sound(id, CHAN_ITEM, SND_CLIPOUT, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
}

public Task_ClipIn(taskid)
{
	new id = taskid - TASK_CLIPIN

	if (HoldingAngelic(id))
		emit_sound(id, CHAN_ITEM, SND_CLIPIN, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
}

public Task_Bolt(taskid)
{
	new id = taskid - TASK_BOLT

	if (HoldingAngelic(id))
		emit_sound(id, CHAN_ITEM, SND_BLOWBACK, VOL_NORM, ATTN_NORM, 0, PITCH_NORM)
}

/*
	Scale the bullet cone, in the one place the engine actually uses it.

	Params, from reapi_gamedll_const.inc, 1-based and counting pEntity:

	    1 pEntity  2 vecSrc  3 vecDirShooting  4 vecSpread  5 flDistance
	    6 iPenetration  7 iBulletType  8 iDamage  9 flRangeModifier
	    10 pevAttacker  11 bPistol  12 shared_rand

	so arg 4 is the cone, and it is a scalar here rather than the Float[3] that
	FireBuckshots takes. This runs for every entity on the server that fires a
	bullet, so the guard is not optional - g_bFiringAngelic is the flag the attack
	hook already sets from the weapon entity it was handed, which keeps this off the
	per-bullet lookup path entirely.
*/
public Fw_FireBullets3_Pre(pEntity, Float:vecSrc[3], Float:vecDirShooting[3], Float:vecSpread, Float:flDistance,
                           iPenetration, iBulletType, iDamage, Float:flRangeModifier, pevAttacker, bool:bPistol, shared_rand)
{
	if (pEntity < 1 || pEntity > g_iMaxPlayers || !g_bFiringAngelic[pEntity])
		return HC_CONTINUE

	new Float:scale = get_pcvar_float(g_pSpreadScale)

	if (scale < 0.0)
		scale = 0.0

	// nothing to write at 1.0
	if (scale == 1.0)
		return HC_CONTINUE

	SetHookChainArg(4, ATYPE_FLOAT, vecSpread * scale)

	return HC_CONTINUE
}

// A hole at each real impact point. This is where the rounds actually went.
public Fw_TraceAttack(iEnt, iAttacker, Float:flDamage, Float:fDir[3], ptr, iDamageType)
{
	if (!g_bDecalsOk || !get_pcvar_num(g_pDecals) || !get_pcvar_num(g_pDecalReal))
		return

	/*
		Bullets only. The stab calls ExecuteHamB(Ham_TraceAttack, ...) itself with
		DMG_NEVERGIB|DMG_CLUB, so without this a melee hit would stamp a bullet
		hole. The firing flag below already happens to exclude it - the stab runs
		off SecondaryAttack - but that is a side effect, not a guard, and it would
		stop being true the moment either path moved.
	*/
	if (!(iDamageType & DMG_BULLET))
		return

	// the O(1) flag set in Fw_Primary_Pre, not an entity search per bullet
	if (iAttacker < 1 || iAttacker > g_iMaxPlayers || !g_bFiringAngelic[iAttacker])
		return

	static Float:end[3]
	get_tr2(ptr, TR_vecEndPos, end)

	message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
	write_byte(TE_GUNSHOTDECAL)
	engfunc(EngFunc_WriteCoord, end[0])
	engfunc(EngFunc_WriteCoord, end[1])
	engfunc(EngFunc_WriteCoord, end[2])
	write_short(iEnt > 0 && pev_valid(iEnt) ? iEnt : 0)
	write_byte(g_iDecals[random_num(0, sizeof g_iDecals - 1)])
	message_end()
}

DrawBulletHole(id)
{
	// superseded by Fw_TraceAttack unless the old behaviour is asked for
	if (get_pcvar_num(g_pDecalReal))
		return

	if (!g_bDecalsOk || !get_pcvar_num(g_pDecals))
		return

	static Float:start[3], Float:view[3], Float:angles[3], Float:fwd[3], Float:dest[3], Float:end[3]

	pev(id, pev_origin, start)
	pev(id, pev_view_ofs, view)
	xs_vec_add(start, view, start)

	pev(id, pev_v_angle, angles)
	angle_vector(angles, ANGLEVECTOR_FORWARD, fwd)
	xs_vec_mul_scalar(fwd, 8192.0, fwd)
	xs_vec_add(start, fwd, dest)

	engfunc(EngFunc_TraceLine, start, dest, DONT_IGNORE_MONSTERS, id, 0)

	new hit = get_tr2(0, TR_pHit)

	// only mark solid geometry, not players
	if (hit > 0 && hit <= g_iMaxPlayers)
		return

	// a negative or stale hit index would be written straight into the temp
	// entity message; fall back to worldspawn rather than send garbage
	if (hit < 0 || !pev_valid(hit))
		hit = 0

	get_tr2(0, TR_vecEndPos, end)

	message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
	write_byte(TE_GUNSHOTDECAL)
	engfunc(EngFunc_WriteCoord, end[0])
	engfunc(EngFunc_WriteCoord, end[1])
	engfunc(EngFunc_WriteCoord, end[2])
	write_short(hit)
	write_byte(g_iDecals[random_num(0, sizeof g_iDecals - 1)])
	message_end()
}

// picks the calm or awakened variant of a sequence
SetAnim(id, anim)
{
	SetAnimExact(id, g_bAwake[id] ? anim + ANIM_AWAKE_OFFSET : anim)
}

// sends a sequence index as-is, for cases like the reload where the choice is
// not driven by the awakened state
SetAnimExact(id, anim)
{
	/*
		Do not put logging in here.

		Every animation write goes through this function, which makes it the
		obvious place to trace - and it is, briefly. It is also on the firing
		path: Fw_Primary_Post sets ANIM_FIRE on every single shot, so at the
		M4A1's ~11 rounds a second a log_amx call here is eleven synchronous
		disk appends a second and the frame rate shows it. Trace inside Stab
		instead, which only runs on a right click.
	*/
	set_pev(id, pev_weaponanim, anim)

	message_begin(MSG_ONE_UNRELIABLE, SVC_WEAPONANIM, {0, 0, 0}, id)
	write_byte(anim)
	write_byte(pev(id, pev_body))
	message_end()
}
