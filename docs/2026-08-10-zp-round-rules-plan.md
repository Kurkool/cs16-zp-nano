# ZP Round Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the mode own its round-end rule, so the last zombie can die like any other and the workaround that heals and teleports it can be deleted.

**Architecture:** ReGameDLL's `mp_round_infinite "f"` blocks CS's team-extermination round-end check. The rules plugin sets that flag at round start and clears it once no zombie can return, so CS's own check becomes correct instead of something to dodge. `zp_headshot_permadeath` is rewritten as `zp_round_rules` with the rescue path removed.

**Tech Stack:** AMX Mod X 1.10.0.5479, Metamod-r 1.3.0.149, Zombie Plague 4.3 Fix6a, ReGameDLL_CS 5.30.0.814, CS 1.6 build 10210 (HL25), Windows listen server.

**Design doc:** `C:\Users\USER\Desktop\2026-08-10-zp-round-rules-design.md`

## Global Constraints

- **Git is live.** `cstrike` is the repository root, remote `https://github.com/Kurkool/cs16-zp-nano`, branch `master`. Every task ends with a real commit. Only sources, includes, configs and the language file are tracked — `.amxx`, `.prev`, `.bak` and `.orig` are ignored, so still keep `<name>.amxx.prev` beside every installed plugin as the runtime rollback.
- **The repository is public and `users.ini` / `sql.cfg` are excluded.** Do not un-ignore them; they are where an admin or database password would land.
- **No test framework exists for AMXX here.** Verification is a named in-game case plus a specific log line. Never claim a task passes without the log line quoted.
- **Never recompile `zombie_plague40.amxx`.** Its shipped `.sma` does not match the running `.amxx`; rebuilding it would silently drop features. ZP is changed through config only.
- **Compiler:** `D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting\amxxpc.exe`
- **Plugin list:** `configs/plugins-zplague.ini` — this is the file this server loads custom plugins from, not `plugins.ini`.
- **Melee is marked `DMG_CLUB`.** Never test `DMG_NEVERGIB`; CS bullets set it too (`bits=4098` for a bullet against `bits=4224` for a stab).
- Server root below is `D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike`, written as `<CS>`.

---

## File Structure

| File | Responsibility |
|---|---|
| `<CS>/addons/amxmodx/scripting/zp_round_rules.sma` | new — every round rule in one place: melee permadeath, delayed respawn, the round-end gate, kill and respawn cues |
| `<CS>/addons/amxmodx/scripting/zp_headshot_permadeath.sma` | deleted at the end of Task 3 |
| `<CS>/addons/amxmodx/configs/plugins-zplague.ini` | swap the plugin name, drop the dead Orpheu probe line, drop the stale load-order comment |
| `<CS>/addons/amxmodx/configs/zombieplague.cfg` | rename the cvars, document `mp_round_infinite` |
| `<CS>/addons/amxmodx/scripting/zp_extra_angelic_beast.sma` | header comment only — the load-order rule it documents no longer exists |

---

### Task 1: Prove `mp_round_infinite "f"` blocks the extermination check — PASSED 2026-08-10

Result: the control run ended the round on a gun kill of the last zombie; with
`"f"` set, every zombie died and play carried on in the same round. Tasks 2–4
are cleared to proceed.

No code. The entire plan rests on this cvar behaving as documented on build 10210, and it has never been switched on. If it does not work, stop and revise the design rather than continuing.

**Files:** none.

**Interfaces:**
- Consumes: nothing.
- Produces: a yes/no answer that gates Tasks 2–4.

- [ ] **Step 1: Confirm the cvar exists**

In the game console:

```
mp_round_infinite
```

Expected: it prints a current value of `"0"`. If instead it says `Unknown command`, ReGameDLL is not loaded — check that `<CS>/dlls/mp.dll` is 1,953,280 bytes and not the 1,131,368-byte Valve one, and stop here.

- [ ] **Step 2: Take the rescue path out of the way**

The current plugin stops the last zombie from ever dying, which would mask the result. Disable its respawn takeover for the duration of this test:

```
zp_endless_respawn 0
```

With this off, `Fw_TakeDamage_Pre` returns immediately and the last zombie dies for real.

- [ ] **Step 3: Control run — confirm CS still ends the round normally**

```
mp_round_infinite 0
```

Play until one zombie is left, kill it with a gun.
Expected: the round ends immediately, humans win.

This proves the test setup can detect a round ending. Without it, a passing result in Step 4 could just mean the round was never going to end anyway.

- [ ] **Step 4: The real test**

