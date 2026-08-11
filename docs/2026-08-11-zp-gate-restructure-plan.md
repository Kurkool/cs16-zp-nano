# ZP Round-End Gate Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `mp_round_infinite` an argument computed at the instant CS reads it, instead of persistent state that eight sites must keep correct.

**Architecture:** Install ReAPI and hook `CHalfLifeMultiplay::CheckWinConditions` with a pre-hook. The gate is computed there — a few lines before the cvar is read at `multiplay_gamerules.cpp:903`, in the same call. Eight write sites collapse to one, all three win-check callers are covered by construction, and `rg_check_win_conditions()` lets the plugin ask CS to re-decide when a respawn is refused.

**Tech Stack:** AMX Mod X 1.10.0.5479, Metamod-r 1.3.0.149, Zombie Plague 4.3 Fix6a, ReGameDLL_CS 5.30.0.814, **ReAPI (new)**, CS 1.6 build 10210 (HL25), Windows listen server.

**Design doc:** `docs/2026-08-11-zp-gate-restructure-design.md` (commit `53401a6`)

## Global Constraints

- **Git is live.** `cstrike` is the repository root, remote `https://github.com/Kurkool/cs16-zp-nano`, branch `feat/round-rules`, on top of `91e34b3`. There is no worktree and there cannot be one — the repo root is the directory the game loads from. Every task ends with a real commit.
- **The repository is public and `configs/users.ini` / `configs/sql.cfg` are excluded.** Do not un-ignore them.
- **`*.amxx` is git-ignored**, so still keep `<name>.amxx.prev` beside every installed plugin as the runtime rollback.
- **No test framework exists for AMXX here.** Verification is a named in-game case plus a specific log line. **Never claim a task passes without quoting the log line.**
- **Never recompile `zombie_plague40.amxx`.** Its shipped `.sma` does not match the running `.amxx`.
- **Do not recompile `addon_floating_damage.amxx`.** `plugins-zplague.ini:60-62` records that it was built with its reapi include commented out. Installing ReAPI does not change the compiled plugin and must not be treated as an invitation to rebuild it — that is a separate change with its own verification.
- **Compiler:** `D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting\amxxpc.exe`
- **Plugin list:** `configs/plugins-zplague.ini` — this is the file this server loads custom plugins from, not `plugins.ini`.
- **Melee is marked `DMG_CLUB`.** Never test `DMG_NEVERGIB`; CS bullets set it too.
- **Server root below is written as `<CS>`** = `D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike`.
- **ReGameDLL line numbers** cited below are from `.superpowers/sdd/2026-08-10-zp-round-rules-plan/regamedll-multiplay_gamerules.cpp` (git-ignored copy of 5.30.0.814).

---

## File Structure

| File | Responsibility |
|---|---|
| `<CS>/addons/amxmodx/modules/reapi_amxx.dll` | new — the module. Not tracked by git (binary, and `addons/` binaries are ignored) |
| `<CS>/addons/amxmodx/scripting/include/reapi*.inc` | new — shipped includes. Tracked |
| `<CS>/addons/amxmodx/configs/modules.ini` | enable `reapi` under the third-party section |
| `<CS>/addons/amxmodx/scripting/test_reapi_probe.sma` | new, temporary — Task 1's risk gate only. Deleted in Task 4 |
| `<CS>/addons/amxmodx/scripting/zp_round_rules.sma` | the restructure: one predicate, one gate site |
| `<CS>/addons/amxmodx/configs/zombieplague.cfg` | comment block only — describe when the gate is computed, and fix the stale "headshot" wording |
| `<CS>/addons/amxmodx/configs/plugins-zplague.ini` | add the probe in Task 1, remove it in Task 4 |
| `<CS>/docs/2026-08-11-zp-gate-restructure-design.md` | status line: `approved` → `built` |
| `<CS>/docs/2026-08-11-handoff.md` | rewritten in Task 4 to describe the state after this plan |

---

### Task 1: Prove ReAPI loads and hooks `CheckWinConditions` on this build

No production code. The entire plan rests on a module that has never been loaded here, exactly as Task 1 of the previous plan rested on a cvar that had never been switched on. Same treatment: prove it, then build on it.

**Files:**
- Create: `<CS>/addons/amxmodx/scripting/test_reapi_probe.sma`
- Modify: `<CS>/addons/amxmodx/configs/modules.ini`
- Modify: `<CS>/addons/amxmodx/configs/plugins-zplague.ini`
- Install: `<CS>/addons/amxmodx/modules/reapi_amxx.dll`, `<CS>/addons/amxmodx/scripting/include/reapi*.inc`

