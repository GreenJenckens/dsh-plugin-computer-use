param(
    [int]$Monitor = -1,
    [int64]$Hwnd = 0,
    [string]$Title,
    [string]$TitleRegex,
    [int]$ProcessId = 0,
    [int]$MaxWidth = 1600,
    [string]$Region,
    [string]$Path,
    [switch]$ListMonitors
)

. "$PSScriptRoot\CuCommon.ps1"

try {
    if ($ListMonitors) {
        Write-CuResult ([ordered]@{ ok = $true; monitors = @(Get-CuScreens); cursor = (Get-CuCursor) })
        exit 0
    }

    $screens = @(Get-CuScreens)
    $srcX = 0; $srcY = 0; $srcW = 0; $srcH = 0
    $label = ''

    if (-not [string]::IsNullOrWhiteSpace($Region)) {
        $parts = $Region -split ','
        if ($parts.Count -ne 4) { throw "region must be 'x,y,width,height'" }
        $srcX = [int]$parts[0]; $srcY = [int]$parts[1]
        $srcW = [int]$parts[2]; $srcH = [int]$parts[3]
        $label = "region:$Region"
    } elseif ($Hwnd -gt 0 -or -not [string]::IsNullOrWhiteSpace($Title) -or -not [string]::IsNullOrWhiteSpace($TitleRegex)) {
        $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
        if (-not (Activate-CuWindow $w)) { throw 'could not bring the window to the foreground; a window screenshot would capture another window' }
        Start-Sleep -Milliseconds 250
        $r = [CuNative]::GetFrameBounds($w)
        $srcX = $r.Left; $srcY = $r.Top
        $srcW = $r.Right - $r.Left; $srcH = $r.Bottom - $r.Top
        $label = [CuNative]::GetWindowTitle($w)
        if ($srcW -le 0 -or $srcH -le 0) { throw "window has an empty rectangle" }
    } else {
        if ($Monitor -ge 0) {
            if ($Monitor -ge $screens.Count) { throw "monitor $Monitor not found (have $($screens.Count))" }
            $s = $screens[$Monitor]
        } else {
            $s = @($screens | Where-Object { $_.primary })[0]
        }
        $srcX = $s.x; $srcY = $s.y; $srcW = $s.width; $srcH = $s.height
        $label = "monitor:$($s.index)"
    }

    $bmp = New-Object System.Drawing.Bitmap $srcW, $srcH
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($srcX, $srcY, 0, 0, (New-Object System.Drawing.Size $srcW, $srcH))
    $g.Dispose()

    $scale = 1.0
    $outW = $srcW; $outH = $srcH
    if ($MaxWidth -gt 0 -and $srcW -gt $MaxWidth) {
        $scale = [double]$MaxWidth / [double]$srcW
        $outW = $MaxWidth
        $outH = [int][Math]::Round($srcH * $scale)
        $resized = New-Object System.Drawing.Bitmap $outW, $outH
        $g2 = [System.Drawing.Graphics]::FromImage($resized)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g2.DrawImage($bmp, 0, 0, $outW, $outH)
        $g2.Dispose()
        $bmp.Dispose()
        $bmp = $resized
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $dir = Join-Path $env:TEMP 'dsh-cu'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Path = Join-Path $dir ("shot-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + ".png")
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $cursor = Get-CuCursor
    Write-CuResult ([ordered]@{
        ok           = $true
        path         = (Resolve-Path $Path).Path
        width        = $outW
        height       = $outH
        sourceWidth  = $srcW
        sourceHeight = $srcH
        scale        = [Math]::Round($scale, 4)
        sourceX      = $srcX
        sourceY      = $srcY
        label        = $label
        cursor       = $cursor
        monitors     = $screens
    })
} catch {
    Write-CuResult (New-CuError $_.Exception.Message)
    exit 1
}

