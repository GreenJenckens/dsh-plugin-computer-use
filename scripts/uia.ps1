param(
    [string]$Action = 'tree',
    [int64]$Hwnd = 0,
    [string]$Title,
    [string]$TitleRegex,
    [int]$ProcessId = 0,
    [string]$Name,
    [string]$NameRegex,
    [string]$AutomationId,
    [string]$ControlType,
    [int]$MatchIndex = 0,
    [int]$MaxDepth = 10,
    [int]$MaxNodes = 200,
    [switch]$All,
    [switch]$NoPatterns,
    [string]$Value
)

. "$PSScriptRoot\CuCommon.ps1"

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function ConvertTo-CuInt {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 0 }
    return [int]$Value
}

$ControlView = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$RawView = [System.Windows.Automation.TreeWalker]::RawViewWalker

function Get-CuPattern {
    param($Element, $Pattern)
    $obj = $null
    try {
        if ($Element.TryGetCurrentPattern($Pattern, [ref]$obj)) { return $obj }
    } catch {}
    return $null
}

function Get-CuElementInfo {
    param($Element, [int]$Index = -1, [switch]$WithPatterns)
    $cur = $Element.Current
    $role = $cur.ControlType.ProgrammaticName
    if ($role.StartsWith('ControlType.')) { $role = $role.Substring(12) }
    $rect = $cur.BoundingRectangle
    $name = $cur.Name
    if ($null -eq $name) { $name = '' }
    if ($name.Length -gt 160) { $name = $name.Substring(0, 160) + '...' }
    $row = [ordered]@{
        i        = $Index
        role     = $role
        name     = $name
        id       = $cur.AutomationId
        class    = $cur.ClassName
        enabled  = $cur.IsEnabled
        offscreen = $cur.IsOffscreen
        focus    = $cur.HasKeyboardFocus
        x        = (ConvertTo-CuInt $rect.X)
        y        = (ConvertTo-CuInt $rect.Y)
        w        = (ConvertTo-CuInt $rect.Width)
        h        = (ConvertTo-CuInt $rect.Height)
    }
    if ($WithPatterns) {
        $actions = @()
        if ((Get-CuPattern $Element ([System.Windows.Automation.InvokePattern]::Pattern)) -ne $null) { $actions += 'invoke' }
        if ((Get-CuPattern $Element ([System.Windows.Automation.ValuePattern]::Pattern)) -ne $null) { $actions += 'setvalue' }
        if ((Get-CuPattern $Element ([System.Windows.Automation.TogglePattern]::Pattern)) -ne $null) { $actions += 'toggle' }
        if ((Get-CuPattern $Element ([System.Windows.Automation.SelectionItemPattern]::Pattern)) -ne $null) { $actions += 'select' }
        if ((Get-CuPattern $Element ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)) -ne $null) { $actions += 'expand' }
        if ((Get-CuPattern $Element ([System.Windows.Automation.ScrollPattern]::Pattern)) -ne $null) { $actions += 'scroll' }
        if ($actions.Count -gt 0) { $row.actions = $actions }
        $vp = Get-CuPattern $Element ([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp -ne $null) {
            try {
                $v = $vp.Current.Value
                if ($null -ne $v) {
                    if ($v.Length -gt 240) { $v = $v.Substring(0, 240) + '...' }
                    $row.value = $v
                }
            } catch {}
        }
        $tg = Get-CuPattern $Element ([System.Windows.Automation.TogglePattern]::Pattern)
        if ($tg -ne $null) { try { $row.checked = ($tg.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) } catch {} }
        $si = Get-CuPattern $Element ([System.Windows.Automation.SelectionItemPattern]::Pattern)
        if ($si -ne $null) { try { $row.selected = $si.Current.IsSelected } catch {} }
        $tp = Get-CuPattern $Element ([System.Windows.Automation.TextPattern]::Pattern)
        if ($tp -ne $null) {
            $actions += 'text'
            $row.actions = $actions
            try {
                $txt = $tp.DocumentRange.GetText(240)
                if ($null -ne $txt -and $txt.Length -gt 0) { $row.text = $txt }
            } catch {}
        }
    }
    return $row
}

