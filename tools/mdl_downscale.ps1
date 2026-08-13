# Downscale oversized textures inside a GoldSrc studio model (MDL v10).
#
# Why this is needed: these models were authored for CrossFire's forked engine,
# which accepts 1024x1024 studio textures. GoldSrc does not - it fails the map
# load with "GL_LoadTexture: too big".
#
# Three things have to change together, and missing any one of them produces a
# model that loads but renders wrong rather than one that fails loudly:
#
#   1. the texture pixels themselves, subsampled 2:1
#   2. every UV coordinate on every mesh that uses a resized texture - MDL
#      stores S/T in absolute texels, not normalised 0-1, so halving the image
#      without halving the UVs makes the texture wrap
#   3. the per-texture data offsets and the header's total length, since the
#      texture block shrinks
#
# The palette is carried across untouched. That is the whole reason this is
# safe to do by hand: subsampling picks existing pixels, so every index still
# refers to the colour it always did and no requantisation is involved.

param(
    [Parameter(Mandatory=$true)][string]$InPath,
    [Parameter(Mandatory=$true)][string]$OutPath,
    [int]$MaxDim = 512
)

$b = [IO.File]::ReadAllBytes($InPath)

if ([Text.Encoding]::ASCII.GetString($b,0,4) -ne 'IDST') { throw "not an IDST model: $InPath" }
$ver = [BitConverter]::ToInt32($b,4)
if ($ver -ne 10) { throw "version $ver, only 10 is supported" }

$numTex   = [BitConverter]::ToInt32($b,180)
$texIndex = [BitConverter]::ToInt32($b,184)
$numSkinRef     = [BitConverter]::ToInt32($b,192)
$skinIndex      = [BitConverter]::ToInt32($b,200)
$numBodyparts   = [BitConverter]::ToInt32($b,204)
$bodypartIndex  = [BitConverter]::ToInt32($b,208)

# --- work out which textures need shrinking, and by what factor ---------------
$tex = @()
for ($i = 0; $i -lt $numTex; $i++) {
    $o = $texIndex + $i*80
    $w = [BitConverter]::ToInt32($b,$o+68)
    $h = [BitConverter]::ToInt32($b,$o+72)
    $shrink = ($w -gt $MaxDim -or $h -gt $MaxDim)
    $tex += [PSCustomObject]@{
        Slot=$i; HdrOff=$o
        Name=([Text.Encoding]::ASCII.GetString($b,$o,64)).Trim([char]0)
        W=$w; H=$h; DataOff=[BitConverter]::ToInt32($b,$o+76)
        Shrink=$shrink
        NewW=$(if($shrink){[int]($w/2)}else{$w})
        NewH=$(if($shrink){[int]($h/2)}else{$h})
    }
}
if (-not ($tex | Where-Object Shrink)) { throw "nothing over $MaxDim in $InPath" }

# skinref -> texture slot, first skin family only
$skin = @()
for ($i = 0; $i -lt $numSkinRef; $i++) { $skin += [BitConverter]::ToInt16($b,$skinIndex + $i*2) }

# --- 2. halve UVs on meshes that use a shrinking texture ----------------------
# Done first, in place: it changes no byte counts, so offsets stay valid.
$uvTouched = 0
for ($p = 0; $p -lt $numBodyparts; $p++) {
    $bo = $bodypartIndex + $p*76
    $nModels = [BitConverter]::ToInt32($b,$bo+64)
    $mIndex  = [BitConverter]::ToInt32($b,$bo+72)
    for ($m = 0; $m -lt $nModels; $m++) {
        $mo = $mIndex + $m*112
        $nMesh    = [BitConverter]::ToInt32($b,$mo+72)
        $meshIndex= [BitConverter]::ToInt32($b,$mo+76)
        for ($k = 0; $k -lt $nMesh; $k++) {
            $ko = $meshIndex + $k*20
            $triIndex = [BitConverter]::ToInt32($b,$ko+4)
            $skinRef  = [BitConverter]::ToInt32($b,$ko+8)
            $slot = if ($skinRef -lt $skin.Count) { $skin[$skinRef] } else { $skinRef }
            if (-not $tex[$slot].Shrink) { continue }

            $pos = $triIndex
            while ($true) {
                $cnt = [BitConverter]::ToInt16($b,$pos); $pos += 2
                if ($cnt -eq 0) { break }
                $abs = [Math]::Abs($cnt)
                for ($v = 0; $v -lt $abs; $v++) {
                    $s = [BitConverter]::ToInt16($b,$pos+4)
                    $t = [BitConverter]::ToInt16($b,$pos+6)
                    [void][BitConverter]::GetBytes([int16]([Math]::Floor($s/2))).CopyTo($b,$pos+4)
                    [void][BitConverter]::GetBytes([int16]([Math]::Floor($t/2))).CopyTo($b,$pos+6)
                    $pos += 8; $uvTouched++
                }
            }
        }
    }
}

# --- 1 + 3. rebuild the texture block and fix offsets -------------------------
# The texture block is the tail of the file; everything before the first
# texture's data is untouched model data.
$firstData = ($tex | Sort-Object DataOff | Select-Object -First 1).DataOff
$out = New-Object System.IO.MemoryStream
$out.Write($b, 0, $firstData)

foreach ($t in $tex | Sort-Object DataOff) {
    $src = $t.DataOff
    $newOff = [int]$out.Position
    if ($t.Shrink) {
        $pixels = New-Object byte[] ($t.NewW * $t.NewH)
        for ($y = 0; $y -lt $t.NewH; $y++) {
            $srcRow = $src + ($y*2)*$t.W
            $dstRow = $y*$t.NewW
            for ($x = 0; $x -lt $t.NewW; $x++) { $pixels[$dstRow+$x] = $b[$srcRow + $x*2] }
        }
        $out.Write($pixels, 0, $pixels.Length)
        $out.Write($b, $src + $t.W*$t.H, 768)   # palette, verbatim
    } else {
        $out.Write($b, $src, $t.W*$t.H + 768)
    }
    $t | Add-Member -NotePropertyName NewOff -NotePropertyValue $newOff -Force
}

$res = $out.ToArray(); $out.Dispose()

foreach ($t in $tex) {
    [void][BitConverter]::GetBytes([int32]$t.NewW).CopyTo($res, $t.HdrOff+68)
    [void][BitConverter]::GetBytes([int32]$t.NewH).CopyTo($res, $t.HdrOff+72)
    [void][BitConverter]::GetBytes([int32]$t.NewOff).CopyTo($res, $t.HdrOff+76)
}
[void][BitConverter]::GetBytes([int32]$res.Length).CopyTo($res, 72)

[IO.File]::WriteAllBytes($OutPath, $res)

[PSCustomObject]@{
    Model     = Split-Path $InPath -Leaf
    Textures  = ($tex | ForEach-Object { "$($_.Name) $($_.W)x$($_.H)->$($_.NewW)x$($_.NewH)" }) -join "; "
    UVsHalved = $uvTouched
    OldBytes  = $b.Length
    NewBytes  = $res.Length
}
