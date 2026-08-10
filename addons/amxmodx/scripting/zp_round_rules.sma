/*
	[ZP] Round Rules - Melee Permadeath + Kill Feedback + Endless Respawn
	-----------------------------------------------------------------
	This is zp_round_rules.sma, registered in-game as "[ZP] Round Rules".
	The trigger for permadeath is MELEE, not the head.

	1. Permadeath - a zombie killed by MELEE stays down for the rest of the
	   round. Anything else comes straight back, headshots included.

	   Melee means the real knife, and it means the right-click stab on the
	   custom weapons - AK47 Beast, M4A1-S Angelic Beast. Those tag their
	   damage with DMG_CLUB; the knife is recognised by weapon id instead,
	   because CS does not tag its own stab that way.

	2. Kill feedback - a sound played to the KILLER only:
	       normal kill -> cscf/kill_normal.wav
	       permakill   -> cscf/kill_headshot.wav
	   The second file keeps its name, but it now follows the melee permakill
	   rather than the head, so the special cue and the special kill stay
	   together.

	3. Endless respawn - non-melee deaths respawn after zp_rules_respawn_delay
	   seconds, with no window where the zombie team is empty.

	Why respawn is handled here instead of by zp_deathmatch:
	    ZP respawns on a timer, so for zp_spawn_delay seconds the zombie team
	    is empty and CS hands the round to the humans. Shooting the last
	    zombie in the leg used to win the round outright.

	    Respawning in Ham_Killed post is still too late - CS runs its win
	    check inside CBasePlayer::Killed, before any post hook. So the LAST
	    zombie is caught earlier, in Ham_TakeDamage: a lethal non-melee hit
	    is cancelled and turned into a heal + teleport, so the zombie never
	    dies and there is nothing for CS to react to.

	    This is why the delay in point 3 is safe. It only ever runs while two
	    or more zombies were alive at the moment of the killing blow, so at
	    least one is still standing while the dead one waits; and if that one
	    is then killed it becomes the last zombie and gets rescued instead of
	    dying. The team cannot empty out during the wait.

	    Round win by headshot is gone as a side effect: a lethal headshot on
	    the last zombie is now a non-melee hit, so it gets cancelled like any
	    other. The last zombie has to be finished with melee.

	    While two or more zombies are alive a normal death is harmless, so it
	    is allowed to happen for real - the kill counts, the frag counts, and
	    Ham_Killed post puts the player back immediately.

	Known limitation - do not spend time on this again:
	    The headshot cue on the kill that ENDS the round is never heard.
	    Logging proved the plugin reaches the play call every single time.
	    Tried and ruled out: CHAN_STATIC -> CHAN_AUTO, emit_sound -> spk, and
	    delaying the sound. ZP plays its own 6 second WIN HUMANS sound at that
	    exact moment and it wins regardless of channel or mechanism. The only
	    real fix would be to point WIN HUMANS at our own file in
	    zombieplague.ini and own that slot instead of competing for it.
	    Left as is on purpose.

	cvars:
		zp_rules_permadeath           1 = melee kills stick for the round
		zp_rules_announce  1 = chat line on a permanent kill
		zp_rules_kill_sound              1 = play the kill feedback sound
		zp_rules_respawn         1 = take respawn over from ZP
		zp_rules_respawn_delay   seconds before a normal death comes back
		zp_rules_escape_credit      1 = frag + kill feed when the last zombie escapes
*/

#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <zombieplague>

#define MAX_SPAWNS 64
#define TASK_RESPAWN 8100

new const SND_KILL_NORMAL[]   = "cscf/kill_normal.wav"
new const SND_KILL_HEADSHOT[] = "cscf/kill_headshot.wav"

/*
	The same pair ZP plays on infection, reused here so a zombie coming back
	sounds like a zombie arriving.

	CSCF keeps these two as a two element array per gender and picks one at
	run time - the index could not be recovered from the compiled plugin, but
	the two clips are the same length and the class specific variants have no
	second file, which points at a plain random choice. Random is what is done
	here, and it is what zombieplague.ini now does for infection too.
*/
new const SND_RESPAWN[2][] = { "nano/NanoAppearSnd.wav", "nano/NanoAppearSnd2.wav" }

