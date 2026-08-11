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
	    that safe is g_pRoundInfinite. Gate_Pre() is a ReAPI pre-hook on
	    CheckWinConditions: it answers "can anyone still come back" at the
	    instant CS asks, a few lines before ReGameDLL reads the "f" bit.
	    CheckRoundTimeExpired() (multiplay_gamerules.cpp:3052) reads the
	    same cvar string every frame from Think(), but never tests "f" -
	    that is the only bit this plugin writes, so nothing that decides a
	    round outcome reads it in between.

	    Round win by headshot is still gone, for the same reason it always
	    was: a lethal headshot is a non-melee hit, so ScheduleRespawn schedules
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
#include <reapi>

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

/*
	Safety cap on the retry loop in Task_Respawn. zombie_plague40.sma's own
	window (2.0 + zp_delay seconds - zp_delay is 22 on this server right
	now, see zombieplague.cfg) is comfortably under half of this. The only
	way to actually hit the cap is make_zombie_task itself stuck retrying
	because no player is alive at all (zombie_plague40.sma:5033-5037), which
	this plugin cannot fix either way - giving up and respawning anyway
	beats leaving the player stuck dead for the rest of the round.
*/
#define MAX_MAKEZOMBIE_RETRIES 120

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

// consecutive Task_Respawn attempts blocked by ZP_TASK_MAKEZOMBIE still
// being pending, see MAX_MAKEZOMBIE_RETRIES
new g_iMakeZombieRetries[33]

new g_pEnabled, g_pAnnounce, g_pKillSound, g_pRespawn, g_pRespawnDelay
new g_pDebug, g_pRespawnSound

/*
	CS ends the round the moment a team has nobody alive. That is right when
	the team is gone for good and wrong while someone is still on their way
	back, and CS cannot tell the difference.

	ReGameDLL can. mp_round_infinite takes one flag per round-end check and
	"f" is the team extermination one. Compute it at the moment CS asks and
	it is right by construction - hold while any zombie can still return,
	release when none can, and CS's own check becomes correct - no cancelled
	damage, no healing anyone back to full.

	That one flag covers BOTH outcomes of the same check, not just the
	human-win half - see Gate_Pre() for why it also has to release
	the instant no human is left alive. set_pcvar_string() replaces the
	whole flag string too, not just this bit; harmless today since nothing
	else on this server drives mp_round_infinite, but worth knowing if that
	ever changes.
*/
new g_pRoundInfinite

/*
	Who is inside CBasePlayer::Killed right now, or 0.

	When the gate runs from DeathNotice (multiplay_gamerules.cpp:4185) the
	victim is mid-death: ZP has cleared its own alive flag
	(zombie_plague40.sma:1137 -> :1952), the engine has set deadflag, and
	Fw_Killed_Post has not run - so there is no TASK_RESPAWN to find either.
	That player is invisible to every other term of the predicate, and this is
	how it is told they exist.
*/
new g_iDyingVictim

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

	/*
		The gate is computed here and nowhere else. CheckWinConditions reads
		mp_round_infinite at multiplay_gamerules.cpp:903, a few lines into its
		own body, so a pre-hook write lands in the same call with nothing able
		to run in between. That is what stops the cvar from being state that
		has to be right at every instant.
	*/
	new HookChain:hGatePre = RegisterHookChain(RG_CSGameRules_CheckWinConditions, "Gate_Pre", false)

	if (hGatePre == INVALID_HOOKCHAIN)
		log_amx("[RULES] RegisterHookChain(CheckWinConditions) failed - Gate_Pre will never run, mp_round_infinite will never be written, the round-end gate is OFF")

	register_event("HLTV", "Event_NewRound", "a", "1=0", "2=0")
	register_event("DeathMsg", "Event_DeathMsg", "a")

	RegisterHam(Ham_TakeDamage,  "player", "Fw_TakeDamage_Pre",  0)
	RegisterHam(Ham_Killed,      "player", "Fw_Killed_Pre",      0)
	RegisterHam(Ham_Killed,      "player", "Fw_Killed_Post",     1)
	RegisterHam(Ham_CS_RoundRespawn, "player", "Fw_RoundRespawn_Pre", 0)
}

