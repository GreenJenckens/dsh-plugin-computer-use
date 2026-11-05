# bridge.ps1 - long-running JSON-lines host for the DSH computer-use plugin.
# Reads one JSON request per line from stdin, writes one JSON response per line
# to stdout. Keeps UI Automation and Win32 handles warm between calls.

param(
    [string]$TempDir = (Join-Path $env:TEMP 'dsh-cu'),
    [switch]$SelfTest,
    [int]$RetentionHours = 2,
    [int]$MaxFiles = 150
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:RetentionHours = [Math]::Min(168, [Math]::Max(1, $RetentionHours))
$script:MaxFiles = [Math]::Min(2000, [Math]::Max(1, $MaxFiles))
$script:CuRefs = @{}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)

. (Join-Path $PSScriptRoot 'CuCommon.ps1')

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$ControlView = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$RawView = [System.Windows.Automation.TreeWalker]::RawViewWalker

if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Windows PowerShell 5.1 (Desktop edition) is required; pwsh 7 cannot host UI Automation and WinRT OCR' }

function Invoke-CuSelfTest {
    $script:cuSelfTestFail = 0
    $check = {
        param([string]$Name, [int]$Ax, [int]$Ay, [int]$Ex, [int]$Ey)
        if ([Math]::Abs($Ax - $Ex) -le 1 -and [Math]::Abs($Ay - $Ey) -le 1) {
            [Console]::Out.WriteLine('PASS ' + $Name + ' ' + $Ax + ',' + $Ay)
        } else {
            [Console]::Out.WriteLine('FAIL ' + $Name + ' got ' + $Ax + ',' + $Ay + ' want ' + $Ex + ',' + $Ey)
            $script:cuSelfTestFail++
        }
    }
    $ax = 0; $ay = 0
    [CuNative]::MapVirtualPoint(0, 0, 0, 0, 1920, 1080, [ref]$ax, [ref]$ay)
    & $check 'origin' $ax $ay 0 0
    [CuNative]::MapVirtualPoint(1919, 1079, 0, 0, 1920, 1080, [ref]$ax, [ref]$ay)
    & $check 'bottom-right' $ax $ay 65535 65535
    [CuNative]::MapVirtualPoint(-1000, 500, -1920, 0, 3840, 1080, [ref]$ax, [ref]$ay)
    & $check 'negative-origin' $ax $ay 15705 30368
    [CuNative]::MapVirtualPoint(-1, -1, 0, 0, 1920, 1080, [ref]$ax, [ref]$ay)
    & $check 'just-outside' $ax $ay -34 -61
    $layouts = @(
        @{ vx = 0; vy = 0; vw = 1920; vh = 1080 },
        @{ vx = -1920; vy = 0; vw = 3840; vh = 1080 },
        @{ vx = 0; vy = -1080; vw = 1920; vh = 2160 },
        @{ vx = -2560; vy = 0; vw = 4480; vh = 1440 }
    )
    $points = @(@(0, 0), @(1919, 1079), @(-1000, 500), @(500, 500), @(-1920, 0), @(1919, 0), @(0, 1079), @(-1, -1))
    foreach ($layout in $layouts) {
        foreach ($point in $points) {
            [CuNative]::MapVirtualPoint($point[0], $point[1], $layout.vx, $layout.vy, $layout.vw, $layout.vh, [ref]$ax, [ref]$ay)
            $ex = [int][Math]::Round($ax * ($layout.vw - 1) / 65535.0) + $layout.vx
            $ey = [int][Math]::Round($ay * ($layout.vh - 1) / 65535.0) + $layout.vy
            & $check ('roundtrip ' + $layout.vx + ',' + $layout.vy + ' ' + $point[0] + ',' + $point[1]) $ex $ey $point[0] $point[1]
        }
    }
    [CuNative]::MapVirtualPoint(100, 100, 0, 0, 1920, 1080, [ref]$ax, [ref]$ay)
    $m1 = $ax
    [CuNative]::MapVirtualPoint(101, 100, 0, 0, 1920, 1080, [ref]$ax, [ref]$ay)
    if ($ax -gt $m1) { [Console]::Out.WriteLine('PASS monotonic ' + $m1 + ' -> ' + $ax) } else { [Console]::Out.WriteLine('FAIL monotonic ' + $m1 + ' -> ' + $ax); $script:cuSelfTestFail++ }
    [Console]::Out.WriteLine('INFO dpi=' + [CuNative]::GetMonitorDpi(1, 1) + ' screen=' + [System.Windows.Forms.SystemInformation]::VirtualScreen)
    if ($script:cuSelfTestFail -eq 0) { [Console]::Out.WriteLine('SELFTEST OK'); return 0 }
    [Console]::Out.WriteLine('SELFTEST FAILED ' + $script:cuSelfTestFail)
    return 1
}

if ($SelfTest) { exit (Invoke-CuSelfTest) }

if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

# ---------------------------------------------------------------- helpers ----

function Get-Arg {
    param($A, [string]$Name, $Default = $null)
    if ($null -eq $A) { return $Default }
    $p = $A.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-ArgInt {
    param($A, [string]$Name, [int]$Default = 0)
    $v = Get-Arg $A $Name $null
    if ($null -eq $v) { return $Default }
    return [int]$v
}

function Get-ArgStr {
    param($A, [string]$Name, [string]$Default = '')
    $v = Get-Arg $A $Name $null
    if ($null -eq $v) { return $Default }
    return [string]$v
}

function Get-ArgBool {
    param($A, [string]$Name, [bool]$Default = $false)
    $v = Get-Arg $A $Name $null
    if ($null -eq $v) { return $Default }
    return [bool]$v
}

function Get-ArgFloat {
    param($A, [string]$Name, [double]$Default = 0)
    $v = Get-Arg $A $Name $null
    if ($null -eq $v) { return $Default }
    return [double]$v
}

$script:AuditPath = Join-Path $TempDir 'audit.jsonl'
$script:IndicatorDir = Join-Path $TempDir 'indicator'

function Touch-CuIndicator {
    try {
        New-Item -ItemType Directory -Path $script:IndicatorDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:IndicatorDir 'active'), [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()), (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

function Test-CuCancel {
    if (Test-Path (Join-Path $script:IndicatorDir 'cancel')) {
        throw 'computer use was cancelled by the user (Ctrl+Alt+Shift+Q); press it again to resume'
    }
}

function Request-CuConfirmation {
    param([string]$Action, [string]$Detail, [int]$TimeoutMs = 30000)
    $ready = Join-Path $script:IndicatorDir 'ready'
    if (-not (Test-Path $ready)) { return $false }
    try {
        $readyData = Get-Content $ready -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $readyData.pid -or -not (Get-Process -Id ([int]$readyData.pid) -ErrorAction SilentlyContinue)) { return $false }
    } catch { return $false }
    $request = Join-Path $script:IndicatorDir 'confirm-request.json'
    $response = Join-Path $script:IndicatorDir 'confirm-response.json'
    $id = [guid]::NewGuid().ToString('n')
    try {
        $payload = [ordered]@{ id = $id; action = $Action; detail = $Detail; at = (Get-Date).ToString('o') }
        $tmp = $request + '.tmp'
        [IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        Move-Item -Force $tmp $request
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path (Join-Path $script:IndicatorDir 'cancel')) { return $false }
            if (Test-Path $response) {
                try {
                    $answer = Get-Content $response -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$answer.id -eq $id) {
                        Remove-Item -Force $request, $response -ErrorAction SilentlyContinue
                        return [bool]$answer.allow
                    }
                } catch {}
            }
            Start-Sleep -Milliseconds 100
        }
        Remove-Item -Force $request, $response -ErrorAction SilentlyContinue
        return $false
    } catch {
        return $false
    }
}


function Write-CuAudit {
    param([string]$Action, $Target, [bool]$Ok = $true)
    try {
        $record = [ordered]@{
            at     = (Get-Date).ToString('o')
            action = $Action
            ok     = $Ok
            target = $Target
        }
        if (Test-Path $script:AuditPath) {
            $info = Get-Item $script:AuditPath -ErrorAction SilentlyContinue
            if ($null -ne $info -and $info.Length -gt 5MB) { Move-Item -Force $script:AuditPath ($script:AuditPath + '.1') }
        }
        ($record | ConvertTo-Json -Compress) | Add-Content -Path $script:AuditPath -Encoding UTF8
    } catch {}
}

function Assert-CuScreenRect {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    if ($W -le 0 -or $H -le 0) { throw 'capture rectangle must have a positive width and height' }
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($X -lt $vs.Left -or $Y -lt $vs.Top -or ($X + $W) -gt $vs.Right -or ($Y + $H) -gt $vs.Bottom) {
        throw ('capture rectangle ' + $X + ',' + $Y + ' ' + $W + 'x' + $H + ' is outside the virtual screen ' + $vs.Left + ',' + $vs.Top + ' ' + $vs.Width + 'x' + $vs.Height)
    }
}