**Interfaces:**
- Consumes: nothing.
- Produces: a yes/no answer that gates Tasks 2–4, plus the two confirmed symbol names Task 2 uses — the hook chain constant for `CheckWinConditions` and the native that triggers a check.

- [ ] **Step 1: Confirm ReGameDLL is still the DLL in place**

```powershell
Get-Item "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\dlls\mp.dll" | Select-Object Length, LastWriteTime
```

Expected: `1953280` bytes. If it reads `1131368`, Steam has restored Valve's DLL — restore ReGameDLL before going further, because ReAPI will not load against Valve's `mp.dll`.

- [ ] **Step 2: Download ReAPI**

From `https://github.com/s1lentq/reapi/releases`, take the latest release's Windows binary archive (named `reapi-bin-<version>.zip`). Extract it somewhere outside `<CS>` — for example `C:\Users\USER\Downloads\reapi\`.

Read the release notes and confirm the release supports ReGameDLL **5.30.0.814**. ReAPI checks the ReGameDLL API version at load and reports a mismatch in the log rather than failing silently, so a wrong guess here is detectable at Step 6 — but check first anyway.

- [ ] **Step 3: Check the shipped includes for collisions before copying anything**

ReAPI ships several `.inc` files. Some names may already exist in this server's include directory, and overwriting an existing include would silently change what every other plugin compiles against.

```powershell
$src = "C:\Users\USER\Downloads\reapi\addons\amxmodx\scripting\include"
$dst = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting\include"

Get-ChildItem $src -Filter *.inc | ForEach-Object {
    $exists = Test-Path (Join-Path $dst $_.Name)
    [PSCustomObject]@{ Name = $_.Name; Collides = $exists }
}
```

Expected: `Collides` is `False` for every row. If any row is `True`, **stop** and report which file — do not overwrite it. Resolve that before continuing.

- [ ] **Step 4: Install the module and the includes**

```powershell
$cs  = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike"
$src = "C:\Users\USER\Downloads\reapi\addons\amxmodx"

Copy-Item "$cs\addons\amxmodx\configs\modules.ini" "$cs\addons\amxmodx\configs\modules.ini.bak-reapi"
Copy-Item "$src\modules\reapi_amxx.dll" "$cs\addons\amxmodx\modules\reapi_amxx.dll"
Copy-Item "$src\scripting\include\*.inc" "$cs\addons\amxmodx\scripting\include\"
```

- [ ] **Step 5: Enable the module**

`modules.ini` has an empty third-party section at lines 17–23. Put `reapi` on its own line in the blank space below that header, so the file reads:

```
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Put third party modules below here.              ;;
;; You can just list their names, without the _amxx ;;
;;  or file extension.                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

reapi

```

AMXX would auto-detect it once a plugin includes it, but listing it explicitly means Step 6 can confirm the module itself before any plugin depends on it — which separates "the module is broken" from "my plugin is broken".

- [ ] **Step 6: Restart and confirm the module is running**

Restart the map, then in the game console:

```
amxx modules
```

Expected: a row for `reapi` with status `running`. If it says `error`, read `<CS>/addons/amxmodx/logs/L<date>.log` for the reason — a ReGameDLL API version mismatch reports itself there. **A failure here means stop and go to Step 12.**

- [ ] **Step 7: Confirm the two symbol names against the shipped include**

Do not trust the names written in this plan. Open `<CS>/addons/amxmodx/scripting/include/reapi_gamedll_const.inc` (and `reapi_gamedll.inc` for the natives) and confirm:

- the hook chain enum entry for `CheckWinConditions` — **ANSWERED 2026-08-11: `RG_CSGameRules_CheckWinConditions`**, at `reapi_gamedll_const.inc:1202`. The name guessed in the first draft of this plan, `RG_CHalfLifeMultiplay_CheckWinConditions`, does not exist. The real one is re-derivable from source: `multiplay_gamerules.cpp:881` is `LINK_HOOK_CLASS_VOID_CUSTOM_CHAIN2(CHalfLifeMultiplay, CSGameRules, CheckWinConditions)` and ReAPI names the hook after the macro's **second** argument, not the class.
- the native that triggers a check — **ANSWERED 2026-08-11: `rg_check_win_conditions()`**, at `reapi_gamedll.inc:949`. Matches the guess.

