<#
.SYNOPSIS
    Gera assets\cofboost.ico (16 a 256 px) e site\assets\favicon.png.
    Uso: powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1
#>
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent

function New-IconBitmap {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'

    # Quadrado arredondado violeta
    $r = [single]($Size * 0.22)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2; $s = [single]($Size - 1)
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($s - $d, 0, $d, $d, 270, 90)
    $path.AddArc($s - $d, $s - $d, $d, $d, 0, 90); $path.AddArc(0, $s - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($Size, $Size)),
        [System.Drawing.Color]::FromArgb(255, 139, 92, 246), [System.Drawing.Color]::FromArgb(255, 91, 61, 214))
    $g.FillPath($brush, $path)

    # Linha de frametime: picos à esquerda, estável à direita (em ícones grandes)
    if ($Size -ge 48) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 91, 240, 176), [single]($Size * 0.045))
        $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $y = $Size * 0.78
        $pts = @(
            @(0.16, 0), @(0.24, -0.12), @(0.30, 0.02), @(0.36, -0.08), @(0.42, 0), @(0.84, 0)
        ) | ForEach-Object { New-Object System.Drawing.PointF([single]($_[0] * $Size), [single]($y + $_[1] * $Size)) }
        $g.DrawLines($pen, [System.Drawing.PointF[]]$pts)
    }

    # "OC"
    $fontSize = if ($Size -ge 48) { $Size * 0.36 } else { $Size * 0.46 }
    $font = New-Object System.Drawing.Font('Segoe UI', [single]$fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $textTop = if ($Size -ge 48) { -$Size * 0.08 } else { 0 }
    $rect = New-Object System.Drawing.RectangleF(0, [single]$textTop, $Size, $Size)
    $g.DrawString('CB', $font, [System.Drawing.Brushes]::White, $rect, $fmt)
    $g.Dispose()
    $bmp
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($s -eq 64) { $bmp.Save((Join-Path $root 'site\assets\favicon.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
    if ($s -eq 256) { $bmp.Save((Join-Path $root 'assets\cofboost.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    , $ms.ToArray()
}

# ICO com imagens PNG (aceito desde o Windows Vista)
New-Item -ItemType Directory -Path (Join-Path $root 'assets') -Force | Out-Null
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $root 'assets\cofboost.ico'), $out.ToArray())
Write-Host 'assets\cofboost.ico e site\assets\favicon.png gerados.'