function Clear-CuTemp {
    try {
        $now = Get-Date
        $files = @(Get-ChildItem $TempDir -File -Filter '*.png' -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            if (($now - $file.LastWriteTime).TotalHours -gt $script:RetentionHours) { Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue }
        }
        $files = @(Get-ChildItem $TempDir -File -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
        if ($files.Count -gt $script:MaxFiles) {
            $files | Select-Object -First ($files.Count - $script:MaxFiles) | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

# Enforce the TTL at host start too, not only when a new capture is written.
Clear-CuTemp

function Capture-CuScreenRect {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size $W, $H))
    $g.Dispose()
    return $bmp
}

function Capture-CuWindowBitmap {
    param([IntPtr]$Hwnd)
    $r = New-Object CuNative+RECT
    [CuNative]::GetWindowRect($Hwnd, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw 'window has an empty rectangle' }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = $false
    try { $ok = [CuNative]::PrintWindow($Hwnd, $hdc, 2) } finally { $g.ReleaseHdc($hdc); $g.Dispose() }
    if (-not $ok) { $bmp.Dispose(); throw 'PrintWindow failed for this window' }
    # DWM frame excludes invisible resize borders; crop so print and screen
    # captures share the same origin for OCR boxes and clicks.
    $frame = [CuNative]::GetFrameBounds($Hwnd)
    $dx = $frame.Left - $r.Left
    $dy = $frame.Top - $r.Top
    $cw = $frame.Right - $frame.Left
    $ch = $frame.Bottom - $frame.Top
    if ($dx -ge 0 -and $dy -ge 0 -and $cw -gt 0 -and $ch -gt 0 -and ($dx + $cw) -le $w -and ($dy + $ch) -le $h) {
        $crop = New-Object System.Drawing.Bitmap $cw, $ch
        $g2 = [System.Drawing.Graphics]::FromImage($crop)
        $g2.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, $cw, $ch), (New-Object System.Drawing.Rectangle $dx, $dy, $cw, $ch), [System.Drawing.GraphicsUnit]::Pixel)
        $g2.Dispose()
        $bmp.Dispose()
        $bmp = $crop
        $r = $frame
        $w = $cw
        $h = $ch
    }
    # A fully uniform frame means the window did not render into the DC.
    $colors = @{}
    $stepX = [Math]::Max(1, [int]($w / 8))
    $stepY = [Math]::Max(1, [int]($h / 8))
    for ($sx = 0; $sx -lt $w; $sx += $stepX) {
        for ($sy = 0; $sy -lt $h; $sy += $stepY) {
            try { $colors[$bmp.GetPixel($sx, $sy).ToArgb()] = 1 } catch {}
        }
    }
    if ($colors.Count -le 1) { $bmp.Dispose(); throw 'PrintWindow returned a blank frame; use capture:screen after activating the window' }
    return @{ bitmap = $bmp; x = $r.Left; y = $r.Top; w = $w; h = $h }
}
function Get-CuWindowShot {
    param([IntPtr]$Hwnd, [string]$Method = 'auto')
    if ($Method -eq 'print') {
        $shot = Capture-CuWindowBitmap $Hwnd
        $shot.method = 'print'
        return $shot
    }
    if ([CuNative]::IsCloaked($Hwnd)) {
        # A cloaked window has no visible pixels; render it instead of copying the screen.
        $shot = Capture-CuWindowBitmap $Hwnd
        $shot.method = 'print'
        return $shot
    }
    if (Activate-CuWindow $Hwnd) {
        Start-Sleep -Milliseconds 200
        $r = [CuNative]::GetFrameBounds($Hwnd)
        $w = $r.Right - $r.Left
        $h = $r.Bottom - $r.Top
        return @{ bitmap = (Capture-CuScreenRect $r.Left $r.Top $w $h); x = $r.Left; y = $r.Top; w = $w; h = $h; method = 'screen' }
    }
    if ($Method -eq 'screen') { throw 'could not bring the window to the foreground; a window screenshot would capture another window' }
    $shot = Capture-CuWindowBitmap $Hwnd
    $shot.method = 'print'
    return $shot
}

# OCR (Windows.Media.Ocr) is initialized lazily on the first ocr request.
$script:OcrReady = $false
$script:AsTaskGeneric = $null

function Initialize-CuOcr {
    if ($script:OcrReady) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime] | Out-Null
    $script:OcrReady = $true
}

function Await-CuOcr {
    param($Operation, [Type]$ResultType)
    $task = $script:AsTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait(15000)) { throw 'OCR operation timed out after 15 s' }
    return $task.Result
}

function Resolve-CuTarget {
    param($A)
    $ref = Get-ArgStr $A 'ref' ''
    if (-not [string]::IsNullOrEmpty($ref)) {
        $h = Get-CuRefWindow $ref
        if ($h -le 0 -or -not [CuNative]::IsWindow([IntPtr]$h)) { throw ('stale ref ' + $ref + ': re-run observe.tree and use the new ref') }
        return [IntPtr]$h
    }
    $hwnd = [int64](Get-ArgInt $A 'hwnd' 0)
    $title = Get-ArgStr $A 'title'
    $rx = Get-ArgStr $A 'titleRegex'
    $procId = Get-ArgInt $A 'processId' 0
    return (Find-CuWindow -Hwnd $hwnd -Title $title -TitleRegex $rx -ProcessId $procId)
}

function Get-CuRole {
    param($Element)
    $role = $Element.Current.ControlType.ProgrammaticName
    if ($role.StartsWith('ControlType.')) { $role = $role.Substring(12) }
    return $role
}

function Get-CuPattern {
    param($Element, $Pattern)
    $obj = $null
    try {
        if ($Element.TryGetCurrentPattern($Pattern, [ref]$obj)) { return $obj }
    } catch {}
    return $null
}

function ConvertTo-CuInt {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 0 }
    return [int]$Value
}

function Get-CuRect {
    param($Element)
    $r = $Element.Current.BoundingRectangle
    return [ordered]@{ x = (ConvertTo-CuInt $r.X); y = (ConvertTo-CuInt $r.Y); w = (ConvertTo-CuInt $r.Width); h = (ConvertTo-CuInt $r.Height) }
}

function Get-CuActions {
    param($Element)
    $actions = @()
    if ((Get-CuPattern $Element ([System.Windows.Automation.InvokePattern]::Pattern)) -ne $null) { $actions += 'invoke' }
    if ((Get-CuPattern $Element ([System.Windows.Automation.ValuePattern]::Pattern)) -ne $null) { $actions += 'setvalue' }
    if ((Get-CuPattern $Element ([System.Windows.Automation.TogglePattern]::Pattern)) -ne $null) { $actions += 'toggle' }
    if ((Get-CuPattern $Element ([System.Windows.Automation.SelectionItemPattern]::Pattern)) -ne $null) { $actions += 'select' }
    if ((Get-CuPattern $Element ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)) -ne $null) { $actions += 'expand' }
    if ((Get-CuPattern $Element ([System.Windows.Automation.ScrollPattern]::Pattern)) -ne $null) { $actions += 'scroll' }
    if ((Get-CuPattern $Element ([System.Windows.Automation.TextPattern]::Pattern)) -ne $null) { $actions += 'text' }
    return $actions
}

function Format-CuName {
    param([string]$Name, [int]$Max = 90)
    if ($null -eq $Name) { return '' }
    $Name = $Name -replace "[`r`n`t]+", ' '
    if ($Name.Length -gt $Max) { $Name = $Name.Substring(0, $Max) + '...' }
    return $Name
}

function Get-CuShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash, 0, 4) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-CuLocator {
    param($Element, [int]$Hwnd, [int]$Nth)
    $role = Get-CuRole $Element
    $name = ''
    $auto = ''
    try { $name = ([string]$Element.Current.Name) -replace '\|', '/' } catch {}
    try { $auto = ([string]$Element.Current.AutomationId) -replace '\|', '/' } catch {}
    return ('hwnd=' + $Hwnd + '|role=' + $role + '|name=' + $name + '|nth=' + $Nth + '|auto=' + $auto)
}

function Register-CuRef {
    param([int]$Hwnd, [string]$Locator)
    $ref = Get-CuShortHash $Locator
    if (-not $script:CuRefs.ContainsKey([int64]$Hwnd)) { $script:CuRefs[[int64]$Hwnd] = @{} }
    $script:CuRefs[[int64]$Hwnd][$ref] = $Locator
    return $ref
}

function Get-CuRefWindow {
    param([string]$Ref)
    foreach ($key in @($script:CuRefs.Keys)) {
        if ($script:CuRefs[$key].ContainsKey($Ref)) { return [int64]$key }
    }
    return 0
}

function Find-CuRefElement {
    param([int64]$Hwnd, [string]$Ref)
    if (-not $script:CuRefs.ContainsKey($Hwnd) -or -not $script:CuRefs[$Hwnd].ContainsKey($Ref)) {
        throw ('stale ref ' + $Ref + ': no observation for this element; re-run observe.tree')
    }
    $locator = [string]$script:CuRefs[$Hwnd][$Ref]
    $map = @{}
    foreach ($part in $locator.Split('|')) {
        $kv = $part.Split('=', 2)
        if ($kv.Count -eq 2) { $map[$kv[0]] = $kv[1] }
    }
    $root = $null
    try { $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd) } catch {}
    if ($null -eq $root) { throw ('stale ref ' + $Ref + ': window is gone') }
    $walk = Get-CuTree -Root $root -MaxDepth 30 -MaxNodes 4000
    $counts = @{}
    $i = 0
    foreach ($el in $walk.elements) {
        $role = Get-CuRole $el
        $name = ''
        $auto = ''
        try { $name = ([string]$el.Current.Name) -replace '\|', '/' } catch {}
        try { $auto = ([string]$el.Current.AutomationId) -replace '\|', '/' } catch {}
        $key = $role + '|' + $name + '|' + $auto
        $nth = 0
        if ($counts.ContainsKey($key)) { $nth = [int]$counts[$key] }
        $counts[$key] = $nth + 1
        if ($role -eq $map['role'] -and $name -eq $map['name'] -and $auto -eq $map['auto'] -and [string]$nth -eq [string]$map['nth']) {
            return @{ el = $el; i = $i }
        }
        $i++
    }
    throw ('stale ref ' + $Ref + ': element is no longer present (role/name/auto/nth changed); re-run observe.tree')
}

function Get-CuTree {
    param($Root, [int]$MaxDepth, [int]$MaxNodes, [switch]$All)
    $walker = if ($All) { $RawView } else { $ControlView }
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Root, 0))
    $rows = New-Object System.Collections.ArrayList
    $truncated = $false
    while ($stack.Count -gt 0) {
        $pair = $stack.Pop()
        $el = $pair[0]
        $depth = $pair[1]
        if ($rows.Count -ge $MaxNodes) { $truncated = $true; break }
        $rows.Add($el) | Out-Null
        if ($depth -ge $MaxDepth) { continue }
        $children = @()
        try {
            $child = $walker.GetFirstChild($el)
            while ($null -ne $child) {
                $children += $child
                $child = $walker.GetNextSibling($child)
            }
        } catch {}
        for ($i = $children.Count - 1; $i -ge 0; $i--) { $stack.Push(@($children[$i], ($depth + 1))) }
    }
    return @{ elements = $rows; truncated = $truncated }
}