If either differs, use the real name everywhere in this plan. This server has already paid once for trusting an artefact that was never opened (`za_ru_lavam4a1` running a shipped binary that matched no local build).

- [ ] **Step 8: Write the probe**

The probe answers three questions at once: does the hook register, does it fire, and does a write from inside it land before ReGameDLL reads the cvar at `:903`. Only the third one actually matters, and only an in-game round can answer it.

Create `<CS>/addons/amxmodx/scripting/test_reapi_probe.sma`:

```pawn
/*
	TEST ONLY 2026-08-11 - proves ReAPI can hook CheckWinConditions on this
	build, and that a write from inside the pre-hook lands before ReGameDLL
	reads mp_round_infinite at multiplay_gamerules.cpp:903.

	Delete this plugin and its line in plugins-zplague.ini once the question
	is answered - Task 4 does that.
*/

#include <amxmodx>
#include <reapi>

new g_pHold

public plugin_init()
{
	register_plugin("[TEST] ReAPI probe", "1.0", "setup")

	// 1 = write "f" from inside the hook, 0 = write "0". The control run and
	// the real test are the same code path with this flipped.
	g_pHold = register_cvar("probe_hold", "0")

	new ret = RegisterHookChain(RG_CSGameRules_CheckWinConditions, "Probe_Pre", false)

	log_amx("[PROBE] RegisterHookChain(CheckWinConditions, pre) returned %d", ret)
}

public Probe_Pre()
{
	new bool:bHold = (get_pcvar_num(g_pHold) != 0)

	set_cvar_string("mp_round_infinite", bHold ? "f" : "0")

	log_amx("[PROBE] CheckWinConditions pre-hook fired, wrote mp_round_infinite=%s",
		bHold ? "f" : "0")
}
```

- [ ] **Step 9: Compile the probe**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
Set-Location $s
& ".\amxxpc.exe" "test_reapi_probe.sma" -o"test_reapi_probe.amxx"
```

Expected: `Done.` with no errors. An "unknown symbol" error on `RegisterHookChain` or the enum name means Step 7 read the wrong names, or the include did not install — go back, do not work around it.

- [ ] **Step 10: Install the probe and take `zp_round_rules` out of the way**

Both write `mp_round_infinite`; with both loaded the test measures nothing.

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
$p = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\plugins"
Copy-Item "$s\test_reapi_probe.amxx" "$p\test_reapi_probe.amxx"
```

In `<CS>/addons/amxmodx/configs/plugins-zplague.ini`, comment out line 51 and add the probe below it:

```
; zp_round_rules.amxx   ; DISABLED for the Task 1 ReAPI probe, re-enable at Step 11
; TEST ONLY 2026-08-11 - ReAPI risk gate, delete this line and the plugin in Task 4
test_reapi_probe.amxx
```

- [ ] **Step 11: Control run — confirm the test can detect a round ending**

Restart the map. In the console:

```
probe_hold 0
```

Play until one zombie is left and kill it with a gun.

Expected: `[PROBE] CheckWinConditions pre-hook fired, wrote mp_round_infinite=0` in the log, and **the round ends** with a human win.

Without this run, a passing Step 12 could just mean the round was never going to end.

- [ ] **Step 12: The real test**

```
probe_hold 1
```

Play until one zombie is left and kill it with a gun.

Expected: `[PROBE] CheckWinConditions pre-hook fired, wrote mp_round_infinite=f` in the log, and **the round does NOT end** — play continues with no zombies alive until the clock runs out.

This is the whole plan in one observation. It proves the hook registers, fires on the death path, and fires early enough that its write is what ReGameDLL reads.

**If the round ends anyway:** the hook is too late or not firing. Stop. Remove `reapi_amxx.dll` and its `modules.ini` line, restore `modules.ini.bak-reapi`, re-enable `zp_round_rules.amxx`, and switch to the no-dependency design recorded under "Rejected alternative" in the design doc. Do not try to make it work.

- [ ] **Step 13: Restore `zp_round_rules` and record the result**

In `plugins-zplague.ini`, uncomment `zp_round_rules.amxx` and comment the probe back out — both write `mp_round_infinite`, so they must never be loaded together. Keep the probe's line rather than deleting it, so Task 4 has something to find:

```
zp_round_rules.amxx

; TEST ONLY 2026-08-11 - ReAPI risk gate, answered its question, delete in Task 4
; test_reapi_probe.amxx
```

