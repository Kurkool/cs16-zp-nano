# Design — own the round rules instead of working around CS

Zombie Plague server, `D:\...\Half-Life\cstrike`. Written 2026-08-10.
Status: **approved 2026-08-10.** Not built yet.

Settled during review: the plugin becomes `zp_round_rules` with `zp_rules_*`
cvars, and the `sv_restartround` message quirk is accepted rather than worked
around.

---

## Why

The round rules are not written down anywhere. They live as behaviour spread
across three plugins, and the piece that stops CS from ending the round early
reads like a trick rather than a rule: a lethal non-melee hit on the last living
zombie is cancelled and the zombie is healed to full and teleported.

The goal is not new gameplay. It is to have the mode own its own rules, stated
once, without hard-coded work-arounds aimed at the engine.

---

## What the investigation established

Worth keeping, because most of it is not obvious and was expensive to find.

**ZP does not end rounds.** It calls
`register_logevent("logevent_round_end", 2, "1=Round_End")` and reacts to CS's
event. It then picks a winner by counting who is still alive. CS owns the
decision, the timer, the event and the next round. There is no contest between
ZP and anything we write — ZP is a passenger.

**The "kill them all" win already works.** Melee the last zombie, it really
dies, the team really is empty, CS ends the round, ZP counts zero zombies and
declares humans the winner. No trickery anywhere on that path.

**Surviving the clock reports the wrong winner.** With both teams still alive
ZP falls to its last branch and shows `WIN_NO_ONE`. Confirmed in game.

**Orpheu is a dead end on this build.** Orpheu 2.5.1 loads fine under AMX Mod X
1.10, but all seven round-control signatures shipped with the CSCF and ExHero
packages fail to resolve: `CheckWinConditions`, `EndRoundMessage`,
`InstallGameRules`, `UpdateTeamScores` and the three `patchRoundEndCheck`
memory structures. They were written for build 5408; this server is build
**10210, HL25**.

**ReGameDLL works here.** Version 5.30.0.814 replaces `mp.dll` and runs on this
listen server on HL25. YaPB detects it and reports a `ReGameDLL` flag. No
ReHLDS and no ReAPI needed. Existing pdata offsets still hold — the weapon
plugins and permadeath were unaffected. Installed and in use since 2026-08-10.

**ReGameDLL exposes the exact switch this design needs.** `mp_round_infinite`
takes flags, one per round-end check:

```
a round time      e bomb
b needed players  f team extermination      <-- the one that matters
c VIP             g hostage rescue
d prison escape
```

---

## The rules

| | Rule | Owner |
|---|---|---|
| R1 | Who becomes a zombie, and when | ZP |
| R2 | A zombie put down by **melee** is out for the round | this plugin |
| R3 | A zombie put down by anything else comes back after `zp_endless_respawn_delay` | this plugin |
| R4 | R3 holds even when it would leave no zombie alive | `mp_round_infinite` |
| R5 | Humans win once every zombie is out | falls out of R2 once the flag lifts |
| R6 | Humans win if the clock runs out with humans alive | config |
| R7 | Zombies win when no humans remain | ZP |

Melee means the real knife, or a custom weapon's stab. Stabs tag their damage
`DMG_NEVERGIB|DMG_CLUB`; the knife is matched on `CSW_KNIFE` because CS does not
set `DMG_CLUB` on its own stab.

> **Do not use `DMG_NEVERGIB` as the melee marker.** CS bullets carry it too —
> observed as `bits=4098` (`DMG_NEVERGIB|DMG_BULLET`) against `bits=4224`
> (`DMG_NEVERGIB|DMG_CLUB`) for a stab. Marking on `DMG_NEVERGIB` would make
> every bullet a melee hit and silently break permadeath.

**R3 and R4 are one rule, not two.** "Killed by anything but melee means you get
sent back." A zombie that is not the last one does that by dying and respawning.
Today the last zombie has to do it without dying, because CS would hand the
round to the humans the moment the team empties. That is the only reason the
mechanisms differ, and it is what makes the code read like a hack.

---

## Mechanism

```
mp_round_infinite "f"     set at round start
                          cleared once no zombie can come back
```

Read it as: *CS may end the round by extermination only once the extermination
is permanent.*

"Can come back" means alive, or dead with a respawn still pending. After every
permadeath the plugin counts both; when the count reaches zero it clears the
flag and CS's next win check — it runs one per frame — ends the round on its
own. Nothing needs to force it. The flag goes back on at the start of the next
round.

This does not fight CS's check — it makes the check correct. While a zombie is
still coming back the team is not really gone, so CS should not act; once every
zombie is permanently out it is, so CS should. Flag `a` is deliberately not set,
so the round timer keeps working and R6 still fires.

