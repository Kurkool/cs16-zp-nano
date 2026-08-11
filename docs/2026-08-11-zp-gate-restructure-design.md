# ZP Round-End Gate — Restructure Design

**Status:** built 2026-08-12, on ReAPI 5.29.0.358
**Branch:** `feat/round-rules`, on top of `91e34b3` (the verified-in-game build)
**Supersedes the gate implementation in:** `2026-08-10-zp-round-rules-design.md` (that
document's *design* is unchanged and was verified; this replaces how it is expressed
in code)

## Why this exists

The round-end gate works. All four outcomes were verified in game on 2026-08-11.
The problem is not the behaviour, it is the shape.

`mp_round_infinite` is currently a piece of persistent state that eight sites write
or recompute, and that must be correct at every instant because CS can read it at
any time. Only two of those sites can actually run before a win check. Three fix
rounds produced the same bug three times: the gate read mid-transition, with a
hand-written correction for that moment that was wrong. Each round audited one site
and inherited the other seven. The reviewer put another Critical at roughly even
money on a fourth patch pass.

This design removes the class rather than the instance.

**The one idea:** `mp_round_infinite` stops being state and becomes an argument,
computed at the instant it is read. The question "is the gate correct right now?"
stops existing, because there is no "right now" other than the moment of the
decision.

## Source references

Line numbers below are from ReGameDLL_CS 5.30.0.814, file
`regamedll/dlls/multiplay_gamerules.cpp`. A copy used during this work is at
`.superpowers/sdd/2026-08-10-zp-round-rules-plan/regamedll-multiplay_gamerules.cpp`
(git-ignored). ZP line numbers are from the shipped `zombie_plague40.sma`.

`CheckWinConditions()` has exactly three callers:

| Caller | Line | Reachable from |
|---|---|---|
| `DeathNotice`, inside `CBasePlayer::Killed` | `:4185` | every death |
| `ClientDisconnected` | `:3686` | every disconnect |
| `ChangePlayerTeam` | `:5199` | a **live** player changing team only |

`Think()` never calls it. `ChangePlayerTeam` returns at `:5160` when
`!pPlayer->IsAlive()`, so a dead player joining spectators never reaches a win
check at all.

Inside `CheckWinConditions()` the ordering that matters:

```
:888   if (m_iRoundWinStatus != WINSTATUS_NONE) { ...; return; }   // repeat calls are a no-op
:903   scenarioFlags = UTIL_ReadFlags(round_infinite.string)       // the cvar is read HERE
:913   if (HasRoundInfinite()) return;
:935   if (!(scenarioFlags & SCENARIO_BLOCK_TEAM_EXTERMINATION) && TeamExterminationCheck(...))
```

`DeathNotice` sends `DeathMsg` at `:4142`, before the `CheckWinConditions()` call at
`:4185`. That ordering is what makes `g_bPermaDead` final by the time the gate is
computed, and it was confirmed in game on 2026-08-11.

## New dependency: ReAPI

`CheckWinConditions` is declared with `LINK_HOOK_CLASS_VOID_CUSTOM_CHAIN2` and
`__API_HOOK` at `:881`/`:884`, so ReAPI can hook it. `TeamExterminationCheck` at
`:1396` is a plain method and cannot be hooked — the gate still works through
`mp_round_infinite`, it is just written in one place now.

ReAPI is an AMXX module (`addons/amxmodx/modules/reapi_amxx.dll`, registered in
`configs/modules.ini`). It needs ReGameDLL, which this server has; it does not need
ReHLDS, because only game-side hooks are used. It lives under `addons/`, which
Steam's file verification does not touch — unlike `dlls/mp.dll` and `delta.lst`,
which it silently reverts.

**This is a gated assumption, not a given.** See "Risk gate" below.

## Architecture

```
CS wants to decide the round
      |
      v
CHalfLifeMultiplay::CheckWinConditions()
      |
      +-- [ReAPI pre-hook] Gate_Pre()
      |        one pass over players 1..32
      |        writes mp_round_infinite
      |
      v :903  the cvar is read, a few lines later, in the same call
      v :935  TeamExterminationCheck runs or is blocked accordingly
```

(ReAPI's hook chain enum for this is `RG_CSGameRules_CheckWinConditions` — named
after the second argument of the `LINK_HOOK_CLASS_VOID_CUSTOM_CHAIN2` macro that
declares it at `:881`, not the C++ class shown above. Confirmed in "Risk gate"
below.)