new bool:g_bPermaDead[33]
new bool:g_bWasZombie[33]

// how the most recent hit on this player landed. Written on every TakeDamage
// so that Event_DeathMsg, which only sees a headshot flag, can still tell a
// melee kill from a shot.
new bool:g_bMeleeHit[33]

new g_pEnabled, g_pAnnounce, g_pKillSound, g_pRespawn, g_pCredit, g_pRespawnDelay
new g_pDebug, g_pRespawnSound
new bool:g_bFakeDeath

new Float:g_fSpawn[MAX_SPAWNS][3]
new g_iSpawns

public plugin_precache()
{
	precache_sound(SND_KILL_NORMAL)
	precache_sound(SND_KILL_HEADSHOT)

	// ZP already precaches these through zombieplague.ini, but doing it here
	// too keeps the plugin standalone if that entry is ever changed
	for (new i = 0; i < sizeof SND_RESPAWN; i++)
		precache_sound(SND_RESPAWN[i])
}

public plugin_init()
{
	register_plugin("[ZP] Round Rules", "2.0", "setup")

	g_pEnabled   = register_cvar("zp_rules_permadeath", "1")
	g_pAnnounce  = register_cvar("zp_rules_announce", "1")
	g_pKillSound = register_cvar("zp_rules_kill_sound", "1")
	g_pRespawn   = register_cvar("zp_rules_respawn", "1")
	g_pCredit    = register_cvar("zp_rules_escape_credit", "1")

	/*
		A normal death used to come straight back on the same frame. It no
		longer has to: the last zombie is rescued in TakeDamage rather than
		respawned, so a wait here can never leave the zombie team empty.
	*/
	g_pRespawnDelay = register_cvar("zp_rules_respawn_delay", "1.0")

	/*
		Traces the whole life of a kill: was the blow melee, did permadeath
		stick, was a respawn scheduled, did it fire. Only the death path is
		logged - a few lines per round, nothing near the firing path.
	*/
	g_pDebug = register_cvar("zp_rules_debug", "1")

	// heard by everyone, same as ZP's own infection cue. Turn it off if a
	// busy round starts sounding like a siren.
	g_pRespawnSound = register_cvar("zp_rules_respawn_sound", "1")

	register_event("HLTV", "Event_NewRound", "a", "1=0", "2=0")
	register_event("DeathMsg", "Event_DeathMsg", "a")

	RegisterHam(Ham_TakeDamage,  "player", "Fw_TakeDamage_Pre",  0)
	RegisterHam(Ham_Killed,      "player", "Fw_Killed_Pre",      0)
	RegisterHam(Ham_Killed,      "player", "Fw_Killed_Post",     1)
	RegisterHam(Ham_CS_RoundRespawn, "player", "Fw_RoundRespawn_Pre", 0)
}

public client_putinserver(id)
{
	g_bPermaDead[id] = false
	g_bWasZombie[id] = false
	g_bMeleeHit[id]  = false
}

public client_disconnected(id)
{
	g_bPermaDead[id] = false
	g_bWasZombie[id] = false
	g_bMeleeHit[id]  = false

	remove_task(id + TASK_RESPAWN)
}

public Event_NewRound()
{
	for (new i = 1; i <= 32; i++)
	{
		g_bPermaDead[i] = false
		g_bMeleeHit[i]  = false

		// a respawn still in flight from the previous round would fire into
		// the new one
		remove_task(i + TASK_RESPAWN)
	}

	CollectSpawns()
}

public zp_round_started(gamemode, id)
{
	for (new i = 1; i <= 32; i++)
		g_bPermaDead[i] = false
}