In `docs/2026-08-11-zp-gate-restructure-design.md`, under "Risk gate", append the outcome of Steps 11 and 12 with the date and the quoted log lines.

- [ ] **Step 14: Commit**

```powershell
$r = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike"
git -C $r add addons/amxmodx/configs/modules.ini addons/amxmodx/configs/plugins-zplague.ini addons/amxmodx/scripting/test_reapi_probe.sma addons/amxmodx/scripting/include docs/2026-08-11-zp-gate-restructure-design.md
git -C $r status --short
```

Check the status output before committing: `reapi_amxx.dll` should **not** appear (binaries under `addons/` are ignored). The `.inc` files should.

```powershell
git -C $r commit -m "Prove ReAPI can hook CheckWinConditions on this build"
```

**Rollback:** delete `<CS>/addons/amxmodx/modules/reapi_amxx.dll`, restore `modules.ini.bak-reapi`, remove the probe from `plugins-zplague.ini`.

---

### Task 2: Collapse the gate to one ReAPI-hooked site

The restructure itself. After this, `mp_round_infinite` is written in one place that runs immediately before it is read.

**Files:**
- Modify: `<CS>/addons/amxmodx/scripting/zp_round_rules.sma`
- Modify: `<CS>/addons/amxmodx/configs/zombieplague.cfg` (comment block only)

**Interfaces:**
- Consumes: Task 1's confirmed symbol names — `RG_CSGameRules_CheckWinConditions` (confirmed against `reapi_gamedll_const.inc:1202`; **not** the `RG_CHalfLifeMultiplay_…` form this plan first guessed) and the `reapi` include.
- Produces: `bool:WillCountAsZombie(id)`, `bool:WillCountAsHuman(id)`, `public Gate_Pre()`, `ScheduleRespawn(victim)`, and the global `g_iDyingVictim`. Task 3 modifies `Task_Respawn`, which relies on none of these directly but must not reintroduce a gate write.

- [ ] **Step 1: Add the include**

In `zp_round_rules.sma`, after the existing includes at lines 65–68:

```pawn
#include <reapi>
```

- [ ] **Step 2: Add the in-flight victim global**

Immediately after the `g_pRoundInfinite` declaration and its comment block (around line 143):

```pawn
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
```

- [ ] **Step 3: Register the hook**

In `plugin_init`, immediately after the `g_pRoundInfinite` lookup and its `if (!g_pRoundInfinite)` warning (currently lines 184–187):

```pawn
	/*
		The gate is computed here and nowhere else. CheckWinConditions reads
		mp_round_infinite at multiplay_gamerules.cpp:903, a few lines into its
		own body, so a pre-hook write lands in the same call with nothing able
		to run in between. That is what stops the cvar from being state that
		has to be right at every instant.
	*/
	RegisterHookChain(RG_CSGameRules_CheckWinConditions, "Gate_Pre", false)
```

- [ ] **Step 4: Replace the counter and the old gate with the predicate**

Delete `CountZombiesThatCanReturn()` and `UpdateRoundEndGate()` entirely — currently lines 279–369, from the `/*` above `CountZombiesThatCanReturn` through the closing brace of `UpdateRoundEndGate`. Put this in their place:

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
	return task_exists(id + TASK_RESPAWN)
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
```

The `else if` is deliberate: a player is counted on at most one side, so double-counting is structurally impossible rather than merely avoided. That is what retires the Low finding.

- [ ] **Step 5: Record the dying victim**

Replace `Fw_Killed_Pre` (currently lines 388–394) with:

```pawn
public Fw_Killed_Pre(victim, attacker, shouldgib)
{
	if (1 <= victim <= 32)
	{
		g_bWasZombie[victim] = (zp_get_user_zombie(victim) != 0)
		g_iDyingVictim = victim
	}

	return HAM_IGNORED
}
```

- [ ] **Step 6: Split `Fw_Killed_Post` so it has exactly one exit**

`Fw_Killed_Post` currently has four `return HAM_IGNORED` statements. A missed clear of `g_iDyingVictim` on any one of them latches the gate — the same shape as the `free_tr2()` bug this server has already paid for. Make the single exit structural, not something to remember.

Replace the whole of `Fw_Killed_Post` (currently lines 396–451) with:

```pawn
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
		zp_respawn_user() straight from this post hook instead of scheduling a
		task - the one respawn on this server that left no TASK_RESPAWN behind
		it, and so the one WillCountAsZombie()'s task_exists() term could not
		see. Everything goes through a task now, so the predicate has exactly
		one thing to look for. AMXX clamps set_task below 0.1 anyway, so this
		floor only makes the existing clamp visible.
	*/
	if (delay < 0.1)
		delay = 0.1

	if (get_pcvar_num(g_pDebug))
		log_amx("[RULES] killed_post victim=%d permadead=0 -> respawn in %.2fs", victim, delay)

	set_task(delay, "Task_Respawn", victim + TASK_RESPAWN)
}
```

- [ ] **Step 7: Remove the two gate calls from `Task_Respawn`**

In the skip path (currently lines 465–476), delete the comment block about AMXX freeing one-shot tasks and the `UpdateRoundEndGate()` call, keeping `remove_task(taskid)`:

```pawn
		/*
			AMXX only frees a one-shot task after its callback returns, so
			task_exists(taskid) would still match THIS invocation until this
			function is done. Remove it explicitly - WillCountAsZombie() reads
			that task, and the next win check must not see one for a player
			who is not coming back.
		*/
		remove_task(taskid)
		return
