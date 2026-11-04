param(
    [string]$Action = 'click',
    [int]$X = 0,
    [int]$Y = 0,
    [int]$X2 = 0,
    [int]$Y2 = 0,
    [string]$Button = 'left',
    [int]$Clicks = 1,
    [string]$Text,
    [string]$Key,
    [string]$Hotkey,
    [int]$Delta = -600,
    [int]$Ms = 0,
    [int64]$Hwnd = 0,
    [string]$Title,
    [string]$TitleRegex,
    [switch]$NoActivate
)

. "$PSScriptRoot\CuCommon.ps1"

$VK = @{
    'backspace' = 0x08; 'tab' = 0x09; 'enter' = 0x0D; 'return' = 0x0D; 'shift' = 0x10; 'ctrl' = 0x11; 'control' = 0x11;
    'alt' = 0x12; 'pause' = 0x13; 'capslock' = 0x14; 'esc' = 0x1B; 'escape' = 0x1B; 'space' = 0x20; 'pageup' = 0x21;
    'pgup' = 0x21; 'pagedown' = 0x22; 'pgdn' = 0x22; 'end' = 0x23; 'home' = 0x24; 'left' = 0x25; 'arrowleft' = 0x25;
    'up' = 0x26; 'arrowup' = 0x26; 'right' = 0x27; 'arrowright' = 0x27; 'down' = 0x28; 'arrowdown' = 0x28;
    'printscreen' = 0x2C; 'prtsc' = 0x2C; 'insert' = 0x2D; 'ins' = 0x2D; 'delete' = 0x2E; 'del' = 0x2E;
    'win' = 0x5B; 'lwin' = 0x5B; 'apps' = 0x5D; 'numlock' = 0x90; 'scrolllock' = 0x91;
    'semicolon' = 0xBA; 'equals' = 0xBB; 'comma' = 0xBC; 'minus' = 0xBD; 'period' = 0xBE; 'slash' = 0xBF;
    'grave' = 0xC0; 'lbracket' = 0xDB; 'backslash' = 0xDC; 'rbracket' = 0xDD; 'quote' = 0xDE
}
foreach ($n in 1..24) { $VK["f$n"] = 0x6F + $n }
foreach ($c in 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z') {
    $VK[$c] = 0x41 + [int][char]$c - 97
}
foreach ($k in $VK.Keys) { }

function Resolve-CuVk {
    param([string]$Name)
    $k = $Name.Trim().ToLowerInvariant()
    if ($VK.ContainsKey($k)) { return [int]$VK[$k] }
    if ($k.Length -eq 1) { return [int][char]($k.ToUpperInvariant()[0]) }
    throw "unknown key name '$Name'"
}

