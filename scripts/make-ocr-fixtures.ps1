param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\plugin\dsh-plugin-computer-use\test\fixtures\ocr')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$ru = @(
    'Итого: 1 234,56 руб. Заказ 0123456789',
    'Счёт № 45-11: оплата 98 765,43 руб. НДС 20%',
    'Артикул 5 шт., ячейка 10:55, вес 1,05 кг',
    'Товар 5 шт. x 1 055,00 = 5 275,00 руб.'
)
$en = @(
    'Order 45-11: total 1,234.56 USD',
    'Invoice 45-11: paid 98,765.43 USD on 2026-11-14',
    'Build 1055: 0 errors, 0 warnings, 5 files',
    'Serial 5S-42: verify code 10:55'
)
$code = @(
    '0123456789 0O1Il5S 00 0O O0 1I l1 5S 1055',
    '0O1Il5S 0123456789 10 100 1000 10.55 1055',
    '00 0O O0 1I l1 5S S5 0123456789 1055',
    '0123456789 0O1Il5S 00/0O 1I/l1 5S/S5 1055'
)

$cases = @(
    @{ font = 'Segoe UI'; pt = 9; theme = 'light'; k = 0 },
    @{ font = 'Segoe UI'; pt = 11; theme = 'light'; k = 1 },
    @{ font = 'Segoe UI'; pt = 14; theme = 'light'; k = 2 },
    @{ font = 'Segoe UI'; pt = 18; theme = 'light'; k = 3 },
    @{ font = 'Consolas'; pt = 9; theme = 'light'; k = 1 },
    @{ font = 'Consolas'; pt = 11; theme = 'light'; k = 2 },
    @{ font = 'Consolas'; pt = 14; theme = 'light'; k = 3 },
    @{ font = 'Consolas'; pt = 18; theme = 'light'; k = 0 },
    @{ font = 'Segoe UI'; pt = 9; theme = 'dark'; k = 2 },
    @{ font = 'Segoe UI'; pt = 14; theme = 'dark'; k = 3 },
    @{ font = 'Consolas'; pt = 9; theme = 'dark'; k = 0 },
    @{ font = 'Consolas'; pt = 14; theme = 'dark'; k = 1 }
)

$manifest = @()
$index = 0
foreach ($case in $cases) {
    $index++
    $bg = if ($case.theme -eq 'dark') { [System.Drawing.Color]::FromArgb(30, 30, 30) } else { [System.Drawing.Color]::White }
    $fg = if ($case.theme -eq 'dark') { [System.Drawing.Color]::FromArgb(212, 212, 212) } else { [System.Drawing.Color]::Black }
    $font = New-Object System.Drawing.Font($case.font, [float]$case.pt)
    $lineHeight = [int][Math]::Ceiling($font.GetHeight() + 8)
    $bmp = New-Object System.Drawing.Bitmap 900, (20 + 3 * $lineHeight)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($bg)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $lines = @($ru[$case.k], $en[$case.k], $code[$case.k])
    $y = 10
    for ($i = 0; $i -lt 3; $i++) {
        $g.DrawString($lines[$i], $font, (New-Object System.Drawing.SolidBrush($fg)), 10, $y)
        $y += $lineHeight
    }
    $g.Dispose()
    $name = ('ocr-{0:d2}-{1}-{2}pt-{3}.png' -f $index, ($case.font -replace ' ', ''), $case.pt, $case.theme)
    $path = Join-Path $OutDir $name
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $font.Dispose()
    $manifest += [ordered]@{
        id = ('ocr-{0:d2}' -f $index)
        file = $name
        font = $case.font
        sizePt = $case.pt
        theme = $case.theme
        width = 900
        height = (20 + 3 * $lineHeight)
        lines = @(
            [ordered]@{ lang = 'ru'; role = 'ru-prose'; text = $lines[0] },
            [ordered]@{ lang = 'en'; role = 'en-prose'; text = $lines[1] },
            [ordered]@{ lang = 'code'; role = 'code'; text = $lines[2] }
        )
    }
}

$manifestPath = Join-Path $OutDir 'manifest.json'
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 8) + "`n"), (New-Object Text.UTF8Encoding($false)))
'wrote ' + $manifest.Count + ' fixtures to ' + $OutDir
