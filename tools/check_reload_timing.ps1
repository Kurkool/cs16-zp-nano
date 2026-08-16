# Verify that every reload sound a weapon plugin schedules lands on the frame the
# animator put it on.
#
# Why this exists: the plugins do not read the model. They schedule their reload
# sounds from fractions of zp_*_reload_time held in zombieplague.cfg, while the
# model carries the animator's own intent as studio events - id 5004, a frame
# number and a WAV name - inside each sequence. Nothing keeps the two in step, so
# a fraction can be wrong, or right for one animation and wrong for another, and
# the only symptom is a sound that feels slightly off. That is hard to judge by
# ear and easy to misattribute: the Angelic was recorded in a handoff as having
# its charging-handle animation late when in fact that one was correct and the
# other was 100ms late.
#
# The events give exact numbers, so this is checkable rather than a matter of
# taste:
#
#     event fraction = frame / numframes
#     bang time      = fraction * reload_time
#
# frame/numframes is the right denominator because it makes fraction * reload_time
# equal frame/fps exactly, whenever the model has been re-timed so that
# numframes/fps equals reload_time. That re-timing is the second thing checked
# here, because a weapon whose reload time is changed without re-timing its model
# has its animation clipped mid-motion - see zp_*_reload_time in zombieplague.cfg.
#
# Beats are matched to cvars in frame order, not by the WAV names in the events.
# The names cannot be trusted: the Iron Beast's magazine sound ships as
# ClipIn_ImperialGold.wav while its bolt-release sound ships as
# G_MZC_M4A1_CLIPIN.wav, and two of three were identified wrongly from the file
# name before the showcase video settled it.
#
# Tolerance is in milliseconds of bang time rather than fractions, since that is
# the unit the ear works in. The 60ms default sits just inside the point where a
# transient reads as out of step with the motion that should have caused it, and
# is not tighter because the Iron Beast's magin fraction deliberately carries a
# transient correction of about +0.05 - that sound peaks in its first 0.08s and
# then has a second of glass tail, so it is scheduled by its bang and not by its
# start. See the block above zp_ironbeast_frac_magin in zombieplague.cfg.

param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [int]$ToleranceMs = 60,
    [int]$WarnMs = 20
)

# Anything inside WarnMs is clean. Between WarnMs and ToleranceMs is real drift
# that is being tolerated on purpose and says so, rather than being reported as
# 'ok' - the Iron Beast's bolt beat sits 49ms out and a single pass/fail bar was
# certifying that as correct.
function Classify([double]$driftMs) {
    $d = [math]::Abs($driftMs)
    if ($d -le $WarnMs)      { return 'ok' }
    if ($d -le $ToleranceMs) { return 'drift' }
    return 'FAIL'
}

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture

# Which cvar owns which beat, in frame order, for each reload sequence.
# A cvar named twice is shared by both animations on purpose: the two Angelic
# reloads pull and seat the magazine on the same frames and only part company at
# the bolt. If a model is ever re-authored so they differ, this check fails and
# says so, which is the point.
$WEAPONS = @(
    @{
        Name     = 'Angelic'
        Model    = 'models\angelic\v_angelic.mdl'
        Source   = 'addons\amxmodx\scripting\zp_extra_angelic_beast.sma'
        TimeCvar = 'zp_angelic_reload_time'
        Reloads  = @(
            @{ Seq = 4;  Label = 'seq 4 charging handle';  Beats = @('zp_angelic_frac_clipout', 'zp_angelic_frac_clipin', 'zp_angelic_frac_bolt') }
            @{ Seq = 11; Label = 'seq 11 bolt release';    Beats = @('zp_angelic_frac_clipout', 'zp_angelic_frac_clipin', 'zp_angelic_frac_bolt_alt') }
        )
    }
    @{
        Name     = 'Iron Beast'
        Model    = 'models\ironbeast\v_ironbeast.mdl'
        Source   = 'addons\amxmodx\scripting\zp_extra_ironbeast.sma'
        TimeCvar = 'zp_ironbeast_reload_time'
        Reloads  = @(
            @{ Seq = 1; Label = 'seq 1 reload'; Beats = @('zp_ironbeast_frac_magin', 'zp_ironbeast_frac_bolt') }
        )
    }
)

# --- readers -----------------------------------------------------------------

function Read-Sequences([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'IDST') { throw "not an IDST model: $path" }
    $ver = [BitConverter]::ToInt32($b, 4)
    if ($ver -ne 10) { throw "version $ver, only 10 is supported: $path" }

    $numSeq = [BitConverter]::ToInt32($b, 164)
    $seqIndex = [BitConverter]::ToInt32($b, 168)

    $out = @()
    for ($i = 0; $i -lt $numSeq; $i++) {
        $o = $seqIndex + $i * 176        # sizeof(mstudioseqdesc_t)
        $numEvents = [BitConverter]::ToInt32($b, $o + 48)
        $eventIndex = [BitConverter]::ToInt32($b, $o + 52)
        $numFrames = [BitConverter]::ToInt32($b, $o + 56)

        # Only id 5004 - "play this WAV" - is a sound beat. The others that turn up
        # in these packs (5001 muzzle flash, for one) carry an unrelated frame, and
        # counting them as beats shifts every cvar one place along and quietly
        # compares the wrong pairs. The reload sequences checked today happen to
        # hold nothing but 5004, which is exactly why this went unnoticed.
        $events = @()
        $skipped = @()
        for ($e = 0; $e -lt $numEvents; $e++) {
            $eo = $eventIndex + $e * 76  # sizeof(mstudioevent_t)
            $ev = [PSCustomObject]@{
                Frame   = [BitConverter]::ToInt32($b, $eo)
                Id      = [BitConverter]::ToInt32($b, $eo + 4)
                Options = ([Text.Encoding]::ASCII.GetString($b, $eo + 12, 64)).Trim([char]0)
            }
            if ($ev.Id -eq 5004) { $events += $ev } else { $skipped += $ev }
        }

        $out += [PSCustomObject]@{
            Index     = $i
            Label     = ([Text.Encoding]::ASCII.GetString($b, $o, 32)).Trim([char]0)
            Fps       = [BitConverter]::ToSingle($b, $o + 32)
            NumFrames = $numFrames
            Events    = @($events | Sort-Object Frame)
            Skipped   = @($skipped)
        }
    }
    return $out
}

