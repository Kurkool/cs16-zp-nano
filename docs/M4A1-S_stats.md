# M4A1-S — CrossFire stat sheet vs. the ZP Angelic Beast

Extracted 2026-08-09 from **CSCF Yasou 3.0 Official — YasouGaming**.

---

## Where the numbers actually live

| | |
|---|---|
| Stat table | `game\cstrike\SUIC_SOUNDS\MAIN\AP\SUIC_WEAPON_MAIN.RC` |
| Game DLL | `game\cstrike\dlls\mp.dll` — dated 2005-02-06, **stock and unmodified** |
| Engine | AMX Mod X + Orpheu + the SUIC module (`addons\amxmodx\function\suic_*.inc` are native declarations only, not data) |

Dead ends checked: `classes\m4a1.res` is only the buy-menu VGUI layout, and there
are no `.sma` sources shipped (47 `.amxx`, 0 `.sma`).

The table holds **13 custom weapons**. Stock CS guns are untouched and use
`mp.dll` defaults.

---

## Reading the fields

Confident, read straight from the file:

| Field | Meaning |
|---|---|
| `copyWpn` | the stock CS weapon this one is built on |
| `copyDamage` | bullet damage as a multiple of that base weapon |
| `intervalTime` | `shot interval | melee cooldown`, seconds |
| `kickback_*` | recoil, one set per stance |
| `crossSize` | crosshair size, four states — the spread indicator |
| `moveSpeed` | movement speed while held |
| `deployTime` / `reloadTime` | seconds |
| `moderator` / `resetTime` | accuracy recovery |
| `specialType` | `1` = has a melee special attack |
| `range` / `length` / `damage` / `waitTime` | the melee attack's numbers |

Inferred, but it is the only reading that fits all 13 rows:

> **`ammo` is the magazine and `clip` is the reserve — the names are backwards.**
> `AP_MG` is `ammo=350 clip=2` and the 687EDP shotgun is `ammo=2 clip=50`.
> Read the other way round the shotgun would have a 50-round magazine.

`range`/`length`/`damage`/`waitTime` appear on **only** the five `specialType=1`
weapons, which are exactly the Beast/Transformer guns that have a butt-stroke in
CrossFire — hence reading them as the melee numbers.

---

## The three M4A1-S variants

There is no plain M4A1-S in this build. All three share a base and differ in
only three values.

| Field | Born Beast | **Prism Beast** | Transformer |
|---|---|---|---|
| `name` | M4A1-S.Born Beast | M4A1-S.Prism Beast | M4A1-S.Transformer |
| `copyWpn` | AK47 | AK47 | AK47 |
| `copyDamage` | 0.5 | 0.5 | 0.5 |
| `intervalTime` | 0.070 \| **0.85** | 0.070 \| **0.55** | 0.070 \| **0.85** |
| `reloadTime` | **1.75** | **1.68** | **1.68** |
| `waitTime` | **0.4** | **0.2** | **0.4** |
| `moveSpeed` | 225 | 225 | 225 |
| `deployTime` | 0.81 | 0.81 | 0.81 |
| `crossSize` | 8\|6\|4\|10 | 8\|6\|4\|10 | 8\|6\|4\|10 |
| `moderator` | 0.5 | 0.5 | 0.5 |
| `resetTime` | 0.3 | 0.3 | 0.3 |
| `ammo` (magazine) | 50 | 50 | 50 |
| `clip` (reserve) | 11 | 11 | 11 |
| `knockback` | 5 | 5 | 5 |
| `specialType` | 1 | 1 | 1 |
| `copyAnim` | rifle | rifle | rifle |
| `range` (melee) | 65.0 | 65.0 | 65.0 |
| `length` (melee) | 75.0 | 75.0 | 75.0 |
| `damage` (melee) | 523 | 523 | 523 |
| `zoom` / `fov` | 1 / 90 | 1 / 90 | 1 / 90 |
| `isHero`/`isRun`/`isBag`/`isBot` | 1 | 1 | 1 |
| `soundDir` | M4A1 | M4A1 | M4A1 |

