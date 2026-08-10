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
	   seconds. The zombie team can be empty for that whole window; the round
	   simply does not react to it (see the gate below).

	Why respawn is handled here instead of by zp_deathmatch:
	    ZP respawns on a timer, so for zp_spawn_delay seconds the zombie team
	    is empty and CS hands the round to the humans. Shooting the last
	    zombie in the leg used to win the round outright.

	    That used to be worked around by cancelling the lethal hit on the
	    last zombie in Ham_TakeDamage, because CS runs its win check inside
	    CBasePlayer::Killed, before any post hook could get a respawn in. The
	    last zombie is not a special case any more: every lethal hit kills,
	    full stop, and the zombie team can genuinely sit at zero for up to
	    zp_rules_respawn_delay seconds while a respawn is pending. What makes
	    that safe is g_pRoundInfinite - UpdateRoundEndGate() holds CS's own
	    team-extermination check off for as long as anyone can still come
	    back, and releases it the instant nothing more can.

	    Round win by headshot is still gone, for the same reason it always
	    was: a lethal headshot is a non-melee hit, so Fw_Killed_Post schedules
	    a respawn for it and the gate stays held even when it was the last
	    zombie standing. Only melee, via permadeath, skips the respawn and
	    lets the gate - and the round - close.

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
*/

#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <zombieplague>

#define TASK_RESPAWN 8100

/*
	zombie_plague40.sma's own task id for picking this round's zombies.
	enum (+= 100) { TASK_MODEL = 2000, TASK_TEAM, TASK_SPAWN, TASK_BLOOD,
	TASK_AURA, TASK_BURN, TASK_NVISION, TASK_FLASH, TASK_CHARGE,
	TASK_SHOWHUD, TASK_MAKEZOMBIE, ... } at zombie_plague40.sma:86-103 puts
	it 11th, so 2000 + 10*100 = 3000. zombieplague.inc does not export it,
	but zombie_plague40.sma itself gates on task_exists(TASK_MAKEZOMBIE) at
	line 7524 for the same reason we need it here, so it is a real signal,
	just an unexported one. Re-derive this if zombie_plague40.sma is ever
	recompiled with a different task enum.
*/
#define ZP_TASK_MAKEZOMBIE 3000

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

new g_pEnabled, g_pAnnounce, g_pKillSound, g_pRespawn, g_pRespawnDelay
new g_pDebug, g_pRespawnSound

/*
	CS ends the round the moment a team has nobody alive. That is right when
	the team is gone for good and wrong while someone is still on their way
	back, and CS cannot tell the difference.

	ReGameDLL can. mp_round_infinite takes one flag per round-end check and
	"f" is the team extermination one. Hold it while any zombie can still
	return, release it when none can, and CS's own check becomes correct -
	no cancelled damage, no healing anyone back to full.
*/
new g_pRoundInfinite

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

	/*
		A normal death used to come straight back on the same frame because
		the last zombie was never allowed to actually die. Now every death is
		real and this can leave the zombie team empty for the whole delay -
		see g_pRoundInfinite, which is what makes that safe.
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

	g_pRoundInfinite = get_cvar_pointer("mp_round_infinite")

	if (!g_pRoundInfinite)
		log_amx("[RULES] mp_round_infinite not found - ReGameDLL is not loaded, the round-end gate is OFF")

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

	// a fresh round always starts held; zombies have not been picked yet, so
	// the count would read zero and open the gate at exactly the wrong time
	if (g_pRoundInfinite)
		set_pcvar_string(g_pRoundInfinite, "f")
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

/*
	Can any zombie still come back? Alive counts, and so does dead with a
	respawn already scheduled. Tasks are asked directly rather than kept in a
	counter, because a counter is one missed decrement away from wedging the
	round open forever.
*/
CountZombiesThatCanReturn()
{
	new n = zp_get_zombie_count()

	for (new i = 1; i <= 32; i++)
	{
		if (task_exists(i + TASK_RESPAWN))
			n++
	}

	return n
}

UpdateRoundEndGate()
{
	if (!g_pRoundInfinite)
		return

	new n = CountZombiesThatCanReturn()
	new bool:bHold = (n > 0)

	set_pcvar_string(g_pRoundInfinite, bHold ? "f" : "0")

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] gate zombiesThatCanReturn=%d -> mp_round_infinite=%s", n, bHold ? "f" : "0")
}

public Fw_TakeDamage_Pre(victim, inflictor, attacker, Float:damage, damagebits)
{
	/*
		All this hook does now is remember how the blow landed, because
		Event_DeathMsg only ever sees a headshot flag of its own and cannot
		tell a stab from a shot.

		It used to decide whether the victim was allowed to die. It no longer
		has to: mp_round_infinite keeps CS from reacting to an empty zombie
		team, so a lethal hit on the last zombie is just a lethal hit.
	*/
	if (1 <= victim <= 32)
		g_bMeleeHit[victim] = IsMeleeHit(attacker, damagebits)

	return HAM_IGNORED
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

		UpdateRoundEndGate()
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

	UpdateRoundEndGate()
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

	/*
		zombie_plague40.sma has not picked this round's zombies yet (its own
		g_newround is still true - zombie_plague40.sma:1543-5040) whenever
		TASK_MAKEZOMBIE is still pending. Its fw_PlayerSpawn_Post
		(zombie_plague40.sma:1795) only calls zombieme() when
		g_respawn_as_zombie[id] && !g_newround, so spawning into this window
		falls through to the human path and skips the weapon strip - a
		zombie holding a gun. A zombie can still be alive and get killed
		during this window (it survived from the previous round), so this is
		a real, observed case, not a hypothetical one. Wait it out instead.
	*/
	if (task_exists(ZP_TASK_MAKEZOMBIE))
	{
		if (get_pcvar_num(g_pDebug))
			log_amx("[RULES] respawn_task victim=%d SKIPPED zp still picking zombies this round - retry in 0.5s", id)

		set_task(0.5, "Task_Respawn", taskid)
		return
	}

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] respawn_task victim=%d -> respawning as zombie", id)

	zp_respawn_user(id, ZP_TEAM_ZOMBIE)
	ClearScoreboardDeath(id)
	PlayRespawnSound()

	UpdateRoundEndGate()
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