```
mp_round_infinite f
```

Play until one zombie is left, kill it with a gun.
Expected: the zombie dies, **the round does not end**, and play continues with no zombies alive until the clock runs out.

- [ ] **Step 5: Restore the server**

```
mp_round_infinite 0
zp_endless_respawn 1
```

- [ ] **Step 6: Record the result**

Write the outcome of Steps 3 and 4 into the design doc under Risks. If Step 4 ended the round, **stop** — the mechanism does not work on this build and Tasks 2–4 are invalid.

---

### Task 2: Rename to `zp_round_rules` with behaviour unchanged

A pure rename and cvar rename. The rescue path stays for now. Doing this separately means that if something breaks in Task 3, it is not the rename.

**Files:**
- Create: `<CS>/addons/amxmodx/scripting/zp_round_rules.sma`
- Modify: `<CS>/addons/amxmodx/configs/plugins-zplague.ini`
- Modify: `<CS>/addons/amxmodx/configs/zombieplague.cfg`

**Interfaces:**
- Consumes: Task 1's confirmation.
- Produces: a plugin named `zp_round_rules.amxx` registering these cvars, which Task 3 extends:
  `zp_rules_permadeath`, `zp_rules_announce`, `zp_rules_kill_sound`, `zp_rules_respawn`, `zp_rules_respawn_delay`, `zp_rules_respawn_sound`, `zp_rules_debug`.

- [ ] **Step 1: Copy the source under the new name**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
Copy-Item "$s\zp_headshot_permadeath.sma" "$s\zp_round_rules.sma"
```

- [ ] **Step 2: Rename the cvars inside the new file**

Apply exactly these replacements in `zp_round_rules.sma`. Old name on the left, new on the right:

| Old | New |
|---|---|
| `zp_hs_permadeath` | `zp_rules_permadeath` |
| `zp_hs_permadeath_announce` | `zp_rules_announce` |
| `zp_kill_sound` | `zp_rules_kill_sound` |
| `zp_endless_respawn` | `zp_rules_respawn` |
| `zp_endless_respawn_delay` | `zp_rules_respawn_delay` |
| `zp_escape_kill_credit` | `zp_rules_escape_credit` |
| `zp_permadeath_debug` | `zp_rules_debug` |
| `zp_respawn_sound` | `zp_rules_respawn_sound` |

Change the plugin registration line to:

```pawn
register_plugin("[ZP] Round Rules", "2.0", "setup")
```

Change every `[PERMA]` log prefix to `[RULES]`.

- [ ] **Step 3: Update the plugin list**

In `<CS>/addons/amxmodx/configs/plugins-zplague.ini`, replace the line `zp_headshot_permadeath.amxx` with `zp_round_rules.amxx`, and delete these three lines entirely:

```
; TEST ONLY 2026-08-10 - Orpheu signature probe, delete this line and the
; plugin once the question is answered.
; test_orpheu_probe.amxx   ; DISABLED - answered its question 2026-08-10, all 7 signatures failed
```

Leave the Angelic Beast load-order comment alone for now; Task 3 removes it.

- [ ] **Step 4: Update the config file**

In `<CS>/addons/amxmodx/configs/zombieplague.cfg`, back up first, then rename the same cvars using the table from Step 2. Do not change any values.

```powershell
$c = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\configs\zombieplague.cfg"
Copy-Item $c "$c.bak-rename"
```

- [ ] **Step 5: Compile**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
Set-Location $s
& ".\amxxpc.exe" "zp_round_rules.sma" -o"zp_round_rules.amxx"
```

Expected: `Done.` with no errors. Warnings other than `loose indentation` mean stop and fix.

- [ ] **Step 6: Install, keeping the old plugin loadable**

```powershell
$p = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\plugins"
Copy-Item "$s\zp_round_rules.amxx" "$p\zp_round_rules.amxx"
```

Do not delete `zp_headshot_permadeath.amxx` yet — it is the rollback.

- [ ] **Step 7: Verify nothing changed behaviourally**

Restart the map. Run these three cases and quote the log line for each:

| Case | Expected log |
|---|---|
| Melee a zombie when others are alive | `[RULES] deathmsg ... meleeFlag=1 ... permakill=1` then `killed_post ... permadead=1 -> NO respawn` |
| Shoot a zombie when others are alive | `[RULES] killed_post ... permadead=0 -> respawn in 1.00s` then `respawn_task ... -> respawning as zombie` |
| Shoot the last zombie | `[RULES] -> LAST ZOMBIE rescued, damage cancelled, healed in place` |