```

At the end of the function (currently line 521), delete the `UpdateRoundEndGate()` call outright. Task 3 puts something else there.

- [ ] **Step 8: Remove the gate call and the compensation term from `Event_DeathMsg`**

Delete the entire comment block and the two statements at the end of `Event_DeathMsg` — currently lines 610–660, from the `/*` beginning "Recompute the gate here" through `UpdateRoundEndGate(bWillReturn ? 1 : 0)`.

Replace with nothing. The function now ends after the `if (get_pcvar_num(g_pKillSound))` block's closing brace.

That comment block is the single largest piece of reasoning being retired: it existed only to describe a correction that no longer has to be made.

- [ ] **Step 9: Remove the gate call from `client_disconnected`**

Replace the tail of `client_disconnected` (currently lines 224–230) with:

```pawn
	/*
		ReGameDLL calls CheckWinConditions itself from ClientDisconnected
		(multiplay_gamerules.cpp:3686), so Gate_Pre runs for this disconnect
		without being asked. Removing the task above is what makes it read
		correctly - and WillCountAsZombie() checks is_user_connected() first
		anyway, so the answer is right whichever side of that call this
		forward happens to fire on.
	*/
	remove_task(id + TASK_RESPAWN)
```

- [ ] **Step 10: Remove the forced `"f"` from `Event_NewRound` and reset the new global**

Replace the tail of `Event_NewRound` (currently lines 245–249) with:

```pawn
	/*
		No forced "f" here any more. There is no window in which a stale value
		gets read: every win check computes its own, including one that lands
		inside the ~24s window before ZP has picked this round's zombies.

		g_iDyingVictim is reset as a round-boundary net. Fw_Killed_Post's
		single exit is what actually keeps it honest.
	*/
	g_iDyingVictim = 0
```

- [ ] **Step 11: Update the plugin's header comment**

In the header block, replace the paragraph beginning "What makes that safe is `g_pRoundInfinite`" (currently lines 36–39) with:

```
	    What makes that safe is g_pRoundInfinite. Gate_Pre() is a ReAPI
	    pre-hook on CheckWinConditions: it answers "can anyone still come
	    back" at the instant CS asks, a few lines before ReGameDLL reads the
	    cvar. The flag is never state that has to be right in between,
	    because nothing reads it in between.
```

And in the `g_pRoundInfinite` comment block, replace the sentence "Hold it while any zombie can still return, release it when none can" with:

```
	Compute it at the moment CS asks and it is right by construction - hold
	while any zombie can still return, release when none can.
```

- [ ] **Step 12: Compile**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
Set-Location $s
& ".\amxxpc.exe" "zp_round_rules.sma" -o"zp_round_rules.amxx"
```

Expected: `Done.` with no errors. Warnings other than `loose indentation` mean stop and fix. In particular:
- an unused-symbol warning for `zp_get_zombie_count` / `zp_get_human_count` means Step 4 left a caller behind
- "symbol never used: `UpdateRoundEndGate`" means a call site was missed in Steps 7–10