function Get-CuElements {
    param($Root, [int]$MaxDepth, [int]$MaxNodes, [switch]$All)
    $walker = if ($All) { $RawView } else { $ControlView }
    $rows = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Root, 0))
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
        for ($i = $children.Count - 1; $i -ge 0; $i--) {
            $stack.Push(@($children[$i], ($depth + 1)))
        }
    }
    return @{ elements = $rows; truncated = $truncated }
}

function Test-CuMatch {
    param($Row)
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        if ($Row.name -ne $Name) { return $false }
    }
    if (-not [string]::IsNullOrWhiteSpace($NameRegex)) {
        if (-not [regex]::IsMatch($Row.name, $NameRegex, 'IgnoreCase')) { return $false }
    }
    if (-not [string]::IsNullOrWhiteSpace($AutomationId)) {
        if ($Row.id -ne $AutomationId) { return $false }
    }
    if (-not [string]::IsNullOrWhiteSpace($ControlType)) {
        if ($Row.role -ne $ControlType) { return $false }
    }
    return $true
}

try {
    $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($w)
    if ($null -eq $root) { throw 'cannot attach to the window through UI Automation' }
    $winTitle = [CuNative]::GetWindowTitle($w)

    $needle = -not ([string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($NameRegex) -and
        [string]::IsNullOrWhiteSpace($AutomationId) -and [string]::IsNullOrWhiteSpace($ControlType))

    $walk = Get-CuElements -Root $root -MaxDepth $MaxDepth -MaxNodes ($(if ($Action -eq 'tree') { $MaxNodes } else { 4000 })) -All:$All

    $items = @()
    $idx = 0
    foreach ($el in $walk.elements) {
        $info = $null
        try { $info = Get-CuElementInfo -Element $el -Index $idx -WithPatterns:(-not $NoPatterns) } catch { $idx++; continue }
        $items += [pscustomobject]@{ idx = $idx; info = $info; el = $el }
        $idx++
    }

    switch ($Action.ToLowerInvariant()) {
        'tree' {
            $out = @()
            foreach ($it in $items) {
                if ($needle -and -not (Test-CuMatch $it.info)) { continue }
                if (-not $needle) {
                    $named = -not [string]::IsNullOrWhiteSpace($it.info.name)
                    $structural = ($it.info.role -in @('Window', 'Pane', 'Group', 'Document', 'Tab', 'ToolBar', 'MenuBar', 'List', 'Table', 'Tree'))
                    if (-not ($named -or $structural)) { continue }
                }
                $out += $it.info
            }
            $top = @($out | Select-Object -First $MaxNodes)
            Write-CuResult ([ordered]@{
                ok        = $true
                hwnd      = [int64]$w
                window    = $winTitle
                count     = $top.Count
                truncated = ($out.Count -gt $top.Count)
                elements  = $top
            })
        }
        'info' {
            Write-CuResult ([ordered]@{ ok = $true; hwnd = [int64]$w; window = $winTitle; elements = ($items | ForEach-Object { $_.info }) })
        }
        'getvalue' {
            $hit = @($items | Where-Object { Test-CuMatch $_.info })
            if ($hit.Count -eq 0) { throw 'no element matched the selector' }
            $it = $hit[[Math]::Min($MatchIndex, $hit.Count - 1)]
            $vp = Get-CuPattern $it.el ([System.Windows.Automation.ValuePattern]::Pattern)
            if ($null -eq $vp) { throw "element '$($it.info.name)' has no value pattern" }
            Write-CuResult ([ordered]@{ ok = $true; element = $it.info; value = $vp.Current.Value })
        }
        'gettext' {
            $hit = @($items | Where-Object { Test-CuMatch $_.info })
            if ($hit.Count -eq 0) { throw 'no element matched the selector' }
            $it = $hit[[Math]::Min($MatchIndex, $hit.Count - 1)]
            $len = 4000
            if ($null -ne $Value -and $Value -match '^\d+$') { $len = [int]$Value }
            $tp = Get-CuPattern $it.el ([System.Windows.Automation.TextPattern]::Pattern)
            if ($null -ne $tp) {
                Write-CuResult ([ordered]@{ ok = $true; via = 'textpattern'; element = @{ i = $it.info.i; role = $it.info.role; name = $it.info.name }; text = $tp.DocumentRange.GetText($len) })
                exit 0
            }
            # Fallback for controls without TextPattern: focus, select all, copy, read clipboard.
            if (-not (Activate-CuWindow $w)) { throw 'could not activate the window for the clipboard fallback' }
            $old = $null
            try { $old = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch {}
            $vkA = 0x41; $vkC = 0x43; $vkCtrl = 0x11
            [CuNative]::Key([uint16]$vkCtrl, $false)
            [CuNative]::Key([uint16]$vkA, $false)
            [CuNative]::Key([uint16]$vkA, $true)
            [CuNative]::Key([uint16]$vkCtrl, $true)
            Start-Sleep -Milliseconds 120
            [CuNative]::Key([uint16]$vkCtrl, $false)
            [CuNative]::Key([uint16]$vkC, $false)
            [CuNative]::Key([uint16]$vkC, $true)
            [CuNative]::Key([uint16]$vkCtrl, $true)
            Start-Sleep -Milliseconds 250
            $copied = ''
            try { $copied = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch {}
            if ($null -ne $old) { try { Set-Clipboard -Value $old } catch {} }
            if ([string]::IsNullOrEmpty($copied)) { throw 'no TextPattern and the clipboard fallback returned no text' }
            if ($copied.Length -gt $len) { $copied = $copied.Substring(0, $len) }
            Write-CuResult ([ordered]@{ ok = $true; via = 'clipboard'; element = @{ i = $it.info.i; role = $it.info.role; name = $it.info.name }; text = $copied })
        }
        default {
            $hit = @($items | Where-Object { Test-CuMatch $_.info })
            if ($hit.Count -eq 0) { throw 'no element matched the selector' }
            if ($hit.Count -gt 1 -and $MatchIndex -eq 0) {
                $preview = @($hit | Select-Object -First 8 | ForEach-Object { [ordered]@{ i = $_.info.i; role = $_.info.role; name = $_.info.name; x = $_.info.x; y = $_.info.y; w = $_.info.w; h = $_.info.h } })
                Write-CuResult ([ordered]@{ ok = $false; code = 'ambiguous'; error = "selector matched $($hit.Count) elements; add -ControlType, or use -MatchIndex or click coordinates"; matches = $preview })
                exit 1
            }
            $it = $hit[[Math]::Min($MatchIndex, $hit.Count - 1)]
            $el = $it.el
            $desc = [ordered]@{ i = $it.info.i; role = $it.info.role; name = $it.info.name }
            if ($Action.ToLowerInvariant() -in @('click', 'doubleclick', 'rightclick')) {
                if (-not (Activate-CuWindow $w)) {
                    throw 'could not bring the target window to the foreground; refusing to send a blind click'
                }
            }
            switch ($Action.ToLowerInvariant()) {
                'invoke' {
                    $p = Get-CuPattern $el ([System.Windows.Automation.InvokePattern]::Pattern)
                    if ($null -eq $p) { throw "element '$($it.info.name)' has no invoke pattern" }
                    $p.Invoke()
                    Start-Sleep -Milliseconds 200
                    Write-CuResult ([ordered]@{ ok = $true; action = 'invoke'; element = $desc })
                }
                'click' {
                    $cx = [int]($it.info.x + ($it.info.w / 2))
                    $cy = [int]($it.info.y + ($it.info.h / 2))
                    if ($it.info.w -le 0 -or $it.info.h -le 0) { throw 'element has no clickable rectangle; use input.ps1 with coordinates' }
                    [CuNative]::MouseMove($cx, $cy)
                    Start-Sleep -Milliseconds 30
                    [CuNative]::MouseButton([CuNative]::MOUSEEVENTF_LEFTDOWN, [CuNative]::MOUSEEVENTF_LEFTUP)
                    Start-Sleep -Milliseconds 200
                    Write-CuResult ([ordered]@{ ok = $true; action = 'click'; element = $desc; x = $cx; y = $cy })
                }
                'doubleclick' {
                    $cx = [int]($it.info.x + ($it.info.w / 2))
                    $cy = [int]($it.info.y + ($it.info.h / 2))
                    [CuNative]::MouseMove($cx, $cy)
                    foreach ($n in 1..2) {
                        [CuNative]::MouseButton([CuNative]::MOUSEEVENTF_LEFTDOWN, [CuNative]::MOUSEEVENTF_LEFTUP)
                        Start-Sleep -Milliseconds 60
                    }
                    Start-Sleep -Milliseconds 200
                    Write-CuResult ([ordered]@{ ok = $true; action = 'doubleclick'; element = $desc; x = $cx; y = $cy })
                }
                'rightclick' {
                    $cx = [int]($it.info.x + ($it.info.w / 2))
                    $cy = [int]($it.info.y + ($it.info.h / 2))
                    [CuNative]::MouseMove($cx, $cy)
                    [CuNative]::MouseButton([CuNative]::MOUSEEVENTF_RIGHTDOWN, [CuNative]::MOUSEEVENTF_RIGHTUP)
                    Start-Sleep -Milliseconds 200
                    Write-CuResult ([ordered]@{ ok = $true; action = 'rightclick'; element = $desc; x = $cx; y = $cy })
                }
                'setvalue' {
                    $p = Get-CuPattern $el ([System.Windows.Automation.ValuePattern]::Pattern)
                    if ($null -eq $p) { throw "element '$($it.info.name)' has no value pattern; use click + input.ps1 type" }
                    if ($null -eq $Value) { throw 'setvalue needs -Value' }
                    $p.SetValue([string]$Value)
                    Start-Sleep -Milliseconds 150
                    if (-not $p.Current.IsReadOnly) { }
                    Write-CuResult ([ordered]@{ ok = $true; action = 'setvalue'; element = $desc })
                }
                'toggle' {
                    $p = Get-CuPattern $el ([System.Windows.Automation.TogglePattern]::Pattern)
                    if ($null -eq $p) { throw "element '$($it.info.name)' has no toggle pattern" }
                    $p.Toggle()
                    Start-Sleep -Milliseconds 150
                    Write-CuResult ([ordered]@{ ok = $true; action = 'toggle'; element = $desc; state = [string]$p.Current.ToggleState })
                }
                'select' {
                    $p = Get-CuPattern $el ([System.Windows.Automation.SelectionItemPattern]::Pattern)
                    if ($null -eq $p) { throw "element '$($it.info.name)' has no selection item pattern" }
                    $p.Select()
                    Start-Sleep -Milliseconds 150
                    Write-CuResult ([ordered]@{ ok = $true; action = 'select'; element = $desc })
                }
                'expand' {
                    $p = Get-CuPattern $el ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                    if ($null -eq $p) { throw "element '$($it.info.name)' has no expand-collapse pattern" }
                    $p.Expand()
                    Start-Sleep -Milliseconds 150
                    Write-CuResult ([ordered]@{ ok = $true; action = 'expand'; element = $desc; state = [string]$p.Current.ExpandCollapseState })
                }
                'collapse' {
                    $p = Get-CuPattern $el ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                    if ($null -eq $p) { throw "element '$($it.info.name)' has no expand-collapse pattern" }
                    $p.Collapse()
                    Start-Sleep -Milliseconds 150
                    Write-CuResult ([ordered]@{ ok = $true; action = 'collapse'; element = $desc; state = [string]$p.Current.ExpandCollapseState })
                }
                'focus' {
                    $el.SetFocus()
                    Start-Sleep -Milliseconds 100
                    Write-CuResult ([ordered]@{ ok = $true; action = 'focus'; element = $desc })
                }
                'scroll' {
                    $cx = [int]($it.info.x + ($it.info.w / 2))
                    $cy = [int]($it.info.y + ($it.info.h / 2))
                    [CuNative]::MouseMove($cx, $cy)
                    $delta = -600
                    if ($null -ne $Value -and $Value -match '^-?\d+$') { $delta = [int]$Value }
                    [CuNative]::MouseWheel($delta)
                    Start-Sleep -Milliseconds 150
                    Write-CuResult ([ordered]@{ ok = $true; action = 'scroll'; element = $desc; delta = $delta })
                }
                default { throw "unknown action '$Action' (tree|info|getvalue|gettext|invoke|click|doubleclick|rightclick|setvalue|toggle|select|expand|collapse|focus|scroll)" }
            }
        }
    }
} catch {
    $err = New-CuError $_.Exception.Message
    $err.detail = [string]$_.InvocationInfo.PositionMessage
    Write-CuResult $err
    exit 1
}