/*
	Was this hit melee?

	DMG_CLUB is the marker. It is not something this plugin invented - the
	custom weapon stabs on this server already tag themselves with it, AK47
	Beast first and the Angelic Beast now matching, and nothing else on the
	server raises that bit.

	The real knife is caught by weapon id rather than by damage bits, because
	CS tags its own stab DMG_NEVERGIB without DMG_CLUB.
*/
bool:IsMeleeHit(attacker, damagebits)
{
	if (damagebits & DMG_CLUB)
		return true

	if (1 <= attacker <= 32 && get_user_weapon(attacker) == CSW_KNIFE)
		return true

	return false
}

public Fw_TakeDamage_Pre(victim, inflictor, attacker, Float:damage, damagebits)
{
	// cached ahead of every early exit below, because Event_DeathMsg needs
	// it and only ever sees a headshot flag of its own
	if (1 <= victim <= 32)
		g_bMeleeHit[victim] = IsMeleeHit(attacker, damagebits)

	if (!get_pcvar_num(g_pRespawn))
		return HAM_IGNORED

	if (victim < 1 || victim > 32 || !is_user_alive(victim))
		return HAM_IGNORED

	if (!zp_get_user_zombie(victim))
		return HAM_IGNORED

	new Float:hp
	pev(victim, pev_health, hp)

	if (damage < hp)
		return HAM_IGNORED

	new bool:bHumanAttacker = (attacker >= 1 && attacker <= 32 && is_user_connected(attacker)
	                           && attacker != victim && !zp_get_user_zombie(attacker))

	// only lethal hits get here, so this is a handful of lines per round
	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] lethal victim=%d attacker=%d dmg=%.0f hp=%.0f melee=%d bits=%d humanAtk=%d zombiesAlive=%d",
			victim, attacker, damage, hp, g_bMeleeHit[victim] ? 1 : 0, damagebits,
			bHumanAttacker ? 1 : 0, zp_get_zombie_count())

	// a melee kill from a human is meant to be lethal - that is the permakill
	if (g_bMeleeHit[victim] && bHumanAttacker && get_pcvar_num(g_pEnabled))
	{
		if (get_pcvar_num(g_pDebug))
			log_amx("[RULES]   -> allowed to die as a PERMAKILL")

		return HAM_IGNORED
	}

	// other zombies still standing, so a real death cannot end the round
	if (zp_get_zombie_count() > 1)
		return HAM_IGNORED

	// last zombie, not a melee hit: cancel the death entirely
	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES]   -> LAST ZOMBIE rescued, damage cancelled, healed in place")

	RespawnZombie(victim)

	if (bHumanAttacker)
	{
		// no real death happened, so the frag and the kill feed line have to
		// be produced by hand - otherwise a clean shot feels like it missed
		if (get_pcvar_num(g_pCredit))
			CreditEscapeKill(attacker, victim)

		if (get_pcvar_num(g_pKillSound))
			PlayKillSound(attacker, SND_KILL_NORMAL)
	}

	SetHamParamFloat(4, 0.0)
	return HAM_SUPERCEDE
}

public Fw_Killed_Pre(victim, attacker, shouldgib)
{
	if (1 <= victim <= 32)
		g_bWasZombie[victim] = (zp_get_user_zombie(victim) != 0)

	return HAM_IGNORED
}

public Fw_Killed_Post(victim, attacker, shouldgib)
{
	if (!get_pcvar_num(g_pRespawn))
		return HAM_IGNORED

	if (victim < 1 || victim > 32 || !is_user_connected(victim))
		return HAM_IGNORED

	// DeathMsg is emitted from inside CBasePlayer::Killed, so it has already
	// run by the time this post hook does and the flag is settled
	if (g_bPermaDead[victim])
	{
		if (get_pcvar_num(g_pDebug))
			log_amx("[RULES] killed_post victim=%d permadead=1 -> NO respawn, stays down", victim)

		return HAM_IGNORED
	}

	new Float:delay = get_pcvar_float(g_pRespawnDelay)

	remove_task(victim + TASK_RESPAWN)

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] killed_post victim=%d permadead=0 -> respawn in %.2fs", victim, delay)

	if (delay <= 0.0)
		zp_respawn_user(victim, ZP_TEAM_ZOMBIE)
	else
		set_task(delay, "Task_Respawn", victim + TASK_RESPAWN)

	return HAM_IGNORED
}