- [ ] **Step 13: Install**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
$p = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\plugins"
Copy-Item "$p\zp_round_rules.amxx" "$p\zp_round_rules.amxx.prev"
Copy-Item "$s\zp_round_rules.amxx" "$p\zp_round_rules.amxx"
```

- [ ] **Step 14: Update the config comments**

In `<CS>/addons/amxmodx/configs/zombieplague.cfg`:

Line 322–323 still describe the old behaviour. Replace:

```
// --- headshot permadeath (added by setup) ---
zp_rules_permadeath 1            // 1 = a zombie killed by headshot does not respawn this round
```

with:

```
// --- melee permadeath (added by setup) ---
zp_rules_permadeath 1            // 1 = a zombie killed by MELEE does not respawn this round; headshots come back
```

Then in the `mp_round_infinite` block at lines 333–339, insert after the first sentence:

```
// The value is computed fresh every time CS asks - zp_round_rules hooks
// CheckWinConditions through ReAPI - so reading this cvar between rounds
// tells you nothing useful about the rule.
```

- [ ] **Step 15: Verify in game**

Restart the map. Run every case and **quote the log line**. The gate line's format is now:

```
[RULES] gate zombies=<n> humans=<n> dying=<id> -> mp_round_infinite=<f|0>
```

| # | Case | Expected |
|---|---|---|
| 1 | Gun-kill the last zombie | round continues, respawn lands after 1s. Gate line at the death shows `zombies=1 dying=<victim> -> f` |
| 2 | Melee the last zombie | round ends, Human Victory. Gate line shows `zombies=0 ... -> 0` |
| 3 | Zombies wipe the humans | Zombie Victory. Gate line shows `humans=0 -> 0` |
| 4 | Clock expires, humans alive | Human Victory (`"f"` does not block the time check — that is a different flag) |
| 6 | While **alive**, type `chooseteam` and switch team mid-round | a gate line appears for that team change, and no round ends wrongly |
| 7 | Die inside the ~24s window before ZP picks this round's zombies | the round does **not** end. Gate line shows `dying=<victim>` and `-> f` |

Case 5 belongs to Task 3.

Case 7 is the NEW-1 Critical scenario from fix round 2 — a bug that was real. To reach it: let a round end, then during the next round's pre-zombie countdown, kill yourself (`kill` in the console) or take fall damage.

Case 6 is what `ChangePlayerTeam` at `:5199` covers, and it is the one that only fires for a **live** player — `:5160` returns early for a dead one.

- [ ] **Step 16: Commit**

```powershell
$r = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike"
git -C $r add addons/amxmodx/scripting/zp_round_rules.sma addons/amxmodx/configs/zombieplague.cfg
git -C $r commit -m "Collapse the round-end gate to one ReAPI-hooked site"
```

**Rollback:** restore `zp_round_rules.amxx.prev`, or `git checkout 91e34b3 -- addons/amxmodx/scripting/zp_round_rules.sma` and rebuild.

---

### Task 3: Handle a refused respawn, and stop the round hanging to the clock

`Task_Respawn` is the one moment where "no zombie can return" becomes true with no `CheckWinConditions()` coming. With ReAPI the plugin can ask for one.

**Files:**
- Modify: `<CS>/addons/amxmodx/scripting/zp_round_rules.sma` (`Task_Respawn` only)

**Interfaces:**
- Consumes: `rg_check_win_conditions()` (name confirmed in Task 1 Step 7), and `Gate_Pre()` from Task 2, which is what makes the triggered check read a correct value.
- Produces: nothing further depends on this.

- [ ] **Step 1: Branch on the respawn's return value**

`zp_respawn_user(id, team)` returns true on success and false otherwise (`zombieplague.inc:306-312`). Its result is currently discarded, so a refused respawn still clears the scoreboard skull for a player who is still dead and plays the zombie-arrival sound for nobody.

Replace the tail of `Task_Respawn` — the three statements at the end of the function, `zp_respawn_user(...)`, `ClearScoreboardDeath(id)` and `PlayRespawnSound()` — with:

```pawn
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
```

- [ ] **Step 2: Ask CS to re-decide**

Immediately below, as the last statement in `Task_Respawn`:

```pawn
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
```

`remove_task(taskid)` goes outside the success/failure branches, immediately before the check. On the success path it is redundant — `zp_respawn_user()` spawns the player synchronously, so `WillCountAsZombie()` short-circuits on `is_user_alive()` and never reaches the `task_exists()` term — but putting it on one path only means the next reader has to re-derive which path needs it. Unconditional is one fact instead of two.

- [ ] **Step 3: Compile**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
Set-Location $s
& ".\amxxpc.exe" "zp_round_rules.sma" -o"zp_round_rules.amxx"
```

Expected: `Done.` with no errors.