**Prism Beast is the fast-melee variant** — 0.55 s cooldown against 0.85 s, and
half the `waitTime`. Its reload is also the joint-shortest at 1.68 s.

Derived: `0.070 s` between shots is roughly **857 RPM**, and bullet damage is
`36 × 0.5 = 18` per hit off the AK-47 base.

---

## Recoil

Identical across all three variants. The seven values line up exactly with the
CS engine's

```c
CBasePlayer::KickBack( up_base, lateral_base, up_modifier,
                       lateral_modifier, up_max, lateral_max, direction_change )
```

| Stance | up_base | lat_base | up_mod | lat_mod | **up_max** | **lat_max** | dir_change |
|---|---|---|---|---|---|---|---|
| standing (`other`) | 0.8 | 0.30 | 0.11 | 0.03 | 0.8 | 0.5 | 3 |
| ducking | 0.8 | 0.25 | 0.02 | 0.03 | 0.8 | 0.5 | 3 |
| walking | 0.8 | 0.50 | 0.50 | 0.05 | 0.8 | 0.5 | 3 |
| airborne (`soar`) | 3.5 | 0.00 | 0.50 | 0.00 | 0.3 | 0.0 | 0 |

The interesting part is the caps. Stock CS M4A1 runs `up_max` around 3.5 and
`lateral_max` around 2.5; this gun keeps the per-shot kick roughly normal and
instead **clamps the accumulation to 0.8 / 0.5**. That is why it stays planted
through a long burst rather than feeling weak on the first shot.

Airborne is the opposite — a big 3.5 first kick with a hard 0.3 ceiling.

---

## Against the ZP Angelic Beast

`addons/amxmodx/scripting/zp_extra_angelic_beast.sma` on the Zombie Plague server.

| | CrossFire Prism Beast | Angelic Beast | |
|---|---|---|---|
| Base weapon | AK47 (`copyWpn`) | M4A1 | not changed — see below |
| Bullet damage | ×0.5 of AK47 ≈ 18 | ×2.5 of M4A1 (`zp_angelic_dmg`) | left alone |
| **Shot interval** | **0.070 s (~857 RPM)** | **0.070 s** (`zp_angelic_interval`) | **matched** |
| **Deploy time** | **0.81 s** | **0.81 s** (`zp_angelic_deploy_time`) | **matched** |
| **Recoil** | **capped at 0.8 / 0.5** | **same KickBack table** (`zp_angelic_recoil_mode 1`) | **matched** |
| Magazine | 50 | 52 (`zp_angelic_clip`) | left alone |
| Reserve | 11 | 156 (`zp_angelic_ammo`) | left alone |
| Melee range | 65.0 units (~1.65 m) | 137.8 units (3.5 m) | kept, deliberate buff |
| Melee damage | 523 | 1000 sent → 750 landed | left alone |
| Melee cooldown | 0.55 s | 0.85 s | left alone |
| Reload | 1.68 s | 2.1 s | left alone |
| Move speed | 225 flat | 240 base, ×1.30 while awakened | left alone |

Handling was matched on 2026-08-09; the power numbers were deliberately left
where they were.

Two values match the source exactly and were clearly taken from it: the original
`STAB_RANGE 64.0` against `range 65.0`, and `STAB_DELAY 0.85` against Born
Beast's melee cooldown. The 3.5 m reach is a deliberate buff over the original.

### Why the numbers cannot simply be copied across

**ZP applies `zp_zombie_armor 0.75` to every point of damage a human deals to a
normal zombie**, before the weapon plugin's own hook sees it. A number written
into the plugin lands at 75% of its value. CrossFire has no such multiplier, so
matching a "523 melee" means sending `523 / 0.75 = 697.33`.

The order catches people out, because it is the opposite of what the cvar name
suggests. ZP loads first, so its `Ham_TakeDamage` hook runs first and the armor
cut is already applied by the time `zp_angelic_dmg` multiplies. For bullets the
chain is