### Sites that write `mp_round_infinite`

| Before | After |
|---|---|
| `Event_NewRound` forces `"f"` | removed |
| `Fw_Killed_Post`, respawn-off branch | removed |
| `Fw_Killed_Post`, permadead branch | removed |
| `Fw_Killed_Post`, respawn branch | removed |
| `Task_Respawn`, skip path | removed |
| `Task_Respawn`, success path | removed |
| `client_disconnected` | removed — ReGameDLL calls the check itself at `:3686` |
| `Event_DeathMsg`, with a compensation term | removed |
| — | **`Gate_Pre()` — the only decision** |
| `plugin_end` restores `"0"` | kept — teardown, not a decision |

`Event_NewRound`'s forced `"f"` is safe to remove because there is no longer a
window in which a stale value is read. Every win check computes its own, including
one that lands inside the ~24 s window at the start of a round where ZP has not yet
picked zombies.

`ChangePlayerTeam` with `bKill=TRUE` needs no special handling: it calls `Killed()`
at `:5189` and `CheckWinConditions()` at `:5199`, so by the time the gate runs,
`Killed` has returned, `Fw_Killed_Post` has run, and `TASK_RESPAWN` exists. The
predicate reads fully settled state.

## The in-flight victim

When the gate runs from `DeathNotice`, the victim is mid-death: ZP has cleared its
own alive flag (`zombie_plague40.sma:1137` -> `:1952`), the engine has set
`deadflag`, and `Fw_Killed_Post` has not run, so no `TASK_RESPAWN` exists yet. That
player is invisible to every other term of the predicate.

One variable states who that is:

```pawn
// who is inside CBasePlayer::Killed right now, or 0
new g_iDyingVictim
```

Set in `Fw_Killed_Pre`, cleared in `Fw_Killed_Post`, reset in `Event_NewRound` as a
round-boundary net.

`Fw_Killed_Post` currently has four exit paths. A missed clear on any of them
latches the gate — the same shape as the `free_tr2()` bug this server has already
paid for. So it is restructured to a single exit by construction:

```pawn
public Fw_Killed_Post(victim, attacker, shouldgib)
{
	ScheduleRespawn(victim)   // all branching moves in here, may return early freely
	g_iDyingVictim = 0        // one exit, always reached
	return HAM_IGNORED
}
```

## The predicate

```pawn
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
		Fw_Killed_Post is about to do, so mirror its own two conditions.

		Deliberately NOT g_bWasZombie: Fw_Killed_Post schedules a respawn for
		any non-permadead victim and Task_Respawn always returns them on
		ZP_TEAM_ZOMBIE. A dying human is a zombie that can return. Gating on
		the victim's past team undercounts by one on every human death,
		including inside the ~24 s window where last round's zombies still sit
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
	return task_exists(id + TASK_RESPAWN)
}

/*
	...and on the human side. Simpler, because nothing on this server respawns
	anyone as a human. ZP's zp_respawn_on_worldspawn_kill can, but only within
	2 s of a spawn, and it bails on g_endround (zombie_plague40.sma:7489),
	which ReGameDLL sets synchronously from inside the very check this gate is
	deciding. It cannot race us.
*/
bool:WillCountAsHuman(id)
{
	if (!is_user_connected(id) || id == g_iDyingVictim)
		return false

	return is_user_alive(id) && !zp_get_user_zombie(id)
}
```

```pawn
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

	set_pcvar_string(g_pRoundInfinite, bHold ? "f" : "0")

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] gate zombies=%d humans=%d dying=%d -> mp_round_infinite=%s",
			zombies, humans, g_iDyingVictim, bHold ? "f" : "0")
}
```

`else if` is deliberate: a player is counted on at most one side. Double-counting
becomes structurally impossible rather than merely avoided.

`set_pcvar_string` replaces the whole flag string, not just the `"f"` bit. Harmless
while nothing else on this server drives `mp_round_infinite`; it would stomp other
flags if that ever changes.

### Every player state, checked

| State | zombie | human | correct |
|---|---|---|---|
| alive zombie | yes | | yes |
| alive human | | yes | yes |
| dead, `TASK_RESPAWN` pending | yes | | yes — returns as a zombie |
| dying, not permadead | yes | | yes — about to be booked |
| dying, permadead | | | yes — gone for the round |
| dead, permadead, no task | | | yes |
| spectator / respawn refused | | | yes — **the Important finding** |
| disconnected | | | yes |