function Test-CuPasswordElement {
    param($Element)
    try {
        if ($Element.Current.IsPassword) { return $true }
    } catch {}
    try {
        $h = [IntPtr]$Element.Current.NativeWindowHandle
        if ($h -ne [IntPtr]::Zero -and [CuNative]::IsPasswordWindow($h)) { return $true }
    } catch {}
    return $false
}

function Test-CuConsoleWindow {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return $false }
    $cls = [CuNative]::GetWindowClass($Hwnd)
    return ($cls -match 'ConsoleWindowClass|CASCADIA_HOSTING_WINDOW_CLASS|WindowsTerminal')
}

function Test-CuFocusedPassword {
    try {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused) { return (Test-CuPasswordElement $focused) }
    } catch {}
    return $false
}

function Assert-CuConsequentialAllowed {
    param($A, [string]$What)
    if (Get-ArgBool $A '__allowConsequential' $false) { return }
    $mode = Get-ArgStr $A '__confirmMode' 'deny'
    if ($mode -eq 'allow') { return }
    if ($mode -eq 'ask') {
        $actionText = 'Action: ' + $What
        $detailText = 'This action may change data or perform a consequential operation. Allow it?'
        try {
            $uiStrings = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'indicator\strings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($uiStrings.confirmAction) { $actionText = [string]($uiStrings.confirmAction -f $What) }
            if ($uiStrings.confirmDetail) { $detailText = [string]$uiStrings.confirmDetail }
            if ($What.StartsWith('clicking ')) {
                $actionText = [string]($uiStrings.confirmClick -f $What.Substring(9))
            } elseif ($What -eq 'writing into a password field') {
                $actionText = [string]$uiStrings.confirmPasswordWrite
            } elseif ($What -eq 'typing into a password field') {
                $actionText = [string]$uiStrings.confirmPasswordType
            } elseif ($What -eq 'typing into a terminal/interpreter window') {
                $actionText = [string]$uiStrings.confirmTerminal
            }
        } catch {}
        if (Request-CuConfirmation -Action $actionText -Detail $detailText) { return }
        throw ('consequential action was not approved by the user: ' + $What)
    }
    throw ('consequential action requires pre-authorization: ' + $What + ' is disabled by default; set confirm:"never" for full access or enable the indicator for ask mode')
}

function Get-CuRiskReason {
    param($Element, $A)
    $keywords = @('pay', 'payment', 'purchase', 'buy', 'checkout', 'submit', 'send', 'delete', 'remove', 'uninstall', 'format', 'transfer', 'confirm order')
    $custom = Get-ArgStr $A '__confirmKeywords' ''
    if (-not [string]::IsNullOrEmpty($custom)) {
        foreach ($word in $custom.Split(',')) {
            if (-not [string]::IsNullOrWhiteSpace($word)) { $keywords += $word.Trim().ToLowerInvariant() }
        }
    }
    $name = ''
    try { $name = [string](Get-CuDisplayName $Element 120) } catch {}
    $id = ''
    try { $id = [string]$Element.Current.AutomationId } catch {}
    $hay = ($name + ' ' + $id).ToLowerInvariant()
    foreach ($word in $keywords) { if ($word -and $hay.Contains($word)) { return $word } }
    return ''
}

function Get-CuDisplayName {
    param($Element, [int]$Max = 90)
    try {
        if (Test-CuPasswordElement $Element) { return '[password redacted]' }
        return (Format-CuName $Element.Current.Name $Max)
    } catch {
        return ''
    }
}

function Format-CuRow {
    param($Element, [int]$Index, [switch]$WithPatterns, [string]$Ref = '')
    $cur = $Element.Current
    $role = Get-CuRole $Element
    $name = Get-CuDisplayName $Element 90
    $rect = Get-CuRect $Element
    $sb = New-Object System.Text.StringBuilder
    if ($Ref) { [void]$sb.Append('ref=' + $Ref + ' ') }
    [void]$sb.Append('i=' + $Index + ' ' + $role)
    if ($name.Length -gt 0) { [void]$sb.Append(' "' + $name + '"') }
    $id = $cur.AutomationId
    if (-not [string]::IsNullOrEmpty($id)) { [void]$sb.Append(' #' + $id) }
    if ($rect.w -gt 0 -and $rect.h -gt 0) { [void]$sb.Append(' ' + $rect.x + ',' + $rect.y + ' ' + $rect.w + 'x' + $rect.h) }
    if (-not $cur.IsEnabled) { [void]$sb.Append(' !en') }
    if ($cur.IsOffscreen) { [void]$sb.Append(' off') }
    if ($cur.HasKeyboardFocus) { [void]$sb.Append(' focus') }
    if ($WithPatterns) {
        $actions = @(Get-CuActions $Element)
        if ($actions.Count -gt 0) { [void]$sb.Append(' [' + ($actions -join ',') + ']') }
        $vp = Get-CuPattern $Element ([System.Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $vp) {
            if (Test-CuPasswordElement $Element) {
                [void]$sb.Append(' ="[password redacted]"')
            } else {
                try {
                    $v = $vp.Current.Value
                    if ($null -ne $v -and $v.Length -gt 0) {
                        $v = Format-CuName $v 120
                        [void]$sb.Append(' ="' + $v + '"')
                    }
                } catch {}
            }
        }
        $tg = Get-CuPattern $Element ([System.Windows.Automation.TogglePattern]::Pattern)
        if ($null -ne $tg) { try { [void]$sb.Append(' checked=' + [int]($tg.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On)) } catch {} }
        $si = Get-CuPattern $Element ([System.Windows.Automation.SelectionItemPattern]::Pattern)
        if ($null -ne $si) { try { [void]$sb.Append(' selected=' + [int]$si.Current.IsSelected) } catch {} }
        $tp = Get-CuPattern $Element ([System.Windows.Automation.TextPattern]::Pattern)
        if ($null -ne $tp) {
            try {
                $t = $tp.DocumentRange.GetText(120)
                if ($null -ne $t -and $t.Trim().Length -gt 0) { [void]$sb.Append(' ~"' + (Format-CuName $t 100) + '"') }
            } catch {}
        }
    }
    return $sb.ToString()
}

function New-CuRegex {
    param([string]$Pattern)
    if ($Pattern.Length -gt 200) { throw 'regex pattern is too long (max 200 characters)' }
    return (New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromMilliseconds(200)))
}

function Test-CuMatch {
    param($Element, $A)
    $cur = $Element.Current
    $name = Get-ArgStr $A 'name'
    if (-not [string]::IsNullOrEmpty($name)) {
        $exact = Get-ArgBool $A 'exactName' $false
        if ($exact) { if ([string]$cur.Name -cne $name) { return $false } }
        else { if ([string]$cur.Name -ne $name) { return $false } }
    }
    $nameRx = Get-ArgStr $A 'nameRegex'
    if (-not [string]::IsNullOrEmpty($nameRx)) {
        try { if (-not (New-CuRegex $nameRx).IsMatch([string]$cur.Name)) { return $false } }
        catch { throw ('invalid or too slow nameRegex: ' + $_.Exception.Message) }
    }
    $autoId = Get-ArgStr $A 'automationId'
    if (-not [string]::IsNullOrEmpty($autoId)) {
        if ([string]$cur.AutomationId -ne $autoId) { return $false }
    }
    $ct = Get-ArgStr $A 'controlType'
    if (-not [string]::IsNullOrEmpty($ct)) {
        if ((Get-CuRole $Element) -ne $ct) { return $false }
    }
    return $true
}

function Select-CuElements {
    param($Root, $A, [int]$MaxDepth = 12, [switch]$All)
    $ref = Get-ArgStr $A 'ref' ''
    if (-not [string]::IsNullOrEmpty($ref)) {
        $h = Get-CuRefWindow $ref
        if ($h -le 0) { throw ('stale ref ' + $ref + ': re-run observe.tree and use the new ref') }
        return @(Find-CuRefElement -Hwnd $h -Ref $ref)
    }
    $walk = Get-CuTree -Root $Root -MaxDepth $MaxDepth -MaxNodes 4000 -All:$All
    $wantIndex = Get-Arg $A 'index' $null
    if ($null -ne $wantIndex) { $wantIndex = [int]$wantIndex }
    $matches = @()
    $i = 0
    foreach ($el in $walk.elements) {
        if (($null -eq $wantIndex -or $i -eq $wantIndex) -and (Test-CuMatch $el $A)) { $matches += @{ el = $el; i = $i } }
        $i++
    }
    return $matches
}

function Get-CuResolvedElement {
    param($Root, $A, [switch]$All)
    $hits = @(Select-CuElements -Root $Root -A $A -All:$All)
    if ($hits.Count -eq 0) { throw 'no element matched the selector' }
    $idx = Get-ArgInt $A 'matchIndex' 0
    if ($idx -lt 0 -or $idx -ge $hits.Count) {
        throw ('matchIndex ' + $idx + ' is out of range for ' + $hits.Count + ' matched elements (0..' + ($hits.Count - 1) + ')')
    }
    if ($hits.Count -gt 1 -and $idx -eq 0) {
        $preview = @()
        foreach ($h in ($hits | Select-Object -First 8)) {
            $r = Get-CuRect $h.el
            $preview += ('i=' + $h.i + ' ' + (Get-CuRole $h.el) + ' "' + (Get-CuDisplayName $h.el 40) + '" @' + $r.x + ',' + $r.y)
        }
        $err = [ordered]@{ ok = $false; code = 'ambiguous'; error = "selector matched $($hits.Count) elements; narrow it with controlType/automationId/name or use matchIndex"; matches = $preview }
        return $err
    }
    return $hits[$idx]
}

function Format-CuElementLine {
    param($Element, [int]$Index)
    return (Format-CuRow $Element $Index -WithPatterns:$false)
}

# -------------------------------------------------------------- operations ---

