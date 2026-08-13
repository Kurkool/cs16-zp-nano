# Shift a GoldSrc studio model in view space by moving its root bone.
#
# Why the root bone and not the vertices: vertices are stored in bone-local
# space, so moving them breaks skinning. Every bone's final position is
# value[i] + delta * scale[i], where the animation supplies the delta - so
# adding to the root bone's value translates the whole hierarchy, every frame
# of every sequence, and nothing else has to change.
#
# Viewmodel axes, from the camera's point of view:
#   X  forward, away from you   (too high = the model floats out in front)
#   Y  left / right
#   Z  up / down                (positive is above the eye line)
#
# For reference, ZP's own v_knife_zombie.mdl sits at X 3.7..41.2, Z -19.7..-2.8
# in its idle sequence - entirely below the eye line, reaching the screen edge
# at the near end. A ported CrossFire viewmodel typically sits well forward of
# that and needs pulling back and down.
#
# The sequence bounding boxes are shifted too. They are only used for culling,
# but leaving them stale would make the model vanish at certain view angles.

param(
    [Parameter(Mandatory=$true)][string]$Path,
    [double]$X = 0,
    [double]$Y = 0,
    [double]$Z = 0,
    [switch]$WhatIf
)

$b = [IO.File]::ReadAllBytes($Path)
if ([Text.Encoding]::ASCII.GetString($b,0,4) -ne 'IDST') { throw "not an IDST model" }

$numBones = [BitConverter]::ToInt32($b,140)
$boneIndex = [BitConverter]::ToInt32($b,144)

$root = -1
for ($i = 0; $i -lt $numBones; $i++) {
    if ([BitConverter]::ToInt32($b, $boneIndex + $i*112 + 32) -eq -1) { $root = $i; break }
}
if ($root -lt 0) { throw "no root bone (none with parent -1)" }

$ro = $boneIndex + $root*112
$rootName = ([Text.Encoding]::ASCII.GetString($b,$ro,32)).Trim([char]0)
$bx = [BitConverter]::ToSingle($b,$ro+64)
$by = [BitConverter]::ToSingle($b,$ro+68)
$bz = [BitConverter]::ToSingle($b,$ro+72)
$ax = $bx + $X
$ay = $by + $Y
$az = $bz + $Z

# sequence 0 bbox, before - reported so the caller can see the effect
$seqIndex = [BitConverter]::ToInt32($b,168)
$numSeq   = [BitConverter]::ToInt32($b,164)
$bMinX = [BitConverter]::ToSingle($b,$seqIndex+96)
$bMaxX = [BitConverter]::ToSingle($b,$seqIndex+108)
$bMinZ = [BitConverter]::ToSingle($b,$seqIndex+104)
$bMaxZ = [BitConverter]::ToSingle($b,$seqIndex+116)

if (-not $WhatIf) {
    [void][BitConverter]::GetBytes([single]$ax).CopyTo($b,$ro+64)
    [void][BitConverter]::GetBytes([single]$ay).CopyTo($b,$ro+68)
    [void][BitConverter]::GetBytes([single]$az).CopyTo($b,$ro+72)

    for ($s = 0; $s -lt $numSeq; $s++) {
        $o = $seqIndex + $s*176
        foreach ($pair in @(@(96,$X), @(100,$Y), @(104,$Z), @(108,$X), @(112,$Y), @(116,$Z))) {
            $off = $o + $pair[0]
            $v = [BitConverter]::ToSingle($b,$off) + $pair[1]
            [void][BitConverter]::GetBytes([single]$v).CopyTo($b,$off)
        }
    }
    [IO.File]::WriteAllBytes($Path,$b)
}

[PSCustomObject]@{
    Model    = Split-Path $Path -Leaf
    RootBone = $rootName
    Shift    = "X $X, Y $Y, Z $Z"
    RootPos  = "$([math]::Round($bx,2)),$([math]::Round($by,2)),$([math]::Round($bz,2)) -> $([math]::Round($ax,2)),$([math]::Round($ay,2)),$([math]::Round($az,2))"
    Seq0X    = "$([math]::Round($bMinX,1))..$([math]::Round($bMaxX,1)) -> $([math]::Round($bMinX+$X,1))..$([math]::Round($bMaxX+$X,1))"
    Seq0Z    = "$([math]::Round($bMinZ,1))..$([math]::Round($bMaxZ,1)) -> $([math]::Round($bMinZ+$Z,1))..$([math]::Round($bMaxZ+$Z,1))"
    Applied  = (-not $WhatIf)
}