All three must behave exactly as they did before the rename. The third still uses the rescue — that is expected at this stage.

**Rollback:** put `zp_headshot_permadeath.amxx` back in `plugins-zplague.ini` and restore `zombieplague.cfg.bak-rename`.

---

### Task 3: Add the round-end gate and delete the rescue

The behavioural change. After this the last zombie is not a special case.

**Files:**
- Modify: `<CS>/addons/amxmodx/scripting/zp_round_rules.sma`
- Modify: `<CS>/addons/amxmodx/configs/zombieplague.cfg`
- Modify: `<CS>/addons/amxmodx/configs/plugins-zplague.ini`
- Modify: `<CS>/addons/amxmodx/scripting/zp_extra_angelic_beast.sma` (comment only)
- Delete: `<CS>/addons/amxmodx/scripting/zp_headshot_permadeath.sma` and the matching `.amxx`

**Interfaces:**
- Consumes: `zp_round_rules.sma` from Task 2.
- Produces: nothing further depends on this.

- [ ] **Step 1: Add the gate state**

Near the other globals in `zp_round_rules.sma`:

```pawn
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
```

In `plugin_init`, after the other cvar registrations:

```pawn
	g_pRoundInfinite = get_cvar_pointer("mp_round_infinite")

	if (!g_pRoundInfinite)
		log_amx("[RULES] mp_round_infinite not found - ReGameDLL is not loaded, the round-end gate is OFF")
```

- [ ] **Step 2: Write the gate itself**

Add these two functions:

```pawn
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
```

- [ ] **Step 3: Call the gate at the three moments it can change**

In `Event_NewRound`, after the existing reset loop:

```pawn
	// a fresh round always starts held; zombies have not been picked yet, so
	// the count would read zero and open the gate at exactly the wrong time
	if (g_pRoundInfinite)
		set_pcvar_string(g_pRoundInfinite, "f")
```

At the end of `Fw_Killed_Post`, immediately before `return HAM_IGNORED`, in both the permadead branch and the respawn branch:

```pawn
	UpdateRoundEndGate()
```

At the end of `Task_Respawn`, after `PlayRespawnSound()`:

```pawn
	UpdateRoundEndGate()
```

- [ ] **Step 4: Delete the rescue**

In `Fw_TakeDamage_Pre`, remove everything after the melee cache. The whole function becomes:

```pawn
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
```

Then delete these entirely: `RespawnZombie()`, `CreditEscapeKill()`, `CollectSpawns()`, `ClearScoreboardDeath()`'s call from inside `CreditEscapeKill` (the function itself stays, it is still used by `Task_Respawn`), `g_bFakeDeath`, `g_fSpawn`, `g_iSpawns`, `MAX_SPAWNS`, the `g_pCredit` cvar and its registration, the `CollectSpawns()` call in `Event_NewRound`, and the `g_bFakeDeath` guard at the top of `Event_DeathMsg`.

- [ ] **Step 5: Compile**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
Set-Location $s
& ".\amxxpc.exe" "zp_round_rules.sma" -o"zp_round_rules.amxx"
```

Expected: `Done.` with no errors and no warnings about unused variables. An unused-symbol warning means Step 4 missed something.

- [ ] **Step 6: Install**

```powershell
$p = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\plugins"
Copy-Item "$p\zp_round_rules.amxx" "$p\zp_round_rules.amxx.prev"
Copy-Item "$s\zp_round_rules.amxx" "$p\zp_round_rules.amxx"
```

- [ ] **Step 7: Document `mp_round_infinite` in the config**

Add to `zombieplague.cfg` under the round-rules block:

```
// mp_round_infinite is driven by zp_round_rules, do not set it by hand.
// "f" blocks CS's team-extermination round end and is held while any zombie
// can still return; "0" releases it once none can.
```

- [ ] **Step 8: Correct the Angelic Beast header**

In `zp_extra_angelic_beast.sma`, the header says the plugin must load before `zp_headshot_permadeath` because that plugin's last-zombie check reads the damage value. Nothing reads damage any more. Replace that paragraph with:

```
	Load order
	    No longer constrained. zp_round_rules used to read the damage value
	    to decide whether a lethal hit was allowed to land, so anything with
	    a damage multiplier had to load first. It no longer inspects damage
	    at all.