public plugin_end()
{
	// leaves mp_round_infinite exactly as ReGameDLL defaults it (no flags
	// held). Without this, disabling the plugin or rolling back the .amxx
	// while the gate happens to be "f" bricks round-extermination in BOTH
	// directions for the rest of the map, with nothing left running to
	// release it.
	if (g_pRoundInfinite)
		set_pcvar_string(g_pRoundInfinite, "0")
}

public client_putinserver(id)
{
	g_bPermaDead[id] = false
	g_bWasZombie[id] = false
	g_bMeleeHit[id]  = false
	g_iMakeZombieRetries[id] = 0
}

public client_disconnected(id)
{
	g_bPermaDead[id] = false
	g_bWasZombie[id] = false
	g_bMeleeHit[id]  = false
	g_iMakeZombieRetries[id] = 0

	/*
		ReGameDLL calls CheckWinConditions itself from ClientDisconnected
		(multiplay_gamerules.cpp:3686), so Gate_Pre runs for this disconnect
		without being asked. Removing the task below is what makes it read
		correctly - and WillCountAsZombie() checks is_user_connected() first
		anyway, so the answer is right whichever side of that call this
		forward happens to fire on.
	*/
	remove_task(id + TASK_RESPAWN)
}

public Event_NewRound()
{
	for (new i = 1; i <= 32; i++)
	{
		g_bPermaDead[i] = false
		g_bMeleeHit[i]  = false
		g_iMakeZombieRetries[i] = 0

		// a respawn still in flight from the previous round would fire into
		// the new one
		remove_task(i + TASK_RESPAWN)
	}

	/*
		No forced "f" here any more. Every extermination check computes
		its own "f" value fresh (Gate_Pre), including one that lands
		inside the ~24s window before ZP has picked this round's zombies -
		nothing that decides a round outcome ever sees a stale one.

		g_iDyingVictim is reset as a round-boundary net. Fw_Killed_Post's
		single exit is what actually keeps it honest.
	*/
	g_iDyingVictim = 0
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
	Will this player be alive on the zombie side once everything currently in
	flight has settled?

	One question, asked the same way about every player. The old code asked a
	different question at each of eight call sites and corrected the answer by
	hand for whichever moment it happened to be; every bug across three fix
	rounds was one of those corrections being wrong.
*/
bool:WillCountAsZombie(id)
{
	if (!is_user_connected(id))
		return false

	/*
		Inside CBasePlayer::Killed right now. What decides it is what
		ScheduleRespawn is about to do, so mirror its own two conditions.

		Deliberately NOT g_bWasZombie: a respawn is scheduled for any
		non-permadead victim and Task_Respawn always returns them on
		ZP_TEAM_ZOMBIE, so a dying human is a zombie that can return. Gating on
		the victim's past team undercounts by one on every human death,
		including inside the ~24s window where last round's zombies still sit
		on team T with zp_get_zombie_count() already back at 0 - that was
		NEW-1 Critical in fix round 2.

		g_bPermaDead is final here: Event_DeathMsg sets it, and DeathNotice
		sends DeathMsg at :4142 before calling CheckWinConditions at :4185.
	*/
	if (id == g_iDyingVictim)
		return get_pcvar_num(g_pRespawn) != 0 && !g_bPermaDead[id]

	if (is_user_alive(id))
		return zp_get_user_zombie(id) != 0

	// dead, but a respawn is already booked
	return task_exists(id + TASK_RESPAWN) != 0
}

/*
	...and on the human side. Simpler, because nothing on this server respawns
	anyone as a human. ZP's zp_respawn_on_worldspawn_kill can, but only within
	2s of a spawn, and it bails on g_endround (zombie_plague40.sma:7489), which
	ReGameDLL sets synchronously from inside the very check this gate is
	deciding. It cannot race us.
*/
bool:WillCountAsHuman(id)
{
	if (!is_user_connected(id) || id == g_iDyingVictim)
		return false

	return is_user_alive(id) && !zp_get_user_zombie(id)
}

/*
	The only place mp_round_infinite is decided. Runs as a ReAPI pre-hook on
	CheckWinConditions, so it is separated from the read at :903 by a handful
	of lines inside one call - there is no window for the value to go stale,
	because there is no gap.
*/
public Gate_Pre()
{
	if (!g_pRoundInfinite)
		return

	new zombies, humans

	for (new id = 1; id <= 32; id++)
	{
		if      (WillCountAsZombie(id)) zombies++
		else if (WillCountAsHuman(id))  humans++
	}

	/*
		"f" blocks ONE ReGameDLL check that decides BOTH extermination
		outcomes (TeamExterminationCheck): humans win at zero zombies, zombies
		win at zero humans. Hold only while both sides still have someone, or
		one of the two win paths wedges shut permanently.

		ZP kills the last human rather than infecting them
		(zombie_plague40.sma:2130-2132) precisely so the zombie-win branch has
		a corpse still on CT to fire on. Do not "fix" that.
	*/
	new bool:bHold = (zombies > 0 && humans > 0)

	// this sets the whole flag string, not just the "f" bit - harmless while
	// nothing else on this server drives mp_round_infinite's other flags
	set_pcvar_string(g_pRoundInfinite, bHold ? "f" : "0")

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] gate zombies=%d humans=%d dying=%d -> mp_round_infinite=%s",
			zombies, humans, g_iDyingVictim, bHold ? "f" : "0")
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
	{
		g_bWasZombie[victim] = (zp_get_user_zombie(victim) != 0)
		g_iDyingVictim = victim
	}

	return HAM_IGNORED
}