function Invoke-CuOp {
    param([string]$Op, $A)
    Test-CuCancel

    switch ($Op) {
        'windows.list' {
            $limit = [Math]::Min(300, (Get-ArgInt $A 'limit' 60))
            $rows = @(Get-CuWindows -Limit $limit)
            $lines = @()
            foreach ($w in $rows) {
                $line = 'hwnd=' + $w.hwnd + ' pid=' + $w.pid + ' ' + $w.process + ' "' + (Format-CuName $w.title 100) + '" ' + $w.x + ',' + $w.y + ' ' + $w.width + 'x' + $w.height
                if ($w.foreground) { $line += ' fg' }
                if ($w.minimized) { $line += ' min' }
                if ($w.cloaked) { $line += ' cl' }
                $lines += $line
            }
            $m = @(Get-CuScreens)
            $mlines = @()
            foreach ($s in $m) { $mlines += ('monitor=' + $s.index + ' ' + $s.width + 'x' + $s.height + ' at ' + $s.x + ',' + $s.y + ' dpi=' + $s.dpi + ' ' + $s.scale + '%' + $(if ($s.primary) { ' primary' } else { '' })) }
            return [ordered]@{ ok = $true; text = (($lines -join "`n") + "`n" + ($mlines -join "`n")); count = $lines.Count; cursor = (Get-CuCursor) }
        }
        'windows.info' {
            $w = Resolve-CuTarget $A
            $r = [CuNative]::GetFrameBounds($w)
            $procId = 0
            [CuNative]::GetWindowThreadProcessId($w, [ref]$procId) | Out-Null
            $pname = ''
            try { $pname = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}
            $text = 'hwnd=' + [int64]$w + ' pid=' + $procId + ' ' + $pname + ' "' + (Format-CuName ([CuNative]::GetWindowTitle($w)) 120) + '" ' + $r.Left + ',' + $r.Top + ' ' + ($r.Right - $r.Left) + 'x' + ($r.Bottom - $r.Top)
            if ([CuNative]::IsIconic($w)) { $text += ' min' }
            if ([CuNative]::GetForegroundWindow() -eq $w) { $text += ' fg' }
            return [ordered]@{ ok = $true; text = $text }
        }
        'windows.activate' {
            $w = Resolve-CuTarget $A
            $okFg = Activate-CuWindow $w
            $text = 'activated hwnd=' + [int64]$w + ' "' + (Format-CuName ([CuNative]::GetWindowTitle($w)) 100) + '"'
            if (-not $okFg) { return [ordered]@{ ok = $false; code = 'foreground'; error = 'could not bring the window to the foreground (the desktop may be locked or another window is modal)' } }
            return [ordered]@{ ok = $true; text = $text }
        }
        'windows.minimize' {
            $w = Resolve-CuTarget $A
            [CuNative]::ShowWindow($w, 6) | Out-Null
            return [ordered]@{ ok = $true; text = ('minimized hwnd=' + [int64]$w) }
        }
        'windows.maximize' {
            $w = Resolve-CuTarget $A
            [CuNative]::ShowWindow($w, 3) | Out-Null
            return [ordered]@{ ok = $true; text = ('maximized hwnd=' + [int64]$w) }
        }
        'windows.restore' {
            $w = Resolve-CuTarget $A
            [CuNative]::ShowWindow($w, 9) | Out-Null
            return [ordered]@{ ok = $true; text = ('restored hwnd=' + [int64]$w) }
        }
        'windows.close' {
            $w = Resolve-CuTarget $A
            [CuNative]::PostMessage($w, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            $deadline = (Get-Date).AddSeconds(2)
            while ((Get-Date) -lt $deadline) {
                if (-not [CuNative]::IsWindowVisible($w)) { break }
                Start-Sleep -Milliseconds 100
            }
            if (-not [CuNative]::IsWindowVisible($w)) {
                return [ordered]@{ ok = $true; text = ('closed hwnd=' + [int64]$w) }
            }
            return [ordered]@{ ok = $true; text = ('close requested for hwnd=' + [int64]$w + '; window is still visible (a save dialog may be open)') }
        }
        'windows.move' {
            $w = Resolve-CuTarget $A
            $x = Get-ArgInt $A 'x' ([int]::MinValue)
            $y = Get-ArgInt $A 'y' ([int]::MinValue)
            if ($x -eq [int]::MinValue -or $y -eq [int]::MinValue) { throw 'move needs x and y' }
            $cur = [CuNative]::GetFrameBounds($w)
            $w0 = $cur.Right - $cur.Left
            $h0 = $cur.Bottom - $cur.Top
            $width = Get-ArgInt $A 'width' -1
            $height = Get-ArgInt $A 'height' -1
            if ($width -gt 0) { $w0 = $width }
            if ($height -gt 0) { $h0 = $height }
            [CuNative]::SetWindowPos($w, [IntPtr]::Zero, $x, $y, $w0, $h0, 0x0004) | Out-Null
            return [ordered]@{ ok = $true; text = ('moved hwnd=' + [int64]$w + ' to ' + $x + ',' + $y + ' ' + $w0 + 'x' + $h0) }
        }
        'observe.tree' {
            $w = Resolve-CuTarget $A
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($w)
            if ($null -eq $root) { throw 'cannot attach to the window through UI Automation' }
            $maxDepth = [Math]::Min(30, [Math]::Max(0, (Get-ArgInt $A 'maxDepth' 10)))
            $maxNodes = [Math]::Min(1000, [Math]::Max(1, (Get-ArgInt $A 'maxNodes' 200)))
            $all = Get-ArgBool $A 'all' $false
            $withPatterns = -not (Get-ArgBool $A 'noPatterns' $false)
            $walk = Get-CuTree -Root $root -MaxDepth $maxDepth -MaxNodes $maxNodes -All:$all
            $hasSelector = $false
            foreach ($k in 'name', 'nameRegex', 'automationId', 'controlType') { if (-not [string]::IsNullOrEmpty((Get-ArgStr $A $k))) { $hasSelector = $true } }
            $lines = @()
            $i = 0
            $shown = 0
            $counts = @{}
            $script:CuRefs[[int64]$w] = @{}
            foreach ($el in $walk.elements) {
                $role = Get-CuRole $el
                $rawName = ''
                $auto = ''
                try { $rawName = ([string]$el.Current.Name) -replace '\|', '/' } catch {}
                try { $auto = ([string]$el.Current.AutomationId) -replace '\|', '/' } catch {}
                $key = $role + '|' + $rawName + '|' + $auto
                $nth = 0
                if ($counts.ContainsKey($key)) { $nth = [int]$counts[$key] }
                $counts[$key] = $nth + 1
                $locator = Get-CuLocator $el ([int64]$w) $nth
                $ref = Register-CuRef ([int64]$w) $locator
                if ($hasSelector) {
                    if ((Test-CuMatch $el $A) -and $shown -lt $maxNodes) { $lines += (Format-CuRow $el $i -WithPatterns:$withPatterns -Ref $ref); $shown++ }
                } else {
                    $name = $el.Current.Name
                    $isStructural = $role -in @('Window', 'Pane', 'Group', 'Document', 'Tab', 'ToolBar', 'MenuBar', 'List', 'Table', 'Tree')
                    if ((-not [string]::IsNullOrWhiteSpace($name)) -or $isStructural) {
                        $lines += (Format-CuRow $el $i -WithPatterns:$withPatterns -Ref $ref)
                        $shown++
                    }
                }
                $i++
            }
            $header = 'window "' + (Format-CuName ([CuNative]::GetWindowTitle($w)) 100) + '" hwnd=' + [int64]$w + ' elements=' + $shown
            if ($walk.truncated) { $header += ' truncated=1 (raise maxNodes or narrow)' }
            return [ordered]@{ ok = $true; text = ($header + "`n" + ($lines -join "`n")); count = $shown }
        }
        'observe.wait' {
            $timeout = [Math]::Min(60000, [Math]::Max(200, (Get-ArgInt $A 'waitMs' 15000)))
            $deadline = (Get-Date).AddMilliseconds($timeout)
            $started = Get-Date
            $wantHwnd = [int64](Get-ArgInt $A 'hwnd' 0)
            $wantTitle = Get-ArgStr $A 'title' ''
            $wantRegex = Get-ArgStr $A 'titleRegex' ''
            $hasElement = $false
            foreach ($k in 'name', 'nameRegex', 'automationId', 'controlType') { if (-not [string]::IsNullOrEmpty((Get-ArgStr $A $k))) { $hasElement = $true } }
            if (-not $hasElement -and -not $wantTitle -and -not $wantRegex -and $wantHwnd -le 0) {
                throw 'observe.wait needs hwnd, title, titleRegex or an element selector'
            }
            while ((Get-Date) -lt $deadline) {
                Test-CuCancel
                $matched = ''
                if ($wantHwnd -gt 0) {
                    if ([CuNative]::IsWindow([IntPtr]$wantHwnd)) { $matched = 'hwnd=' + $wantHwnd }
                } elseif ($wantTitle -or $wantRegex) {
                    foreach ($w in @(Get-CuWindows -Limit 500)) {
                        $t = [string]$w.title
                        if ($wantTitle -and $t.IndexOf($wantTitle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $matched = 'hwnd=' + $w.hwnd + ' title="' + (Format-CuName $t 100) + '"'
                            break
                        }
                        if ($wantRegex -and $t -match $wantRegex) {
                            $matched = 'hwnd=' + $w.hwnd + ' title="' + (Format-CuName $t 100) + '"'
                            break
                        }
                    }
                }
                if (-not $matched -and $hasElement) {
                    $h = $wantHwnd
                    if ($h -le 0) { $h = [int64][CuNative]::GetForegroundWindow() }
                    if ($h -gt 0) {
                        try {
                            $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h)
                            $hits = @(Select-CuElements -Root $root -A $A)
                            if ($hits.Count -gt 0) {
                                $matched = 'hwnd=' + $h + ' element="' + (Format-CuName ([string]$hits[0].el.Current.Name) 80) + '"'
                            }
                        } catch {}
                    }
                }
                if ($matched) {
                    $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
                    return [ordered]@{ ok = $true; text = ('waited ' + $elapsed + ' ms; matched ' + $matched) }
                }
                Start-Sleep -Milliseconds 250
            }
            throw ('observe.wait timed out after ' + $timeout + ' ms; condition was not met')
        }
        'observe.info' {
            $w = Resolve-CuTarget $A
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($w)
            $hits = @(Select-CuElements -Root $root -A $A)
            if ($hits.Count -eq 0) { throw 'no element matched the selector' }
            $lines = @($hits | ForEach-Object { Format-CuRow $_.el $_.i -WithPatterns })
            return [ordered]@{ ok = $true; text = ($lines -join "`n") }
        }
        'observe.getvalue' {
            $w = Resolve-CuTarget $A
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($w)
            $hit = Get-CuResolvedElement -Root $root -A $A
            if (-not $hit.Contains('el')) { return $hit }
            if (Test-CuPasswordElement $hit.el) {
                return [ordered]@{ ok = $true; text = ('value of i=' + $hit.i + ': [password redacted]'); value = '[password redacted]' }
            }
            $vp = Get-CuPattern $hit.el ([System.Windows.Automation.ValuePattern]::Pattern)
            if ($null -eq $vp) { throw 'element has no value pattern; use observe.gettext or observe.tree' }
            $val = $vp.Current.Value
            return [ordered]@{ ok = $true; text = ('value of i=' + $hit.i + ': ' + (Format-CuName ([string]$val) 2000)); value = [string]$val }
        }
        'observe.gettext' {
            $w = Resolve-CuTarget $A
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($w)
            $hit = Get-CuResolvedElement -Root $root -A $A
            if (-not $hit.Contains('el')) { return $hit }
            if (Test-CuPasswordElement $hit.el) { throw 'password field: text is redacted; type into it instead of reading it' }
            $len = [Math]::Min(20000, [Math]::Max(1, (Get-ArgInt $A 'maxChars' 4000)))
            $tp = Get-CuPattern $hit.el ([System.Windows.Automation.TextPattern]::Pattern)
            if ($null -ne $tp) {
                $txt = [string]$tp.DocumentRange.GetText($len)
                return [ordered]@{ ok = $true; text = ('text of i=' + $hit.i + ":`n" + (Format-CuName $txt 4000)); value = $txt }
            }
            # Clipboard fallback is opt-in: it reads the clipboard and can interrupt a console.
            if (-not (Get-ArgBool $A 'clipboard' $false)) {
                throw 'element has no TextPattern; pass clipboard=true to use the select-all/copy fallback (it reads the clipboard and can interrupt a console)'
            }
            $cls = [CuNative]::GetWindowClass($w)
            if ($cls -match 'Console|CASCADIA') { throw 'clipboard fallback is disabled for console windows (Ctrl+C would interrupt the process)' }
            if (-not (Activate-CuWindow $w)) { throw 'could not activate the window for the clipboard fallback' }
            $old = $null
            try { $old = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch {}
            try {
                $ctrl = 0x11; $a = 0x41; $c = 0x43
                [CuNative]::Key([uint16]$ctrl, $false)
                [CuNative]::Key([uint16]$a, $false)
                [CuNative]::Key([uint16]$a, $true)
                [CuNative]::Key([uint16]$ctrl, $true)
                Start-Sleep -Milliseconds 120
                [CuNative]::Key([uint16]$ctrl, $false)
                [CuNative]::Key([uint16]$c, $false)
                [CuNative]::Key([uint16]$c, $true)
                [CuNative]::Key([uint16]$ctrl, $true)
                Start-Sleep -Milliseconds 250
                $copied = ''
                try { $copied = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch {}
                if ($null -ne $old -and $copied -eq $old) { throw 'clipboard did not change; the copy failed and the previous clipboard content is not returned' }
                if ([string]::IsNullOrEmpty($copied)) { throw 'no TextPattern and the clipboard fallback returned no text' }
                if ($copied.Length -gt $len) { $copied = $copied.Substring(0, $len) }
                return [ordered]@{ ok = $true; text = ('text of i=' + $hit.i + ' (clipboard):' + "`n" + (Format-CuName $copied 4000)); value = $copied }
            } finally {
                if ($null -ne $old) { try { Set-Clipboard -Value $old } catch {} }
            }        }
        default { break }
    }
    return $null
}

function Invoke-CuAct {
    param([string]$Action, $A)
    Test-CuCancel
    $w = Resolve-CuTarget $A
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($w)
    $hit = Get-CuResolvedElement -Root $root -A $A
    if (-not $hit.Contains('el')) { return $hit }
    $el = $hit.el
    $role = Get-CuRole $el
    $name = Get-CuDisplayName $el 60
    $desc = 'i=' + $hit.i + ' ' + $role + ' "' + $name + '"'
    $act = $Action
    if (@('invoke', 'click', 'doubleclick') -contains $act) {
        $risk = Get-CuRiskReason $el $A
        if (-not [string]::IsNullOrEmpty($risk)) {
            Assert-CuConsequentialAllowed $A ('clicking "' + $name + '" (keyword: ' + $risk + ')')
        }
    }
    switch ($act) {
        'invoke' {
            $p = Get-CuPattern $el ([System.Windows.Automation.InvokePattern]::Pattern)
            if ($null -eq $p) { throw 'element has no invoke pattern; use act.click' }
            $p.Invoke()
            Start-Sleep -Milliseconds 180
            return [ordered]@{ ok = $true; text = ('invoked ' + $desc) }
        }
        'click' {
            if (-not (Activate-CuWindow $w)) { throw 'could not bring the window to the foreground; refusing to send a blind click' }
            $r = Get-CuRect $el
            if ($r.w -le 0 -or $r.h -le 0) { throw 'element has no clickable rectangle' }
            $cx = [int]($r.x + $r.w / 2)
            $cy = [int]($r.y + $r.h / 2)
            [CuNative]::MouseMove($cx, $cy)
            Start-Sleep -Milliseconds 40
            [CuNative]::MouseButton([CuNative]::MOUSEEVENTF_LEFTDOWN, [CuNative]::MOUSEEVENTF_LEFTUP)
            Start-Sleep -Milliseconds 180
            return [ordered]@{ ok = $true; text = ('clicked ' + $desc + ' at ' + $cx + ',' + $cy) }
        }
        'doubleclick' {
            if (-not (Activate-CuWindow $w)) { throw 'could not bring the window to the foreground; refusing to send a blind click' }
            $r = Get-CuRect $el
            $cx = [int]($r.x + $r.w / 2); $cy = [int]($r.y + $r.h / 2)
            [CuNative]::MouseMove($cx, $cy)
            Start-Sleep -Milliseconds 40
            foreach ($n in 1..2) { [CuNative]::MouseButton([CuNative]::MOUSEEVENTF_LEFTDOWN, [CuNative]::MOUSEEVENTF_LEFTUP); Start-Sleep -Milliseconds 70 }
            return [ordered]@{ ok = $true; text = ('double-clicked ' + $desc + ' at ' + $cx + ',' + $cy) }
        }
        'rightclick' {
            if (-not (Activate-CuWindow $w)) { throw 'could not bring the window to the foreground; refusing to send a blind click' }
            $r = Get-CuRect $el
            $cx = [int]($r.x + $r.w / 2); $cy = [int]($r.y + $r.h / 2)
            [CuNative]::MouseMove($cx, $cy)
            Start-Sleep -Milliseconds 40
            [CuNative]::MouseButton([CuNative]::MOUSEEVENTF_RIGHTDOWN, [CuNative]::MOUSEEVENTF_RIGHTUP)
            Start-Sleep -Milliseconds 180
            return [ordered]@{ ok = $true; text = ('right-clicked ' + $desc + ' at ' + $cx + ',' + $cy) }
        }
        'setvalue' {
            if (Test-CuPasswordElement $el) { Assert-CuConsequentialAllowed $A 'writing into a password field' }
            $p = Get-CuPattern $el ([System.Windows.Automation.ValuePattern]::Pattern)
            if ($null -eq $p) { throw 'element has no value pattern; click it and use input.type' }
            $value = Get-ArgStr $A 'value'
            if ($null -eq $value) { throw 'setvalue needs a value' }
            $p.SetValue($value)
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('set value of ' + $desc) }
        }
        'toggle' {
            $p = Get-CuPattern $el ([System.Windows.Automation.TogglePattern]::Pattern)
            if ($null -eq $p) { throw 'element has no toggle pattern' }
            $p.Toggle()
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('toggled ' + $desc + ' now ' + [string]$p.Current.ToggleState) }
        }
        'select' {
            $p = Get-CuPattern $el ([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($null -eq $p) { throw 'element has no selection item pattern' }
            $p.Select()
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('selected ' + $desc) }
        }
        'expand' {
            $p = Get-CuPattern $el ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -eq $p) { throw 'element has no expand-collapse pattern' }
            $p.Expand()
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('expanded ' + $desc) }
        }
        'collapse' {
            $p = Get-CuPattern $el ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -eq $p) { throw 'element has no expand-collapse pattern' }
            $p.Collapse()
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('collapsed ' + $desc) }
        }
        'focus' {
            if (-not (Activate-CuWindow $w)) { throw 'could not bring the window to the foreground; refusing to focus an element blindly' }
            $el.SetFocus()
            Start-Sleep -Milliseconds 100
            return [ordered]@{ ok = $true; text = ('focused ' + $desc) }
        }
        'scroll' {
            if (-not (Activate-CuWindow $w)) { throw 'could not bring the window to the foreground; refusing to send a blind scroll' }
            $r = Get-CuRect $el
            $cx = [int]($r.x + $r.w / 2); $cy = [int]($r.y + $r.h / 2)
            [CuNative]::MouseMove($cx, $cy)
            Start-Sleep -Milliseconds 40
            $delta = Get-ArgInt $A 'delta' -600
            [CuNative]::MouseWheel($delta)
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('scrolled ' + $delta + ' over ' + $desc) }
        }
        default { throw "unknown act '$Action' (invoke|click|doubleclick|rightclick|setvalue|toggle|select|expand|collapse|focus|scroll)" }
    }
}