- [ ] **Step 4: Install**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
$p = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\plugins"
Copy-Item "$p\zp_round_rules.amxx" "$p\zp_round_rules.amxx.prev"
Copy-Item "$s\zp_round_rules.amxx" "$p\zp_round_rules.amxx"
```

- [ ] **Step 5: Verify case 5**

This case is awkward to stage: you have to be the last zombie, die, and reach the spectate menu before the respawn task fires. Buy time first:

```
zp_rules_respawn_delay 8
```

Restart the map. Become the last zombie, get killed by a gun, then immediately `chooseteam` → Spectator before the 8 seconds are up.

Expected, in order:

```
[RULES] killed_post victim=<id> permadead=0 -> respawn in 8.00s
[RULES] respawn_task victim=<id> REFUSED by zp - staying dead this round
[RULES] gate zombies=0 humans=<n> dying=0 -> mp_round_infinite=0
```

and **the round ends** with a human win, rather than running to the clock.

Also confirm the negative: no zombie-arrival sound plays, and the scoreboard still shows you dead.

Then put the delay back:

```
zp_rules_respawn_delay 1.0
```

- [ ] **Step 6: Re-run case 1 as a regression check**

`rg_check_win_conditions()` now fires on every successful respawn too, which is the common path. Gun-kill the last zombie and confirm the round still does not end and the respawn still lands — the triggered check must read `-> f` and decline to end anything.

Expected: `[RULES] gate zombies=1 humans=<n> dying=0 -> mp_round_infinite=f` from the triggered check, and play continues.

- [ ] **Step 7: Commit**

```powershell
$r = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike"
git -C $r add addons/amxmodx/scripting/zp_round_rules.sma
git -C $r commit -m "Act on a refused respawn, and ask CS to re-decide the round"
```

**Rollback:** restore `zp_round_rules.amxx.prev` — that is the Task 2 build, which is a working state.

---

### Task 4: Record it and clean up

Nothing behavioural. Do not start this until Tasks 2 and 3 have both passed in game.

**Files:**
- Delete: `<CS>/addons/amxmodx/scripting/test_reapi_probe.sma`, `<CS>/addons/amxmodx/scripting/test_reapi_probe.amxx`, `<CS>/addons/amxmodx/plugins/test_reapi_probe.amxx`
- Modify: `<CS>/addons/amxmodx/configs/plugins-zplague.ini`
- Modify: `<CS>/docs/2026-08-11-zp-gate-restructure-design.md`
- Rewrite: `<CS>/docs/2026-08-11-handoff.md`
- Modify: `C:\Users\USER\.claude\projects\C--Users-USER\memory\cs16-zombie-plague-server.md`
- Restore: `<CS>/addons/yapb/conf/yapb.cfg`, `<CS>/listenserver.cfg`

- [ ] **Step 1: Delete the probe**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
$p = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\plugins"
Remove-Item "$s\test_reapi_probe.sma","$s\test_reapi_probe.amxx","$p\test_reapi_probe.amxx" -ErrorAction SilentlyContinue
```

Then remove its two commented lines from `plugins-zplague.ini`.

While in that file, fix the now-stale comment above `addon_floating_damage.amxx`. It reads *"Compiled locally with the reapi include commented out, since there is no reapi module installed."* The second half stopped being true in Task 1. Replace that clause with: *"since there was no reapi module installed at the time. There is one now — see modules.ini — but this plugin is still running the build that has it compiled out, deliberately. Rebuilding it with the reapi path enabled is a separate change with its own verification."*