try {
    $act = $Action.ToLowerInvariant()
    if ($act -eq 'click') { $act = 'mouse' }
    if ($act -eq 'doubleclick') { $act = 'mouse'; $Clicks = 2 }
    if ($act -eq 'rightclick') { $act = 'mouse'; $Button = 'right' }
    if ($act -eq 'middleclick') { $act = 'mouse'; $Button = 'middle' }

    if (-not $NoActivate -and ($Hwnd -gt 0 -or -not [string]::IsNullOrWhiteSpace($Title) -or -not [string]::IsNullOrWhiteSpace($TitleRegex))) {
        $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex
        if (-not (Activate-CuWindow $w)) {
            throw 'could not bring the target window to the foreground; refusing to send input blindly'
        }
    }

    switch ($act) {
        'move' {
            [CuNative]::MouseMove($X, $Y)
            Start-Sleep -Milliseconds 60
            Write-CuResult ([ordered]@{ ok = $true; cursor = (Get-CuCursor) })
        }
        'mouse' {
            [CuNative]::MouseMove($X, $Y)
            Start-Sleep -Milliseconds 40
            $down = [CuNative]::MOUSEEVENTF_LEFTDOWN
            $up = [CuNative]::MOUSEEVENTF_LEFTUP
            if ($Button -eq 'right') { $down = [CuNative]::MOUSEEVENTF_RIGHTDOWN; $up = [CuNative]::MOUSEEVENTF_RIGHTUP }
            elseif ($Button -eq 'middle') { $down = [CuNative]::MOUSEEVENTF_MIDDLEDOWN; $up = [CuNative]::MOUSEEVENTF_MIDDLEUP }
            for ($n = 1; $n -le [Math]::Max(1, $Clicks); $n++) {
                [CuNative]::MouseButton($down, $up)
                if ($n -lt $Clicks) { Start-Sleep -Milliseconds 80 }
            }
            Start-Sleep -Milliseconds 150
            Write-CuResult ([ordered]@{ ok = $true; action = 'mouse'; x = $X; y = $Y; button = $Button; clicks = $Clicks })
        }
        'drag' {
            [CuNative]::MouseMove($X, $Y)
            Start-Sleep -Milliseconds 60
            [CuNative]::MouseDown([CuNative]::MOUSEEVENTF_LEFTDOWN)
            Start-Sleep -Milliseconds 50
            $steps = 14
            for ($s = 1; $s -le $steps; $s++) {
                $nx = [int]($X + (($X2 - $X) * $s / $steps))
                $ny = [int]($Y + (($Y2 - $Y) * $s / $steps))
                [CuNative]::MouseMove($nx, $ny)
                Start-Sleep -Milliseconds 15
            }
            Start-Sleep -Milliseconds 80
            [CuNative]::MouseUp([CuNative]::MOUSEEVENTF_LEFTUP)
            Start-Sleep -Milliseconds 150
            Write-CuResult ([ordered]@{ ok = $true; action = 'drag'; from = @($X, $Y); to = @($X2, $Y2) })
        }
        'scroll' {
            [CuNative]::MouseMove($X, $Y)
            Start-Sleep -Milliseconds 40
            [CuNative]::MouseWheel($Delta)
            Start-Sleep -Milliseconds 150
            Write-CuResult ([ordered]@{ ok = $true; action = 'scroll'; delta = $Delta; cursor = (Get-CuCursor) })
        }
        'type' {
            if ($null -eq $Text) { throw 'type needs -Text' }
            $chunks = [regex]::Split($Text, "\r?\n")
            for ($ci = 0; $ci -lt $chunks.Count; $ci++) {
                foreach ($ch in $chunks[$ci].ToCharArray()) {
                    [CuNative]::UnicodeChar($ch)
                    Start-Sleep -Milliseconds 4
                }
                if ($ci -lt $chunks.Count - 1) {
                    [CuNative]::Key([uint16]0x0D, $false)
                    [CuNative]::Key([uint16]0x0D, $true)
                    Start-Sleep -Milliseconds 25
                }
            }
            Start-Sleep -Milliseconds 100
            Write-CuResult ([ordered]@{ ok = $true; action = 'type'; length = $Text.Length })
        }
        'key' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'key needs -Key (for example ENTER, TAB, F5, DOWN)' }
            $vk = Resolve-CuVk $Key
            [CuNative]::Key([uint16]$vk, $false)
            Start-Sleep -Milliseconds 30
            [CuNative]::Key([uint16]$vk, $true)
            Start-Sleep -Milliseconds 100
            Write-CuResult ([ordered]@{ ok = $true; action = 'key'; key = $Key })
        }
        'hotkey' {
            if ([string]::IsNullOrWhiteSpace($Hotkey)) { throw 'hotkey needs -Hotkey (for example ctrl+shift+s)' }
            $vks = @()
            foreach ($p in @($Hotkey -split '\+')) { $vks += (Resolve-CuVk $p) }
            foreach ($v in $vks) { [CuNative]::Key([uint16]$v, $false); Start-Sleep -Milliseconds 25 }
            for ($i = $vks.Count - 1; $i -ge 0; $i--) { [CuNative]::Key([uint16]$vks[$i], $true); Start-Sleep -Milliseconds 25 }
            Start-Sleep -Milliseconds 120
            Write-CuResult ([ordered]@{ ok = $true; action = 'hotkey'; hotkey = $Hotkey })
        }
        'paste' {
            if ($null -eq $Text) { throw 'paste needs -Text' }
            Set-Clipboard -Value $Text
            Start-Sleep -Milliseconds 80
            $vkCtrl = Resolve-CuVk 'ctrl'
            $vkV = Resolve-CuVk 'v'
            [CuNative]::Key([uint16]$vkCtrl, $false)
            [CuNative]::Key([uint16]$vkV, $false)
            Start-Sleep -Milliseconds 30
            [CuNative]::Key([uint16]$vkV, $true)
            [CuNative]::Key([uint16]$vkCtrl, $true)
            Start-Sleep -Milliseconds 200
            Write-CuResult ([ordered]@{ ok = $true; action = 'paste'; length = $Text.Length })
        }
        'wait' {
            if ($Ms -le 0) { $Ms = 500 }
            Start-Sleep -Milliseconds $Ms
            Write-CuResult ([ordered]@{ ok = $true; action = 'wait'; ms = $Ms; cursor = (Get-CuCursor) })
        }
        'cursor' {
            Write-CuResult ([ordered]@{ ok = $true; cursor = (Get-CuCursor); foreground = [CuNative]::GetWindowTitle([CuNative]::GetForegroundWindow()) })
        }
        default { throw "unknown action '$Action' (move|click|doubleclick|rightclick|drag|scroll|type|key|hotkey|paste|wait|cursor)" }
    }
} catch {
    Write-CuResult (New-CuError $_.Exception.Message)
    exit 1
}