function Invoke-CuInput {
    param([string]$Action, $A)
    Test-CuCancel
    $act = $Action
    if ($act -eq 'click') { $act = 'mouse' }
    if ($act -eq 'doubleclick') { $act = 'mouse'; $Clicks = 2 }
    if ($act -eq 'rightclick') { $act = 'mouse'; $Button = 'right' }
    if ($act -eq 'middleclick') { $act = 'mouse'; $Button = 'middle' }
    if (-not $Clicks) { $Clicks = Get-ArgInt $A 'clicks' 1 }
    if (-not $Button) { $Button = Get-ArgStr $A 'button' 'left' }
    $hwnd = [int64](Get-ArgInt $A 'hwnd' 0)
    $title = Get-ArgStr $A 'title'
    $rx = Get-ArgStr $A 'titleRegex'
    $procId = Get-ArgInt $A 'processId' 0
    $targetWindow = [IntPtr]::Zero
    if ($hwnd -gt 0 -or -not [string]::IsNullOrEmpty($title) -or -not [string]::IsNullOrEmpty($rx) -or $procId -gt 0) {
        $targetWindow = Find-CuWindow -Hwnd $hwnd -Title $title -TitleRegex $rx -ProcessId $procId
        if (-not (Activate-CuWindow $targetWindow)) { throw 'could not bring the target window to the foreground; refusing to send input blindly' }
    }
    if (@('type', 'paste', 'key', 'hotkey') -contains $act) {
        if ($targetWindow -ne [IntPtr]::Zero -and (Test-CuConsoleWindow $targetWindow)) {
            Assert-CuConsequentialAllowed $A 'typing into a terminal/interpreter window'
        }
        if (Test-CuFocusedPassword) { Assert-CuConsequentialAllowed $A 'typing into a password field' }
    }
    $X = Get-ArgInt $A 'x' 0
    $Y = Get-ArgInt $A 'y' 0
    switch ($act) {
        'move' { [CuNative]::MouseMove($X, $Y); Start-Sleep -Milliseconds 50; return [ordered]@{ ok = $true; text = ('moved cursor to ' + $X + ',' + $Y) } }
        'mouse' {
            [CuNative]::MouseMove($X, $Y)
            Start-Sleep -Milliseconds 40
            $down = [CuNative]::MOUSEEVENTF_LEFTDOWN; $up = [CuNative]::MOUSEEVENTF_LEFTUP
            if ($Button -eq 'right') { $down = [CuNative]::MOUSEEVENTF_RIGHTDOWN; $up = [CuNative]::MOUSEEVENTF_RIGHTUP }
            elseif ($Button -eq 'middle') { $down = [CuNative]::MOUSEEVENTF_MIDDLEDOWN; $up = [CuNative]::MOUSEEVENTF_MIDDLEUP }
            for ($n = 1; $n -le [Math]::Max(1, $Clicks); $n++) { [CuNative]::MouseButton($down, $up); if ($n -lt $Clicks) { Start-Sleep -Milliseconds 80 } }
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('clicked ' + $Button + ' x' + $Clicks + ' at ' + $X + ',' + $Y) }
        }
        'drag' {
            $x2 = Get-ArgInt $A 'x2' 0
            $y2 = Get-ArgInt $A 'y2' 0
            [CuNative]::MouseMove($X, $Y)
            Start-Sleep -Milliseconds 60
            [CuNative]::MouseDown([CuNative]::MOUSEEVENTF_LEFTDOWN)
            for ($s = 1; $s -le 14; $s++) {
                [CuNative]::MouseMove([int]($X + (($x2 - $X) * $s / 14)), [int]($Y + (($y2 - $Y) * $s / 14)))
                Start-Sleep -Milliseconds 15
            }
            [CuNative]::MouseUp([CuNative]::MOUSEEVENTF_LEFTUP)
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('dragged ' + $X + ',' + $Y + ' -> ' + $x2 + ',' + $y2) }
        }
        'scroll' {
            [CuNative]::MouseMove($X, $Y)
            Start-Sleep -Milliseconds 40
            $delta = Get-ArgInt $A 'delta' -600
            [CuNative]::MouseWheel($delta)
            Start-Sleep -Milliseconds 150
            return [ordered]@{ ok = $true; text = ('scrolled ' + $delta + ' at ' + $X + ',' + $Y) }
        }
        'type' {
            $text = Get-ArgStr $A 'text'
            if ([string]::IsNullOrEmpty($text)) { throw 'type needs text' }
            if ($text.Length -gt 2000) { throw 'text is too long for input.type (max 2000 characters); use input.paste' }
            $chunks = [regex]::Split($text, "\r?\n")
            for ($ci = 0; $ci -lt $chunks.Count; $ci++) {
                foreach ($ch in $chunks[$ci].ToCharArray()) { [CuNative]::UnicodeChar($ch); Start-Sleep -Milliseconds 4 }
                if ($ci -lt $chunks.Count - 1) {
                    [CuNative]::Key([uint16]0x0D, $false)
                    [CuNative]::Key([uint16]0x0D, $true)
                    Start-Sleep -Milliseconds 25
                }
            }
            Start-Sleep -Milliseconds 80
            return [ordered]@{ ok = $true; text = ('typed ' + $text.Length + ' characters') }
        }
        'key' {
            $key = Get-ArgStr $A 'key'
            if ([string]::IsNullOrEmpty($key)) { throw 'key needs a key name' }
            $vk = Resolve-CuVk $key
            [CuNative]::Key([uint16]$vk, $false)
            Start-Sleep -Milliseconds 30
            [CuNative]::Key([uint16]$vk, $true)
            Start-Sleep -Milliseconds 100
            return [ordered]@{ ok = $true; text = ('pressed ' + $key) }
        }
        'hotkey' {
            $hotkey = Get-ArgStr $A 'hotkey'
            if ([string]::IsNullOrEmpty($hotkey)) { throw 'hotkey needs a combination' }
            $vks = @()
            foreach ($p in @($hotkey -split '\+')) { $vks += (Resolve-CuVk $p) }
            foreach ($v in $vks) { [CuNative]::Key([uint16]$v, $false); Start-Sleep -Milliseconds 25 }
            for ($i = $vks.Count - 1; $i -ge 0; $i--) { [CuNative]::Key([uint16]$vks[$i], $true); Start-Sleep -Milliseconds 25 }
            Start-Sleep -Milliseconds 120
            return [ordered]@{ ok = $true; text = ('pressed ' + $hotkey) }
        }
        'paste' {
            $text = Get-ArgStr $A 'text'
            if ([string]::IsNullOrEmpty($text)) { throw 'paste needs text' }
            if ($text.Length -gt 20000) { throw 'text is too long for input.paste (max 20000 characters)' }
            $oldClip = $null
            try { $oldClip = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch {}
            try {
                Set-Clipboard -Value $text
                Start-Sleep -Milliseconds 60
                $ctrl = Resolve-CuVk 'ctrl'; $v = Resolve-CuVk 'v'
                [CuNative]::Key([uint16]$ctrl, $false)
                [CuNative]::Key([uint16]$v, $false)
                Start-Sleep -Milliseconds 30
                [CuNative]::Key([uint16]$v, $true)
                [CuNative]::Key([uint16]$ctrl, $true)
                Start-Sleep -Milliseconds 250
            } finally {
                if ($null -ne $oldClip) { try { Set-Clipboard -Value $oldClip } catch {} }
            }
            return [ordered]@{ ok = $true; text = ('pasted ' + $text.Length + ' characters') }
        }
        'wait' {
            $ms = [Math]::Min(10000, [Math]::Max(0, (Get-ArgInt $A 'ms' 500)))
            $deadline = (Get-Date).AddMilliseconds($ms)
            while ((Get-Date) -lt $deadline) {
                Test-CuCancel
                Start-Sleep -Milliseconds 100
            }
            return [ordered]@{ ok = $true; text = ('waited ' + $ms + ' ms') }
        }
        'cursor' {
            $c = Get-CuCursor
            $fgTitle = [CuNative]::GetWindowTitle([CuNative]::GetForegroundWindow())
            return [ordered]@{ ok = $true; text = ('cursor ' + $c.x + ',' + $c.y + ' foreground "' + (Format-CuName $fgTitle 100) + '"') }
        }
        default { throw "unknown input '$Action' (move|click|doubleclick|rightclick|middleclick|drag|scroll|type|key|hotkey|paste|wait|cursor)" }
    }
}