## Findings closed

**Important — a dead player who joins spectators latches the gate held.**
Dissolved. `Task_Respawn` no longer writes the gate, so there is nothing to latch,
and a refused respawn leaves the player as dead-with-no-task, which the predicate
already reads as gone. Note that this defect was never able to *end a round
wrongly*: `ChangePlayerTeam` returns at `:5160` for a dead player, so no win check
runs at that moment. Its real cost was that the round could then only end on the
clock.

**Low — the compensation term can only add, never subtract.** Dissolved. There is
no compensation term. Each player is classified exactly once.

**Also fixed, not previously reported:** `Task_Respawn` calls
`ClearScoreboardDeath()` and `PlayRespawnSound()` regardless of whether
`zp_respawn_user()` succeeded. A refused respawn currently clears the skull for a
player who is still dead and plays the zombie-arrival sound for nobody. Both now sit
behind the success branch.

## Closing "the round can only end on the clock"

`Task_Respawn` is the one moment where "no zombie can return" can become true with
no `CheckWinConditions()` coming. AMXX cannot call it directly — the Orpheu route
was tried and all seven signatures failed on build 10210. ReAPI can.

```pawn
if (zp_respawn_user(id, ZP_TEAM_ZOMBIE))
{
	ClearScoreboardDeath(id)
	PlayRespawnSound()
}
else
{
	// allowed_respawn() refuses for spectators and once the round has ended.
	// Nothing to clean up - no task survives this callback and the predicate
	// reads them as gone - but it must be visible in the log, or a player
	// simply never comes back with no line saying why.
	log_amx("[RULES] respawn_task victim=%d REFUSED by zp - staying dead this round", id)
}

rg_check_win_conditions()
```

Safe to call unconditionally: the guard at `:888` makes it a no-op once a winner is
decided, so there is no double round-end.

Not needed in `client_disconnected` — ReGameDLL calls the check itself at `:3686`.

## Risk gate

The whole design rests on ReAPI loading and hooking correctly on this build. That
has never been observed, exactly as `mp_round_infinite` had never been observed
before Task 1. Same treatment: prove it, then build on it.

1. Install `reapi_amxx.dll`, add it to `configs/modules.ini`.
2. Restart. `amxx modules` must show reapi **running**, not error.
3. A throwaway probe plugin: register the hook, one `log_amx` line.
4. Play until someone dies. The line must appear, and must appear *before* the
   round decision.
5. Any step fails: remove the `.dll`, fall back to the no-dependency design
   recorded under "Rejected alternative" below.

ReAPI must support ReGameDLL 5.30.0.814's API version. A mismatch is reported at
load rather than failing silently.

**The ReAPI hook and native names in this document are written from memory and must
be checked against the shipped `reapi.inc` before use.** This server has already
paid for trusting an unverified artefact once (`za_ru_lavam4a1` running a shipped
binary that matched no local build).

### Outcome (2026-08-11)

Steps 6, 11 and 12 passed on ReAPI **5.29.0.358**. The risk gate is open.

**Step 6 — module loads.** `reapi` shows `running`, and the hook re-registers
cleanly across map changes:
```
L 08/11/2026 - 22:25:37: [test_reapi_probe.amxx] [PROBE] RegisterHookChain(CheckWinConditions, pre) returned 4210689
L 08/11/2026 - 22:34:39: [test_reapi_probe.amxx] [PROBE] RegisterHookChain(CheckWinConditions, pre) returned 4210689
```

**Step 11 — control run (`probe_hold 0`).** Humans won when the last zombie was
shot; the test can detect a round ending:
```
L 08/11/2026 - 22:30:13: [test_reapi_probe.amxx] [PROBE] CheckWinConditions pre-hook fired, wrote mp_round_infinite=0
```

**Step 12 — real test (`probe_hold 1`).** The round did not end, in both
directions of `TeamExterminationCheck` (tested separately): last zombie shot
dead, and all humans dead.
```
L 08/11/2026 - 22:31:03: [test_reapi_probe.amxx] [PROBE] CheckWinConditions pre-hook fired, wrote mp_round_infinite=f
L 08/11/2026 - 22:31:59: [test_reapi_probe.amxx] [PROBE] CheckWinConditions pre-hook fired, wrote mp_round_infinite=f
```
No further `CheckWinConditions` calls for 2.5 minutes after 22:31:59, until the
map changed at 22:34:35 — nobody left alive to die, so nothing left to trigger a
check.