### R4 stops being a special case

The last zombie dies like any other and respawns a second later. Deleted:

- the rescue branch in `Fw_TakeDamage_Pre`
- `RespawnZombie()` — the heal-to-full and teleport
- `CreditEscapeKill()` — the faked `DeathMsg` and faked frag
- `CollectSpawns()`, `g_fSpawn`, `MAX_SPAWNS`
- `g_bFakeDeath`
- the `ClearScoreboardDeath()` call that only existed to undo the faked death

`Fw_TakeDamage_Pre` shrinks to caching whether the hit was melee. No damage
comparison, no zombie count, no supercede.

**A load-order constraint disappears with it.** The note that "any plugin with a
damage multiplier must load before `zp_headshot_permadeath`" existed because the
rescue read the damage value. Nothing reads it any more.

### R6 is configuration, not code

Under these rules ZP's no-one-wins branch is reachable only when the clock
expires with both sides alive — which is humans surviving, which is humans
winning. Both teams dead cannot happen. So the branch is not wrong logic, it is
a mislabelled outcome, and it is fixed where the label lives:

| File | Key | To | |
|---|---|---|---|
| `configs/zombieplague.ini` | `WIN NO ONE` | `nano/SodierWin.wav` | done |
| `data/lang/zombie_plague.txt` | `WIN_NO_ONE` | `Human Victory` | done |
| `data/lang/zombie_plague.txt` | `WIN_HUMAN` | `Human Victory` | done |
| `data/lang/zombie_plague.txt` | `WIN_ZOMBIE` | `Zombie Victory` | done |

Only the `[en]` block was touched, at byte level — the file holds twenty
languages in a non-UTF-8 encoding and reading it as text corrupts the accented
ones. Verified: three lines differ, nothing else. Backup at
`zombie_plague.txt.bak`.

Known cost: `sv_restartround` reaches the same branch and will also announce a
human win. Cosmetic, rare, accepted.

ZP's own `.sma` is **not** the source of its running `.amxx`, so ZP is never
recompiled. Everything above is configuration.

---

## Changes

| File | Change |
|---|---|
| `zp_round_rules.sma` | new, replaces `zp_headshot_permadeath.sma` |
| `configs/plugins-zplague.ini` | swap the plugin, drop the disabled Orpheu probe, drop the stale load-order comment |
| `configs/zombieplague.cfg` | `zp_hs_*` → `zp_rules_*`, add `mp_round_infinite` |
| `data/lang/zombie_plague.txt` | `WIN_NO_ONE` under `[en]` |
| `zp_extra_angelic_beast.sma` | header comment: the load-order rule is gone |

Renaming is included because the current name is actively wrong — the trigger
has been melee since 2026-08-09 — and the file is being rewritten anyway.

### Kept as is

Melee permadeath, the one second respawn, kill cues, the `ScoreAttrib` clear on
the real respawn path, and every sound mapping set on 2026-08-10.

---

## How it gets checked

No test framework exists for AMXX here, so this is manual, in this order. Each
one has a matching `[RULES]` log line.

1. Melee a zombie → stays down, scoreboard keeps the mark
2. Shoot a zombie → back in one second, mark cleared
3. **Shoot the last zombie → it dies for real, the round does not end, it comes back** — proves `mp_round_infinite "f"`
4. Melee the last zombie → round ends, humans win
5. Clock expires with humans alive → humans win, not "no one won"

Case 3 is the one the whole design turns on.

---

## Risks

**Steam restores `mp.dll`.** Verifying the game files or a Steam update puts
Valve's DLL back and `mp_round_infinite` stops existing, so R4 breaks and CS
ends rounds early again. Backup is `dlls/mp.dll.valve-bak`. This also applies to
the `delta.lst` edit made for the floating damage plugin.

**ReGameDLL is not the DLL this server was built against.** It has been running
since 2026-08-10 with nothing broken, but it changes movement code — the view
roll while strafing came back, which is `sv_rollangle` behaving as Half-Life
always did rather than as Valve's CS build forced it.

**`mp_round_infinite` has not been switched on yet.** Every finding above about
ReGameDLL is from running it with the cvar at its default of `0`. Case 3 is the
first real test.

## Rollback

| Undo | How |
|---|---|
| the rules plugin | put `zp_headshot_permadeath.amxx.prev` back |
| `mp_round_infinite` | set it to `0` |
| ReGameDLL | copy `dlls/mp.dll.valve-bak` over `dlls/mp.dll` |
| sounds | `configs/zombieplague.ini.bak-sounds` |

---

## Left alone on purpose

Not part of this work, listed so they are not lost: extra-item prices, FastDL,
the Angelic Beast power pass, and moving that weapon onto the AK-47 base the way
CrossFire has it.