function Assert-CuExpectedWindow {
    param($A)
    $expected = [int64](Get-ArgInt $A 'expectedWindow' 0)
    if ($expected -le 0) { return }
    $fg = [int64][CuNative]::GetForegroundWindow()
    if ($fg -ne $expected) {
        $title = ''
        try { $title = [CuNative]::GetWindowTitle([IntPtr]$fg) } catch {}
        throw ('expectedWindow=' + $expected + ' but foreground is hwnd=' + $fg + ' title="' + (Format-CuName $title 100) + '"; re-observe before capturing')
    }
}

function Invoke-CuScreenshot {
    param($A)
    Test-CuCancel
    Assert-CuExpectedWindow $A
    $screens = @(Get-CuScreens)
    $wSel = $false
    foreach ($k in 'hwnd', 'title', 'titleRegex', 'processId') { $v = Get-Arg $A $k $null; if ($null -ne $v -and "$v" -ne '' -and "$v" -ne '0') { $wSel = $true } }
    $region = Get-ArgStr $A 'region'
    $method = Get-ArgStr $A 'capture' 'auto'
    $shot = $null
    $label = ''
    if (-not [string]::IsNullOrEmpty($region)) {
        $parts = $region -split ','
        if ($parts.Count -ne 4) { throw 'region must be "x,y,width,height"' }
        $srcX = [int]$parts[0]; $srcY = [int]$parts[1]; $srcW = [int]$parts[2]; $srcH = [int]$parts[3]
        Assert-CuScreenRect $srcX $srcY $srcW $srcH
        $shot = @{ bitmap = (Capture-CuScreenRect $srcX $srcY $srcW $srcH); x = $srcX; y = $srcY; w = $srcW; h = $srcH; method = 'screen' }
        $label = 'region:' + $region
    } elseif ($wSel) {
        $w = Resolve-CuTarget $A
        $shot = Get-CuWindowShot $w $method
        $label = [CuNative]::GetWindowTitle($w)
    } else {
        $mon = Get-ArgInt $A 'monitor' -1
        if ($mon -ge 0) {
            if ($mon -ge $screens.Count) { throw "monitor $mon not found" }
            $s = $screens[$mon]
        } else { $s = @($screens | Where-Object { $_.primary })[0] }
        $srcX = $s.x; $srcY = $s.y; $srcW = $s.width; $srcH = $s.height
        $shot = @{ bitmap = (Capture-CuScreenRect $srcX $srcY $srcW $srcH); x = $srcX; y = $srcY; w = $srcW; h = $srcH; method = 'screen' }
        $label = 'monitor:' + $s.index
    }
    $srcX = $shot.x; $srcY = $shot.y; $srcW = $shot.w; $srcH = $shot.h
    $bmp = $shot.bitmap
    if ($srcW -le 0 -or $srcH -le 0) { throw 'empty capture rectangle' }
    $maxWidth = Get-ArgInt $A 'maxWidth' 1400
    $scale = 1.0
    $outW = $srcW; $outH = $srcH
    if ($maxWidth -gt 0 -and $srcW -gt $maxWidth) {
        $scale = [double]$maxWidth / [double]$srcW
        $outW = $maxWidth
        $outH = [int][Math]::Round($srcH * $scale)
        $resized = New-Object System.Drawing.Bitmap $outW, $outH
        $g2 = [System.Drawing.Graphics]::FromImage($resized)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g2.DrawImage($bmp, 0, 0, $outW, $outH)
        $g2.Dispose(); $bmp.Dispose(); $bmp = $resized
    }
    $path = Get-ArgStr $A 'path'
    if ([string]::IsNullOrEmpty($path)) {
        $path = Join-Path $TempDir ('shot-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.png')
    } else {
        $full = [IO.Path]::GetFullPath($path)
        $root = [IO.Path]::GetFullPath($TempDir).TrimEnd('\') + '\'
        if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'screenshot path must be inside the computer-use temp dir'
        }
        $path = $full
    }
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Clear-CuTemp
    $modeText = ''
    if ($shot.method -eq 'print') { $modeText = ' via PrintWindow' }
    $text = 'screenshot ' + $outW + 'x' + $outH + ' px from ' + $srcW + 'x' + $srcH + ' (' + $label + ')' + $modeText + '; source origin ' + $srcX + ',' + $srcY + '; scale ' + [Math]::Round($scale, 3)
    return [ordered]@{
        ok = $true; text = $text; path = (Resolve-Path $path).Path
        width = $outW; height = $outH; sourceWidth = $srcW; sourceHeight = $srcH
        scale = [Math]::Round($scale, 4); sourceX = $srcX; sourceY = $srcY
    }
}