public Task_Respawn(taskid)
{
	new id = taskid - TASK_RESPAWN

	// a second can be a long time - the player may have left, the round may
	// have turned over, or something else may have put them back already
	if (!is_user_connected(id) || is_user_alive(id) || g_bPermaDead[id])
	{
		if (get_pcvar_num(g_pDebug))
			log_amx("[RULES] respawn_task victim=%d SKIPPED connected=%d alive=%d permadead=%d",
				id, is_user_connected(id) ? 1 : 0, is_user_alive(id) ? 1 : 0, g_bPermaDead[id] ? 1 : 0)

		return
	}

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] respawn_task victim=%d -> respawning as zombie", id)

	zp_respawn_user(id, ZP_TEAM_ZOMBIE)
	ClearScoreboardDeath(id)
	PlayRespawnSound()
}

/*
	spk rather than emit_sound, and to everyone rather than to one player.

	This follows ZP's own PlaySound, which is client_cmd(0, "spk ...") - the
	same reason the kill cue below uses it. A sound tied to a player entity
	and a channel gets torn down when the round flips, and something else on
	that channel replaces it.
*/
PlayRespawnSound()
{
	if (!get_pcvar_num(g_pRespawnSound))
		return

	client_cmd(0, "spk ^"%s^"", SND_RESPAWN[random_num(0, sizeof SND_RESPAWN - 1)])
}

/*
	Take the skull off the scoreboard.

	The dead marker on the TAB list is not read from the player, it is pushed
	out once as a ScoreAttrib message: CS sends it with the dead bit set when
	someone dies and clears it again when the engine spawns them. Respawning
	from a plugin never produces that second message, so the player walks
	around perfectly alive with the scoreboard still showing them dead.

	Nothing was wrong before the respawn gained a delay only because the two
	events used to land in the same frame.
*/
ClearScoreboardDeath(id)
{
	static msgScoreAttrib

	if (!msgScoreAttrib)
		msgScoreAttrib = get_user_msgid("ScoreAttrib")

	if (!msgScoreAttrib)
		return

	message_begin(MSG_BROADCAST, msgScoreAttrib)
	write_byte(id)
	write_byte(0)   // bit 0 = dead, bit 1 = bomb, bit 2 = VIP
	message_end()
}

public Event_DeathMsg()
{
	// skip the kill-feed line we fake ourselves for an escaped last zombie,
	// otherwise the feedback sound would fire twice
	if (g_bFakeDeath)
		return

	new killer = read_data(1)
	new victim = read_data(2)

	if (victim < 1 || victim > 32 || killer < 1 || killer > 32 || killer == victim)
		return

	if (!is_user_connected(killer))
		return

	// only a human killing a zombie counts
	if (!g_bWasZombie[victim] || zp_get_user_zombie(killer))
		return

	// read_data(3) is the headshot flag and is deliberately ignored - the
	// permakill follows the melee flag cached during TakeDamage instead
	new bool:bPermaKill = g_bMeleeHit[victim]

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] deathmsg victim=%d killer=%d meleeFlag=%d csHeadshotFlag=%d -> permakill=%d",
			victim, killer, bPermaKill ? 1 : 0, read_data(3), (bPermaKill && get_pcvar_num(g_pEnabled)) ? 1 : 0)

	if (bPermaKill && get_pcvar_num(g_pEnabled))
	{
		g_bPermaDead[victim] = true

		if (get_pcvar_num(g_pAnnounce))
		{
			new szKiller[32], szVictim[32]
			get_user_name(killer, szKiller, charsmax(szKiller))
			get_user_name(victim, szVictim, charsmax(szVictim))
			client_print(0, print_chat, "[ZP] %s finished %s with melee - no respawn this round.", szKiller, szVictim)
		}
	}

	if (get_pcvar_num(g_pKillSound))
		PlayKillSound(killer, bPermaKill ? SND_KILL_HEADSHOT : SND_KILL_NORMAL)
}