```

Recompile and install the Angelic Beast plugin using the same commands as Step 5 and 6 with `zp_extra_angelic_beast`.

- [ ] **Step 9: Verify all five cases**

Restart the map. Quote the log line for each.

| # | Case | Expected |
|---|---|---|
| 1 | Melee a zombie, others alive | stays down; `permakill=1`, `NO respawn` |
| 2 | Shoot a zombie, others alive | back in 1s, scoreboard mark cleared; `respawn in 1.00s` |
| 3 | **Shoot the last zombie** | **it dies, the round does NOT end, it returns in 1s**; expect `gate zombiesThatCanReturn=1 -> mp_round_infinite=f` |
| 4 | Melee the last zombie | round ends, Human Victory, SodierWin plays; expect `gate zombiesThatCanReturn=0 -> mp_round_infinite=0` |
| 5 | Clock expires with humans alive | Human Victory, not "no one won" |

Case 3 is the one the whole design turns on. There must be no `LAST ZOMBIE rescued` line anywhere in the log — that string no longer exists in the source.

- [ ] **Step 10: Remove the old plugin**

Only after all five cases pass:

```powershell
Remove-Item "$s\zp_headshot_permadeath.sma"
Remove-Item "$p\zp_headshot_permadeath.amxx"
```

Keep `zp_headshot_permadeath.amxx.prev` — it is the last rollback to the pre-rewrite behaviour.

**Rollback:** restore `zp_round_rules.amxx.prev`, or put `zp_headshot_permadeath.amxx.prev` back and point `plugins-zplague.ini` at it, and set `mp_round_infinite 0`.

---

### Task 4: Clear out the Orpheu experiment and update the notes

Independent tidying. Nothing depends on it, and nothing it touches is loaded.

**Files:**
- Delete: `<CS>/addons/amxmodx/scripting/test_orpheu_probe.sma` and `.amxx`, `<CS>/addons/amxmodx/plugins/test_orpheu_probe.amxx`, `<CS>/addons/amxmodx/scripting/include/orpheu*.inc`
- Modify: `C:\Users\USER\.claude\projects\C--Users-USER\memory\cs16-zombie-plague-server.md`

- [ ] **Step 1: Delete the probe and the unused includes**

```powershell
$s = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\scripting"
$p = "D:\Program Files (x86)\Steam\steamapps\common\Half-Life\cstrike\addons\amxmodx\plugins"
Remove-Item "$s\test_orpheu_probe.sma","$s\test_orpheu_probe.amxx","$p\test_orpheu_probe.amxx" -ErrorAction SilentlyContinue
Remove-Item "$s\include\orpheu.inc","$s\include\orpheu_advanced.inc","$s\include\orpheu_const.inc","$s\include\orpheu_memory.inc","$s\include\orpheu_stocks.inc" -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Confirm nothing still references them**

```powershell
Select-String -Path "$s\*.sma" -Pattern "orpheu" -SimpleMatch
```

Expected: no output.

- [ ] **Step 3: Update the memory file**

Replace the load-order constraint line — the one saying a damage multiplier must load before `zp_headshot_permadeath` — with a note that it no longer applies and why. Add: ReGameDLL 5.30.0.814 replaces `mp.dll` and is what makes `mp_round_infinite` available, with the Valve original at `dlls/mp.dll.valve-bak`; Orpheu's shipped signatures do not resolve on build 10210 so that route is closed.

- [ ] **Step 4: Mark the design doc built**

Change the status line in `2026-08-10-zp-round-rules-design.md` from `approved` to `built`, with the date and the result of Task 1 Step 4.

---

## Self-Review

**Spec coverage.** R2, R3 and R7 are unchanged and covered by Task 2's verification. R4 is Task 3 Steps 1–4. R5 is Task 3 Step 9 case 4. R6 was already applied through config before this plan and is re-verified in Task 3 Step 9 case 5. R1 belongs to ZP and is untouched. The renaming, the deletions, and the Angelic Beast comment are Task 3 Steps 2–8. The Orpheu cleanup is Task 4.

**Placeholders.** None. Every code step carries the code, every console step the exact command, every verification the exact expected string.

**Type consistency.** `UpdateRoundEndGate()` and `CountZombiesThatCanReturn()` are defined in Task 3 Step 2 and called in Step 3 under those names. `TASK_RESPAWN` and `g_pDebug` already exist in the Task 2 output. `ClearScoreboardDeath()` is explicitly kept while its call site inside `CreditEscapeKill` is removed with that function.

**One risk the plan cannot remove.** Task 1 is a gate, not a formality. Everything after it assumes `mp_round_infinite "f"` works on build 10210, and that has never been observed. If Task 1 Step 4 ends the round, this plan is void and the design needs revisiting.