- [ ] **Step 2: Confirm nothing still references it**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx"
Select-String -Path "$s\scripting\*.sma","$s\configs\*.ini" -Pattern "test_reapi_probe" -SimpleMatch
```

Expected: no output.

- [ ] **Step 3: Mark the design doc built**

In `docs/2026-08-11-zp-gate-restructure-design.md`, change the status line from `approved 2026-08-11, not yet built` to `built <date>`, and note the ReAPI version that was installed.

- [ ] **Step 4: Rewrite the handoff**

Rewrite `docs/2026-08-11-handoff.md` so it describes the state after this plan rather than before it. It must carry:

- the branch, the commits, and which commit is the last verified-in-game one
- ReAPI as a stack component: version, that it is required for `zp_round_rules` to compile and run, and that removing it breaks the plugin rather than degrading it
- the seven verification cases and their results
- what is still open: Task 4 of the original plan (the Orpheu cleanup), Plan Step 10 (deleting `zp_headshot_permadeath`), the intermittent winner text
- that `addon_floating_damage` has a reapi code path compiled out and is deliberately left that way

- [ ] **Step 5: Update the durable server memory**

In `C:\Users\USER\.claude\projects\C--Users-USER\memory\cs16-zombie-plague-server.md`:

- add ReAPI to the stack line, with the note that it lives under `addons/` and so survives Steam's file verification, unlike `mp.dll` and `delta.lst`
- add the gotcha this work established: `CheckWinConditions` is hookable through ReAPI because it is declared `__API_HOOK` at `multiplay_gamerules.cpp:884`, while `TeamExterminationCheck` at `:1396` is not — and `ChangePlayerTeam` returns early at `:5160` for a dead player, so a dead player joining spectators never triggers a win check at all
- the existing entry about `CheckWinConditions()` having three callers stays; it is still true and still the reason the design works

- [ ] **Step 6: Restore the test settings**

Both have `.bak` files beside them and neither is tracked by git. The hard bots were needed to make the zombie-win case reachable; the short round time to make the clock case quick.

```powershell
$cs = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike"
Copy-Item "$cs\addons\yapb\conf\yapb.cfg.bak" "$cs\addons\yapb\conf\yapb.cfg"
Copy-Item "$cs\listenserver.cfg.bak" "$cs\listenserver.cfg"
```

Restart and confirm `yb_difficulty` and `mp_roundtime` read their normal values.

- [ ] **Step 7: Commit**

```powershell
$r = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike"
git -C $r add -A
git -C $r status --short
```

Check the status output before committing — `reapi_amxx.dll` must not appear, and neither should `yapb.cfg` or `listenserver.cfg`.

```powershell
git -C $r commit -m "Remove the ReAPI probe and record the restructure"
```

---

## Not in this plan

- **Task 4 of `2026-08-10-zp-round-rules-plan.md`** — deleting the Orpheu probe and its five `orpheu*.inc` files. Independent, nothing depends on it, still pending. Note that it is now more clearly correct to delete: ReAPI does what Orpheu was being evaluated for.
- **Plan Step 10 of that plan** — deleting `zp_headshot_permadeath.sma` and its `.amxx`. Keep them until this work has run for a while.
- **The intermittent winner text.** ZP's announcement layer, not the gate.
- **Recompiling `addon_floating_damage.amxx` with its reapi path enabled.** Now possible, deliberately not done here.
- **Extra-item price balance, and FastDL** for the ~30 MB of client files that opening the server to real players would need.

---

## Self-Review

**Spec coverage.** Every section of the design doc maps to a task. The ReAPI dependency and its risk gate are Task 1. The architecture, the predicate, the in-flight victim, the single-exit `Fw_Killed_Post` and all eight site removals are Task 2 Steps 1–11. Closing "the round can only end on the clock", and the previously unreported scoreboard/sound defect, are Task 3. The verification table's seven cases are split: 1, 2, 3, 4, 6 and 7 in Task 2 Step 15, and 5 in Task 3 Step 5 with 1 re-run as a regression in Step 6. Rollback appears per task. The design doc's "Rejected alternative" is the documented fallback at Task 1 Step 12. "Out of scope" maps to "Not in this plan".

**Placeholder scan.** No TBD or TODO. Every code step carries its code, every console step its exact command, every verification its exact expected string. The two ReAPI symbol names are the one place the plan does not assert a value — that is deliberate and has its own step (Task 1 Step 7) rather than being left vague.

**Type consistency.** `WillCountAsZombie(id)` and `WillCountAsHuman(id)` are defined in Task 2 Step 4 and called in Step 4's own `Gate_Pre()`; `Gate_Pre` is the callback name registered in Step 3. `ScheduleRespawn(victim)` is defined and called in Step 6. `g_iDyingVictim` is declared in Step 2, written in Steps 5, 6 and 10, and read in Step 4. `rg_check_win_conditions()` appears only in Task 3, after Task 1 Step 7 confirms it. `TASK_RESPAWN`, `g_pRespawn`, `g_pDebug`, `g_bPermaDead`, `g_bWasZombie`, `g_iMakeZombieRetries`, `ClearScoreboardDeath` and `PlayRespawnSound` all already exist in the Task 2 input and keep their names.

**One risk the plan cannot remove.** Task 1 is a gate, not a formality. Everything after it assumes ReAPI loads and that a pre-hook write reaches `:903`. If Task 1 Step 12 ends the round, this plan is void and the design's recorded no-dependency alternative is what gets built instead.