function Get-CfgValue([string]$text, [string]$cvar) {
    $m = [regex]::Match($text, "(?m)^\s*$([regex]::Escape($cvar))\s+([-\d.]+)")
    if (-not $m.Success) { return $null }
    return [double]::Parse($m.Groups[1].Value, $inv)
}

# --- run ---------------------------------------------------------------------

$cfgPath = Join-Path $Root 'addons\amxmodx\configs\zombieplague.cfg'
$cfg = Get-Content $cfgPath -Raw
$rows = @()

foreach ($w in $WEAPONS) {
    $seqs = Read-Sequences (Join-Path $Root $w.Model)
    $sma = Get-Content (Join-Path $Root $w.Source) -Raw
    $reloadTime = Get-CfgValue $cfg $w.TimeCvar

    if ($null -eq $reloadTime) {
        $rows += [PSCustomObject]@{ Weapon = $w.Name; Check = $w.TimeCvar; Model = '-'; Cfg = 'MISSING'; DriftMs = '-'; Result = 'FAIL' }
        continue
    }

    foreach ($r in $w.Reloads) {
        $seq = $seqs | Where-Object Index -eq $r.Seq
        if (-not $seq) {
            $rows += [PSCustomObject]@{ Weapon = $w.Name; Check = "$($r.Label) exists"; Model = 'MISSING'; Cfg = '-'; DriftMs = '-'; Result = 'FAIL' }
            continue
        }

        # the model must be re-timed so its own length matches the reload cvar,
        # or the animation is cut off part way through the motion
        $seqTime = $seq.NumFrames / $seq.Fps
        $rows += [PSCustomObject]@{
            Weapon  = $w.Name
            Check   = "$($r.Label) length vs $($w.TimeCvar)"
            Model   = "$([math]::Round($seqTime,4))s"
            Cfg     = "$($reloadTime)s"
            DriftMs = [math]::Round(($seqTime - $reloadTime) * 1000, 1)
            Result  = Classify (($seqTime - $reloadTime) * 1000)
        }

        # never drop an event without saying so
        foreach ($sk in $seq.Skipped) {
            $rows += [PSCustomObject]@{
                Weapon = $w.Name
                Check  = "$($r.Label) non-sound event id $($sk.Id) at frame $($sk.Frame) ignored"
                Model  = $sk.Options; Cfg = '-'; DriftMs = '-'; Result = 'note'
            }
        }

        if ($seq.Events.Count -ne $r.Beats.Count) {
            $rows += [PSCustomObject]@{
                Weapon = $w.Name; Check = "$($r.Label) beat count"
                Model = "$($seq.Events.Count) events"; Cfg = "$($r.Beats.Count) cvars"
                DriftMs = '-'; Result = 'FAIL'
            }
            continue
        }

        for ($i = 0; $i -lt $r.Beats.Count; $i++) {
            $cvar = $r.Beats[$i]
            $ev = $seq.Events[$i]
            $modelFrac = $ev.Frame / $seq.NumFrames
            $cfgFrac = Get-CfgValue $cfg $cvar

            if (-not $sma.Contains("register_cvar(`"$cvar`"")) {
                # a value in the config that the plugin never registers is dead
                $rows += [PSCustomObject]@{
                    Weapon = $w.Name; Check = "$cvar registered in plugin"
                    Model = '-'; Cfg = 'NOT REGISTERED'; DriftMs = '-'; Result = 'FAIL'
                }
                continue
            }
            if ($null -eq $cfgFrac) {
                $rows += [PSCustomObject]@{
                    Weapon = $w.Name; Check = "$cvar ($($r.Label), frame $($ev.Frame))"
                    Model = [math]::Round($modelFrac, 4); Cfg = 'MISSING'; DriftMs = '-'; Result = 'FAIL'
                }
                continue
            }

            $driftMs = ($cfgFrac - $modelFrac) * $reloadTime * 1000
            $rows += [PSCustomObject]@{
                Weapon  = $w.Name
                Check   = "$cvar ($($r.Label), frame $($ev.Frame))"
                Model   = [math]::Round($modelFrac, 4)
                Cfg     = $cfgFrac
                DriftMs = [math]::Round($driftMs, 1)
                Result  = Classify $driftMs
            }
        }
    }
}

$rows | Format-Table -AutoSize
$failed  = @($rows | Where-Object Result -eq 'FAIL')
$drifted = @($rows | Where-Object Result -eq 'drift')
$notes   = @($rows | Where-Object Result -eq 'note')
"$($rows.Count) rows, $($failed.Count) failed, $($drifted.Count) tolerated drift, $($notes.Count) events ignored (clean <= ${WarnMs}ms, fail > ${ToleranceMs}ms)"
if ($failed.Count) { exit 1 }