**Naming correction.** The real hook chain enum is
**`RG_CSGameRules_CheckWinConditions`**, not the `RG_CHalfLifeMultiplay_…` form
this document's prose implied (see the Architecture diagram above, now
annotated). It is re-derivable from source: `multiplay_gamerules.cpp:881` reads
`LINK_HOOK_CLASS_VOID_CUSTOM_CHAIN2(CHalfLifeMultiplay, CSGameRules, CheckWinConditions)`,
and ReAPI names the hook chain after the macro's **second** argument
(`CSGameRules`), not the first, which is the actual C++ class
(`CHalfLifeMultiplay`). Confirmed against the shipped
`reapi_gamedll_const.inc:1202`. The native name, `rg_check_win_conditions()`,
matched this document as written — no correction needed there. Task 2 must use
the corrected hook name.

**Observation for Task 2.** In testing, `CheckWinConditions` was observed firing
in pairs — two calls within the same second per death event — so `Gate_Pre()`
will run about twice per event. It is idempotent and cheap, so this is
harmless, but duplicate `[RULES] gate` lines in Task 2's logs are expected and
must not be read as a bug.

## Rollback

| Layer | How |
|---|---|
| plugin | `zp_round_rules.amxx.prev` |
| pre-rewrite behaviour | `zp_headshot_permadeath.amxx.prev` (still on disk) |
| ReAPI | delete the `.dll` and its `modules.ini` line |
| the whole change | reset to `91e34b3`, the verified-in-game commit |

Plan Step 10 — deleting `zp_headshot_permadeath.sma` and its `.amxx` — stays
deferred until this lands.

## Verification

Manual and in game; there is no test framework here. Every case needs its `[RULES]`
log line quoted. No log line, no pass.

Cases 1–4 are re-runs: this restructure touches code that was just proven correct,
and that is the cost the handoff named.

| # | Case | Expected |
|---|---|---|
| 1 | gun-kill the last zombie | round continues, respawn lands — `gate zombies=1 ... -> f` |
| 2 | melee the last zombie | Human Victory — `gate zombies=0 ... -> 0` |
| 3 | zombies wipe the humans | Zombie Victory — `gate ... humans=0 -> 0` |
| 4 | clock expires, humans alive | Human Victory |
| 5 | **new** — last zombie dies, then joins spectators | `REFUSED by zp`, then the round **ends** rather than hanging |
| 6 | **new** — a live player changes team mid-round | the hook fires; no wrong round end |
| 7 | **new** — a death inside the ~24 s window before ZP picks zombies | the round does not end |

Case 7 is the NEW-1 Critical scenario from fix round 2. It was a real bug; it earns
a permanent case.

Case 5 is awkward to stage — raise `zp_rules_respawn_delay` temporarily so there is
time to reach the spectate menu.

Test settings currently in place and still needed: `yb_difficulty "4"` in
`addons/yapb/conf/yapb.cfg` and `mp_roundtime 3` in `listenserver.cfg`, both with
`.bak` files beside them, neither tracked by git. Restore them when the round-rules
work is finished.

## Rejected alternative — no new dependency

Keep the cvar as state, but restructure to: the same single predicate, written from
only `Event_DeathMsg` and `client_disconnected`, plus "momentary release" — release
the gate only for the instant the win check reads it and re-arm to `"f"` on a
0.1 s task, making *held* the resting state so uncovered win checks fail safe.

Rejected because it leaves two gaps that ReAPI closes outright: a live player
changing team reads a stale-but-safe value and the round then hangs to the clock,
and a refused respawn does the same. Both stop being rare if the server is ever
opened to real players, which is the stated intent. It remains the fallback if the
risk gate fails.

## Out of scope

- The intermittent winner text. It is ZP's announcement layer, not the gate. The
  `dhudmessage.inc` shim was checked and is clean.
- Task 4 of the original plan (clearing out the Orpheu experiment). Independent;
  nothing depends on it.
- Recompiling `zombie_plague40.amxx`. Never — its `.sma` does not match the running
  binary.
- Extra-item price balance, and FastDL for the ~30 MB of client files that opening
  the server to real players would need. Both known, both deferred.
