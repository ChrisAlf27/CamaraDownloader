# Genera assets\app.ico (camara azul con flecha de descarga) en 16/24/32/48/64/256 px.
param([string]$Path = (Join-Path $PSScriptRoot 'app.ico'))
Add-Type -AssemblyName System.Drawing

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}

function New-IconPng([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
    $k = $s / 256.0
    $blue  = [System.Drawing.Color]::FromArgb(255, 30, 110, 190)
    $dark  = [System.Drawing.Color]::FromArgb(255, 20, 60, 110)
    $white = [System.Drawing.Brushes]::White
    # cuerpo de la camara
    $g.FillPath((New-Object System.Drawing.SolidBrush $blue), (New-RoundRect (16*$k) (60*$k) (224*$k) (156*$k) (28*$k)))
    $g.FillPath((New-Object System.Drawing.SolidBrush $blue), (New-RoundRect (80*$k) (36*$k) (96*$k) (40*$k) (12*$k)))
    # lente
    $g.FillEllipse($white, 68*$k, 78*$k, 120*$k, 120*$k)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $dark), 84*$k, 94*$k, 88*$k, 88*$k)
    # flecha de descarga dentro del lente
    $arrow = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF (116*$k), (106*$k)), (New-Object System.Drawing.PointF (140*$k), (106*$k)),
        (New-Object System.Drawing.PointF (140*$k), (136*$k)), (New-Object System.Drawing.PointF (158*$k), (136*$k)),
        (New-Object System.Drawing.PointF (128*$k), (168*$k)), (New-Object System.Drawing.PointF (98*$k), (136*$k)),
        (New-Object System.Drawing.PointF (116*$k), (136*$k)))
    $g.FillPolygon($white, $arrow)
    # luz roja
    $g.FillEllipse([System.Drawing.Brushes]::OrangeRed, 196*$k, 76*$k, 22*$k, 22*$k)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    if ($s -ge 256) {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    } else {
        # Entrada BMP clasica (DIB 32 bits + mascara AND), compatible con System.Drawing
        $bw = New-Object System.IO.BinaryWriter($ms)
        $maskRow = [int]([Math]::Ceiling($s / 32.0) * 4)
        $bw.Write([uint32]40); $bw.Write([int32]$s); $bw.Write([int32]($s * 2)); $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]0); $bw.Write([uint32]($s * $s * 4 + $maskRow * $s)); $bw.Write([int32]0); $bw.Write([int32]0)
        $bw.Write([uint32]0); $bw.Write([uint32]0)
        for ($y = $s - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $s; $x++) { $c = $bmp.GetPixel($x, $y); $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A) }
        }
        $bw.Write((New-Object byte[] ($maskRow * $s)))
        $bw.Flush()
    }
    $bmp.Dispose()
    return , $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 256
$pngs = foreach ($s in $sizes) { , (New-IconPng $s) }
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush()
[IO.File]::WriteAllBytes($Path, $out.ToArray())
Write-Host "Icono: $Path"