public Fw_RoundRespawn_Pre(id)
{
	if (!get_pcvar_num(g_pEnabled))
		return HAM_IGNORED

	if (1 <= id <= 32 && g_bPermaDead[id])
		return HAM_SUPERCEDE

	return HAM_IGNORED
}

/*
	The last zombie never actually dies, so CS produces no frag and no kill
	feed entry. Both are recreated here: a frag bump plus a hand-built
	DeathMsg, guarded so our own DeathMsg handler skips it.
*/
CreditEscapeKill(killer, victim)
{
	new Float:fFrags
	pev(killer, pev_frags, fFrags)
	set_pev(killer, pev_frags, fFrags + 1.0)

	new szWeapon[32], szShort[32]
	get_weaponname(get_user_weapon(killer), szWeapon, charsmax(szWeapon))

	// "weapon_ak47" -> "ak47", which is what DeathMsg expects
	if (equal(szWeapon, "weapon_", 7))
		copy(szShort, charsmax(szShort), szWeapon[7])
	else
		copy(szShort, charsmax(szShort), szWeapon)

	g_bFakeDeath = true

	message_begin(MSG_BROADCAST, get_user_msgid("DeathMsg"))
	write_byte(killer)
	write_byte(victim)
	write_byte(0)          // not a headshot - this path is never a melee kill,
	                       // and a melee kill would have been allowed to land
	write_string(szShort)
	message_end()

	g_bFakeDeath = false

	/*
		The fake DeathMsg above is what puts the skull next to the victim on
		the scoreboard, and this is the one path where no real death and no
		real respawn ever follow to take it off again - the zombie was healed
		in place instead. Clear it here, right next to the line that caused
		it.

		This whole function goes away once mp_round_infinite blocks the team
		extermination check and the last zombie is simply allowed to die.
	*/
	ClearScoreboardDeath(victim)

	// push the new score out so the scoreboard does not lag behind
	message_begin(MSG_BROADCAST, get_user_msgid("ScoreInfo"))
	write_byte(killer)
	write_short(get_user_frags(killer))
	write_short(get_user_deaths(killer))
	write_short(0)
	write_short(get_user_team(killer))
	message_end()
}

/*
	spk rather than emit_sound: emit_sound ties the sound to a player entity
	and one of its channels, so anything else on that channel replaces it and
	a round flip tears the whole set down. spk plays straight on the client,
	outside the entity channel system.
*/
PlayKillSound(id, const sound[])
{
	if (!is_user_connected(id))
		return

	client_cmd(id, "spk ^"%s^"", sound)
}

RespawnZombie(id)
{
	new hp = zp_get_zombie_maxhealth(id)

	if (hp < 1)
		hp = 1000

	set_pev(id, pev_health, float(hp))

	if (g_iSpawns > 0)
	{
		new i = random_num(0, g_iSpawns - 1)
		engfunc(EngFunc_SetOrigin, id, g_fSpawn[i])
		set_pev(id, pev_velocity, Float:{0.0, 0.0, 0.0})
	}
}

CollectSpawns()
{
	g_iSpawns = 0

	new ent, Float:o[3]
	new const szClasses[2][] = { "info_player_deathmatch", "info_player_start" }

	for (new c = 0; c < 2; c++)
	{
		ent = -1

		while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", szClasses[c])) > 0)
		{
			if (g_iSpawns >= MAX_SPAWNS)
				return

			pev(ent, pev_origin, o)

			g_fSpawn[g_iSpawns][0] = o[0]
			g_fSpawn[g_iSpawns][1] = o[1]
			g_fSpawn[g_iSpawns][2] = o[2]
			g_iSpawns++
		}
	}
}