function Invoke-CuOcr {
    param($A)
    Test-CuCancel
    Assert-CuExpectedWindow $A
    Initialize-CuOcr
    $screens = @(Get-CuScreens)
    $wSel = $false
    foreach ($k in 'hwnd', 'title', 'titleRegex', 'processId') { $v = Get-Arg $A $k $null; if ($null -ne $v -and "$v" -ne '' -and "$v" -ne '0') { $wSel = $true } }
    $region = Get-ArgStr $A 'region'
    $method = Get-ArgStr $A 'capture' 'auto'
    $shot = $null
    $label = ''
    $evalImage = Get-ArgStr $A '_image' ''
    if (-not [string]::IsNullOrEmpty($evalImage)) {
        if ($env:DSH_CU_OCR_EVAL -ne '1') { throw 'ocr _image is a development-only option; it is disabled in production' }
        if (-not (Test-Path $evalImage)) { throw ('ocr image not found: ' + $evalImage) }
        $img = [System.Drawing.Image]::FromFile($evalImage)
        try {
            $srcW = $img.Width; $srcH = $img.Height
            $bmp = New-Object System.Drawing.Bitmap $img
        } finally { $img.Dispose() }
        $shot = @{ bitmap = $bmp; x = 0; y = 0; w = $srcW; h = $srcH; method = 'file' }
        $label = 'file:' + [IO.Path]::GetFileName($evalImage)
    } elseif (-not [string]::IsNullOrEmpty($region)) {
        $parts = $region -split ','
        if ($parts.Count -ne 4) { throw 'region must be "x,y,width,height"' }
        $srcX = [int]$parts[0]; $srcY = [int]$parts[1]; $srcW = [int]$parts[2]; $srcH = [int]$parts[3]
        Assert-CuScreenRect $srcX $srcY $srcW $srcH
        $shot = @{ bitmap = (Capture-CuScreenRect $srcX $srcY $srcW $srcH); x = $srcX; y = $srcY; w = $srcW; h = $srcH; method = 'screen' }
        $label = 'region:' + $region
    } elseif ($wSel) {
        $w = Resolve-CuTarget $A
        $shot = Get-CuWindowShot $w $method
        $label = [CuNative]::GetWindowTitle($w)
    } else {
        $mon = Get-ArgInt $A 'monitor' -1
        if ($mon -ge 0) {
            if ($mon -ge $screens.Count) { throw "monitor $mon not found" }
            $s = $screens[$mon]
        } else { $s = @($screens | Where-Object { $_.primary })[0] }
        $srcX = $s.x; $srcY = $s.y; $srcW = $s.width; $srcH = $s.height
        $shot = @{ bitmap = (Capture-CuScreenRect $srcX $srcY $srcW $srcH); x = $srcX; y = $srcY; w = $srcW; h = $srcH; method = 'screen' }
        $label = 'monitor:' + $s.index
    }
    $srcX = $shot.x; $srcY = $shot.y; $srcW = $shot.w; $srcH = $shot.h
    $bmp = $shot.bitmap
    if ($srcW -le 0 -or $srcH -le 0) { throw 'empty capture rectangle' }
    $scale = Get-ArgFloat $A 'ocrScale' 2.0
    if ($scale -le 0) { $scale = 1.0 }
    if ($scale -gt 3) { throw 'ocrScale must be <= 3' }
    # Windows.Media.Ocr rejects images whose longest side exceeds 10 000 px.
    # A 4K window at ocrScale 3 would otherwise fail the whole action.
    $maxDim = [Math]::Max($srcW, $srcH)
    $clamped = $false
    if ($maxDim -gt 0 -and ($maxDim * $scale) -gt 10000) {
        $scale = [Math]::Max(0.05, 10000.0 / $maxDim)
        $clamped = $true
    }
    if ($scale -ne 1.0) {
        $outW = [int][Math]::Round($srcW * $scale)
        $outH = [int][Math]::Round($srcH * $scale)
        $resized = New-Object System.Drawing.Bitmap $outW, $outH
        $g2 = [System.Drawing.Graphics]::FromImage($resized)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g2.DrawImage($bmp, 0, 0, $outW, $outH)
        $g2.Dispose(); $bmp.Dispose(); $bmp = $resized
    }
    $path = Join-Path $TempDir ('ocr-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.png')
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Clear-CuTemp
    $engine = $null
    $langTag = Get-ArgStr $A 'ocrLang' ''
    if (-not [string]::IsNullOrEmpty($langTag)) {
        try {
            $lang = New-Object Windows.Globalization.Language $langTag
            $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
        } catch {}
    }
    if ($null -eq $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    if ($null -eq $engine) { throw 'no Windows OCR engine is available for the requested language' }
    $file = Await-CuOcr ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await-CuOcr ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await-CuOcr ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $big = Await-CuOcr ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Await-CuOcr ($engine.RecognizeAsync($big)) ([Windows.Media.Ocr.OcrResult])
    $boxes = Get-ArgBool $A 'ocrBoxes' $true
    $maxLines = [Math]::Min(500, [Math]::Max(1, (Get-ArgInt $A 'maxLines' 120)))
    $lines = @()
    foreach ($line in @($result.Lines)) {
        if ($lines.Count -ge $maxLines) { break }
        $textLine = [string]$line.Text
        if ($boxes) {
            $minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = 0.0; $maxY = 0.0
            foreach ($word in @($line.Words)) {
                $wr = $word.BoundingRect
                if ($wr.X -lt $minX) { $minX = $wr.X }
                if ($wr.Y -lt $minY) { $minY = $wr.Y }
                if (($wr.X + $wr.Width) -gt $maxX) { $maxX = $wr.X + $wr.Width }
                if (($wr.Y + $wr.Height) -gt $maxY) { $maxY = $wr.Y + $wr.Height }
            }
            if ($minX -eq [double]::MaxValue) { $minX = 0; $minY = 0 }
            $bx = [int]($minX / $scale + $srcX)
            $by = [int]($minY / $scale + $srcY)
            $bw = [int](($maxX - $minX) / $scale)
            $bh = [int](($maxY - $minY) / $scale)
            $lines += ('[' + $bx + ',' + $by + ',' + $bw + 'x' + $bh + '] ' + (Format-CuName $textLine 200))
        } else {
            $lines += (Format-CuName $textLine 200)
        }
    }
    $header = 'ocr ' + $srcW + 'x' + $srcH + ' ' + $label + ' lang=' + $engine.RecognizerLanguage.LanguageTag + ' lines=' + $lines.Count + ' scale=' + $scale
    if ($clamped) { $header += ' clamped=1' }
    return [ordered]@{ ok = $true; text = ($header + "`n" + ($lines -join "`n")); path = (Resolve-Path $path).Path; lines = $lines.Count }
}

function Invoke-CuLaunch {
    param($A)
    Test-CuCancel
    $target = Get-ArgStr $A 'target'
    if ([string]::IsNullOrEmpty($target)) { throw 'launch needs a target (executable, file, folder, or URL)' }
    $leaf = [IO.Path]::GetFileName($target).ToLowerInvariant()
    $deny = @('cmd', 'cmd.exe', 'powershell', 'powershell.exe', 'pwsh', 'pwsh.exe', 'wscript', 'wscript.exe', 'cscript', 'cscript.exe', 'mshta', 'mshta.exe', 'regsvr32', 'regsvr32.exe', 'rundll32', 'rundll32.exe', 'certutil', 'certutil.exe', 'bitsadmin', 'bitsadmin.exe', 'msiexec', 'msiexec.exe', 'wmic', 'wmic.exe', 'schtasks', 'schtasks.exe', 'reg', 'reg.exe')
    if ($deny -contains $leaf) { throw ('launch of "' + $target + '" is blocked by policy: interpreter and shell binaries are not allowed') }
    if ($target.StartsWith('\\')) { throw 'UNC targets are not allowed' }
    if ($target -match '^[A-Za-z]:[\\/]') { }
    elseif ($target -match '^(https?|mailto):') { }
    elseif ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:') { throw ('URL scheme is not allowed: ' + $target) }
    $argLine = Get-ArgStr $A 'args'
    $waitMs = [Math]::Min(10000, [Math]::Max(0, (Get-ArgInt $A 'waitMs' 800)))
    $proc = $null
    if ($target -match '^https?://|^mailto:') {
        Start-Process $target | Out-Null
    } elseif ([string]::IsNullOrEmpty($argLine)) {
        $proc = Start-Process -FilePath $target -PassThru
    } else {
        $proc = Start-Process -FilePath $target -ArgumentList $argLine -PassThru
    }
    if ($waitMs -gt 0) { Start-Sleep -Milliseconds $waitMs }
    $pid2 = 0
    if ($null -ne $proc) { $pid2 = $proc.Id }
    $text = 'launched "' + $target + '"'
    if ($pid2 -gt 0) { $text += ' pid=' + $pid2 }
    $title = Get-ArgStr $A 'waitForTitle'
    if (-not [string]::IsNullOrEmpty($title)) {
        $launchTime = (Get-Date).AddSeconds(-2)
        $deadline = (Get-Date).AddMilliseconds([Math]::Max(6000, ($waitMs + 4000)))
        $found = $null
        $fallback = $null
        while ((Get-Date) -lt $deadline) {
            $cands = @(Get-CuWindows -Limit 300 | Where-Object { $_.title -like "*$title*" })
            foreach ($cand in $cands) {
                $ownPid = $false
                if ($pid2 -gt 0 -and $cand.pid -eq $pid2) { $ownPid = $true }
                $isNew = $false
                try {
                    $p = Get-Process -Id $cand.pid -ErrorAction Stop
                    $isNew = ($p.StartTime -gt $launchTime)
                } catch {}
                if (-not ($ownPid -or $isNew)) { if ($null -eq $fallback) { $fallback = $cand }; continue }
                # A freshly started app may publish a transient frame window first;
                # accept only a window that is still there a moment later.
                Start-Sleep -Milliseconds 400
                $again = @(Get-CuWindows -Limit 300 | Where-Object { $_.hwnd -eq $cand.hwnd -and $_.title -like "*$title*" })
                if ($again.Count -gt 0) { $found = $again[0]; break }
            }
            if ($null -ne $found) { break }
            Start-Sleep -Milliseconds 200
        }
        if ($null -ne $found) {
            $text += ' window hwnd=' + $found.hwnd + ' "' + (Format-CuName $found.title 80) + '"'
        } elseif ($null -ne $fallback) {
            $text += ' window hwnd=' + $fallback.hwnd + ' "' + (Format-CuName $fallback.title 80) + '" (existing window, not a new process: verify with computer_windows list before typing)'
        } else {
            $text += ' (window with that title not found; call computer_windows list)'
        }
    }
    return [ordered]@{ ok = $true; text = $text; pid = $pid2 }
}

# -------------------------------------------------------------- VK table -----

$script:VK = @{
    'backspace' = 0x08; 'tab' = 0x09; 'enter' = 0x0D; 'return' = 0x0D; 'shift' = 0x10; 'ctrl' = 0x11; 'control' = 0x11;
    'alt' = 0x12; 'pause' = 0x13; 'capslock' = 0x14; 'esc' = 0x1B; 'escape' = 0x1B; 'space' = 0x20; 'pageup' = 0x21;
    'pgup' = 0x21; 'pagedown' = 0x22; 'pgdn' = 0x22; 'end' = 0x23; 'home' = 0x24; 'left' = 0x25; 'arrowleft' = 0x25;
    'up' = 0x26; 'arrowup' = 0x26; 'right' = 0x27; 'arrowright' = 0x27; 'down' = 0x28; 'arrowdown' = 0x28;
    'printscreen' = 0x2C; 'prtsc' = 0x2C; 'insert' = 0x2D; 'ins' = 0x2D; 'delete' = 0x2E; 'del' = 0x2E;
    'win' = 0x5B; 'lwin' = 0x5B; 'apps' = 0x5D; 'numlock' = 0x90; 'scrolllock' = 0x91;
    'semicolon' = 0xBA; 'equals' = 0xBB; 'comma' = 0xBC; 'minus' = 0xBD; 'period' = 0xBE; 'slash' = 0xBF;
    'grave' = 0xC0; 'lbracket' = 0xDB; 'backslash' = 0xDC; 'rbracket' = 0xDD; 'quote' = 0xDE
}
foreach ($n in 1..24) { $script:VK["f$n"] = 0x6F + $n }
foreach ($c in 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z') {
    $script:VK[$c] = 0x41 + [int][char]$c - 97
}

function Resolve-CuVk {
    param([string]$Name)
    $k = $Name.Trim().ToLowerInvariant()
    if ($script:VK.ContainsKey($k)) { return [int]$script:VK[$k] }
    if ($k.Length -eq 1) { return [int][char]($k.ToUpperInvariant()[0]) }
    throw "unknown key name '$Name'"
}

function Invoke-CuDiagnostics {
    param($A)
    $ps = $PSVersionTable.PSVersion.ToString()
    $uia = 'ok'
    try { [void][System.Windows.Automation.AutomationElement]::RootElement } catch { $uia = 'error: ' + $_.Exception.Message }
    $ocr = 'not initialized'
    try {
        Initialize-CuOcr
        $langs = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
        if ($langs.Count -eq 0) { $ocr = 'no recognizer languages' } else { $ocr = ($langs -join ',') }
    } catch { $ocr = 'error: ' + $_.Exception.Message }
    $monitors = @(Get-CuScreens | ForEach-Object { $_.width.ToString() + 'x' + $_.height.ToString() + '@' + $_.x.ToString() + ',' + $_.y.ToString() + ' dpi=' + $_.dpi.ToString() })
    $writable = $false
    try {
        $probe = Join-Path $TempDir ('.diag-' + $PID + '-' + (Get-Random))
        [IO.File]::WriteAllText($probe, 'ok')
        Remove-Item $probe -Force
        $writable = $true
    } catch {}
    $indicatorDir = Join-Path $TempDir 'indicator'
    $indicator = 'off'
    if (Test-Path (Join-Path $indicatorDir 'ready')) { $indicator = 'ready' }
    if (Test-Path (Join-Path $indicatorDir 'cancel')) { $indicator = 'cancelled' }
    $mode = Get-ArgStr $A '__mode' 'auto'
    $lines = @(
        'powershell=' + $ps,
        'uia=' + $uia,
        'ocr=' + $ocr,
        'monitors=' + ($monitors -join '; '),
        'temp=' + $TempDir + ' writable=' + $writable,
        'indicator=' + $indicator,
        'mode=' + $mode
    )
    return [ordered]@{ ok = $true; text = ($lines -join "`n"); powershell = $ps; uia = $uia; ocr = $ocr; mode = $mode }
}

# ---------------------------------------------------------------- main loop ---

function Write-CuResponse {
    param($Response)
    $json = $Response | ConvertTo-Json -Depth 8 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

# Announce readiness once so the plugin can detect a healthy host.
Write-CuResponse ([ordered]@{ id = 0; ok = $true; text = 'ready'; pid = $PID })

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line.Length -eq 0) { continue }
    $req = $null
    try { $req = $line | ConvertFrom-Json } catch { Write-CuResponse ([ordered]@{ id = 0; ok = $false; code = 'bad-request'; error = 'invalid JSON request' }); continue }
    $id = Get-ArgInt $req 'id' 0
    $op = Get-ArgStr $req 'op'
    $argsObj = Get-Arg $req 'args' $null
    Touch-CuIndicator
    try {
        $result = $null
        if ($op -like 'windows.*') { $result = Invoke-CuOp -Op $op -A $argsObj }
        elseif ($op -like 'observe.*') { $result = Invoke-CuOp -Op $op -A $argsObj }
        elseif ($op -like 'act.*') { $result = Invoke-CuAct -Action $op.Substring(4) -A $argsObj }
        elseif ($op -like 'input.*') { $result = Invoke-CuInput -Action $op.Substring(6) -A $argsObj }
        elseif ($op -eq 'screenshot') { $result = Invoke-CuScreenshot -A $argsObj }
        elseif ($op -eq 'ocr') { $result = Invoke-CuOcr -A $argsObj }
        elseif ($op -eq 'launch') { $result = Invoke-CuLaunch -A $argsObj }
        elseif ($op -eq 'diagnostics') { $result = Invoke-CuDiagnostics -A $argsObj }
        else { throw "unknown op '$op'" }
        if ($null -eq $result) { throw "op '$op' is not implemented" }
        if ($op -match '^(windows\.|observe\.|act\.|input\.|launch$|screenshot$|ocr$|diagnostics$)') {
            $target = [ordered]@{}
            foreach ($k in 'hwnd', 'title', 'titleRegex', 'processId', 'name', 'automationId', 'controlType', 'action', 'target', 'region', 'monitor', 'key', 'hotkey', 'x', 'y', 'delta', 'button', 'capture') {
                $v = Get-Arg $argsObj $k $null
                if ($null -ne $v) { $target[$k] = $v }
            }
            if ($op -eq 'input.type' -or $op -eq 'input.paste') {
                $target['chars'] = ([string](Get-Arg $argsObj 'text' '')).Length
            }
            if ($op -eq 'launch') {
                $target['argsChars'] = ([string](Get-Arg $argsObj 'args' '')).Length
            }
            if ($result.Contains('path')) { $target['path'] = $result['path'] }
            Write-CuAudit -Action $op -Target $target -Ok ([bool]$result.ok)
        }
        $result.id = $id
        Write-CuResponse $result
    } catch {
        try {
            $msg = [string]$_.Exception.Message
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
            Write-CuAudit -Action $op -Target ([ordered]@{ error = $msg }) -Ok $false
        } catch {}
        Write-CuResponse ([ordered]@{ id = $id; ok = $false; code = 'error'; error = [string]$_.Exception.Message })
    }
}






