public Fw_Killed_Post(victim, attacker, shouldgib)
{
	ScheduleRespawn(victim)

	// one exit, always reached. The branching all lives in ScheduleRespawn,
	// which may return early as often as it likes.
	g_iDyingVictim = 0

	return HAM_IGNORED
}

ScheduleRespawn(victim)
{
	if (!get_pcvar_num(g_pRespawn))
		return

	if (victim < 1 || victim > 32 || !is_user_connected(victim))
		return

	/*
		Clean up before branching on permadead, not after. A stale
		TASK_RESPAWN can exist here - ZP's own respawn_player_check_task can
		revive a player out from under a pending retry, and if they then die
		again on their next life the old task is still scheduled. The retry
		counter is reset here too, so it is scoped to one respawn attempt
		instead of accumulating across a player's whole connection (see
		MAX_MAKEZOMBIE_RETRIES).
	*/
	remove_task(victim + TASK_RESPAWN)
	g_iMakeZombieRetries[victim] = 0

	// DeathMsg is emitted from inside CBasePlayer::Killed, so it has already
	// run by the time this post hook does and the flag is settled
	if (g_bPermaDead[victim])
	{
		if (get_pcvar_num(g_pDebug))
			log_amx("[RULES] killed_post victim=%d permadead=1 -> NO respawn, stays down", victim)

		return
	}

	new Float:delay = get_pcvar_float(g_pRespawnDelay)

	/*
		Floored, not branched. A delay of zero or less used to call
		zp_respawn_user() straight from this post hook instead of scheduling
		a task - the one respawn on this server that left no TASK_RESPAWN
		behind it, so it was invisible to WillCountAsZombie()'s
		task_exists() term.

		It also bypassed Task_Respawn entirely, and with it the
		ZP_TASK_MAKEZOMBIE retry guard below: a death that hit this path
		during ZP's pre-pick window would have respawned straight through
		ZP's own fw_PlayerSpawn_Post human path, producing exactly the
		"zombie holding a gun" bug that retry guard exists to prevent.
		Routing every respawn through Task_Respawn closes both gaps at once.
	*/
	if (delay < 0.1)
		delay = 0.1

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] killed_post victim=%d permadead=0 -> respawn in %.2fs", victim, delay)

	set_task(delay, "Task_Respawn", victim + TASK_RESPAWN)
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

		/*
			AMXX only frees a one-shot task after its callback returns, so
			task_exists(taskid) would still match THIS invocation until this
			function is done. Remove it explicitly - WillCountAsZombie() reads
			that task, and the next win check must not see one for a player
			who is not coming back.
		*/
		remove_task(taskid)
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
	// outside=1: id 3000 belongs to zombie_plague40.sma, not to us, and
	// task_exists() only searches the calling plugin's own tasks unless
	// told otherwise (amxmodx.inc:1824). Without this it always reads 0 and
	// the whole retry branch below never fires.
	if (task_exists(ZP_TASK_MAKEZOMBIE, 1))
	{
		g_iMakeZombieRetries[id]++

		if (g_iMakeZombieRetries[id] <= MAX_MAKEZOMBIE_RETRIES)
		{
			if (get_pcvar_num(g_pDebug))
				log_amx("[RULES] respawn_task victim=%d SKIPPED zp still picking zombies this round - retry in 0.5s (%d/%d)",
					id, g_iMakeZombieRetries[id], MAX_MAKEZOMBIE_RETRIES)

			set_task(0.5, "Task_Respawn", taskid)
			return
		}

		log_amx("[RULES] respawn_task victim=%d gave up waiting on zp after %d retries - respawning anyway, may hold a gun",
			id, g_iMakeZombieRetries[id])
	}

	g_iMakeZombieRetries[id] = 0

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] respawn_task victim=%d -> respawning as zombie", id)

	if (zp_respawn_user(id, ZP_TEAM_ZOMBIE))
	{
		ClearScoreboardDeath(id)
		PlayRespawnSound()
	}
	else
	{
		/*
			allowed_respawn() refuses for spectators and once the round has
			ended (zombie_plague40.sma:8764-8774). Nothing else is going to
			bring this player back, so they are out for the round - but it has
			to be visible, or they simply never return with no line saying why.
		*/
		log_amx("[RULES] respawn_task victim=%d REFUSED by zp - staying dead this round", id)
	}

	/*
		Drop this task before asking for the check, not after.

		AMXX frees a one-shot task only once its callback returns, so until
		this function does, task_exists(taskid) still finds THIS invocation -
		and WillCountAsZombie()'s last term reads exactly that task. Without
		this line, a refused respawn is counted as a zombie who can still
		return: the gate holds, and the round hangs to the clock. Which is the
		precise failure the call below exists to prevent.

		The stale-task skip path earlier in this function already does this,
		for the same reason. It was added there in fix round 2 of the previous
		plan, after the same bug shipped once.
	*/
	remove_task(taskid)

	/*
		The one place the plugin has to start a win check rather than answer
		one. If this was the last zombie and the respawn was refused, nothing
		else is coming: CheckWinConditions has exactly three callers
		(multiplay_gamerules.cpp:4185, :3686, :5199) and none of them is a
		timer. Without this the round could only end on the clock.

		Safe to call unconditionally - the guard at :888 makes it a no-op once
		a winner is already decided, so there is no double round-end. Gate_Pre
		runs first, as it does for any other caller.
	*/
	rg_check_win_conditions()
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

	if (victim < 1 || victim > 32)
		return

	new bool:bWasZombieVictim = g_bWasZombie[victim]

	// only a human killing a zombie earns permadeath / the announce / the
	// special kill sound - one guard condition rather than a chain of early
	// returns
	if (killer >= 1 && killer <= 32 && killer != victim && is_user_connected(killer)
	    && bWasZombieVictim && !zp_get_user_zombie(killer))
	{
		// read_data(3) is the headshot flag and is deliberately ignored -
		// the permakill follows the melee flag cached during TakeDamage
		// instead
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