```
33 (M4A1 base)  ->  x0.75 armor  =  24.75  ->  x zp_angelic_dmg
```

so the current `2.5` lands **61.875 per body shot**. Headshots arrive already
multiplied by four, since hitgroup scaling happens back in `TraceAttack`.
To land a chosen number `N` per body shot, set `zp_angelic_dmg = N / 24.75`.

**The bullet damage does not transfer at all.** CrossFire balances against
~100 HP players; ZP zombies on this server run 1000–3600 HP. Literally applying
`copyDamage 0.5` gives 18 per bullet, 13.5 after zombie armor — roughly 250
bullets to drop one zombie. The gun would be unusable.

---

## Mapping to the plugin

### Done — the handling set

| Prism Beast field | How |
|---|---|
| `kickback_*` | `KICKBACK[4][7]` in the plugin, a transcription of `CBasePlayer::KickBack` fed from CrossFire's table. `zp_angelic_recoil_mode 1` selects it; `0` restores the old ×0.15 punch scaling so the two can be compared without a recompile. |
| `intervalTime 0.070` | `zp_angelic_interval`, written into the weapon's `m_flNextPrimaryAttack` and the player's `m_flNextAttack` after each shot |
| `deployTime 0.81` | `zp_angelic_deploy_time`, applied in the deploy hook |

The burst counter is tracked inside the plugin rather than read from the
engine's `m_iShotsFired`: the two pdata tables available on this machine
disagree about where that member lives (`m_flAccuracy` is 71 in the working
plugins but 62 in the floating-damage include), and the model does not need the
engine's copy. It costs nothing here — `up_base` already equals `up_max`, so
the vertical kick is pinned from the first round regardless of the count.

### Deliberately not applied

| Prism Beast field | Why |
|---|---|
| `copyDamage 0.5` | unusable against ZP zombie health pools — 18 per bullet, 13.5 after armor |
| `ammo 50` / `clip 11` | power, held back for a later pass; 11 reserve rounds is very thin for ZP |
| `damage 523` | would be `zp_angelic_stab_dmg 697.33` to land 523 after zombie armor |
| `range 65.0` | the 3.5 m reach is a deliberate buff and was kept |
| melee cooldown `0.55` | `STAB_DELAY` is still a `#define` at 0.85 |
| `reloadTime 1.68` | `v_angelic.mdl` had its reload sequences re-timed to 76.2 fps to fit 2.1 s; shortening this cuts the animation off unless the model is re-timed again |
| `moveSpeed 225` | conflicts with the awakened speed boost, which is the gun's signature |

### On `copyWpn = AK47`

The ZP plugin is still built on `weapon_m4a1` and was not moved. Now that
recoil, rate of fire, accuracy and deploy time are all set explicitly, the base
weapon contributes almost nothing to how the gun handles. What still comes from
it is base bullet damage — 33 for the M4A1 against the AK-47's 36 — plus the
556 vs 762 bullet type, which changes range falloff and armour penetration
slightly. All of that sits in the power bracket that was deliberately deferred.

Moving the base would mean rewriting all seven Ham hooks and every `CSW_M4A1`,
blocking `events/ak47.sc` instead of `events/m4a1.sc`, and re-testing the clip
override against the AK-47's own 30-round refill cap. The real risk is the
stab: it hangs off `Ham_Weapon_SecondaryAttack`, which on the M4A1 is a real
function (the silencer toggle) but on the AK-47 is the empty base-class one.
The hook should still fire, but that is untested here — if it does not, the
melee attack disappears entirely.

Worth doing alongside the power pass, if at all, not before it.

### Does not map

| Field | Why |
|---|---|
| `knockback 5` | `zp_knockback 0` server-wide |
| `crossSize` | CS 1.6 crosshair size is not settable per weapon this way |
| `waitTime 0.2` | distinct from the melee cooldown; exact behaviour not established |
| `length 75.0` | plausibly the melee hull extent, not confirmed |
