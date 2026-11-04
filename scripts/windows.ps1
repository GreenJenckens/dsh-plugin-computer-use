param(
    [string]$Action = 'list',
    [int64]$Hwnd = 0,
    [string]$Title,
    [string]$TitleRegex,
    [int]$ProcessId = 0,
    [int]$X = -2147483648,
    [int]$Y = -2147483648,
    [int]$Width = -1,
    [int]$Height = -1,
    [int]$Limit = 80
)

. "$PSScriptRoot\CuCommon.ps1"

try {
    switch ($Action.ToLowerInvariant()) {
        'list' {
            $rows = @(Get-CuWindows -Limit $Limit)
            Write-CuResult ([ordered]@{ ok = $true; count = $rows.Count; windows = $rows; monitors = @(Get-CuScreens) })
        }
        'info' {
            $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
            $r = [CuNative]::GetFrameBounds($w)
            $procId = 0
            [CuNative]::GetWindowThreadProcessId($w, [ref]$procId) | Out-Null
            $pname = ''
            try { $pname = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}
            Write-CuResult ([ordered]@{
                ok         = $true
                hwnd       = [int64]$w
                pid        = $procId
                process    = $pname
                title      = [CuNative]::GetWindowTitle($w)
                class      = [CuNative]::GetWindowClass($w)
                rect       = [ordered]@{ x = $r.Left; y = $r.Top; width = ($r.Right - $r.Left); height = ($r.Bottom - $r.Top) }
                minimized  = [CuNative]::IsIconic($w)
                foreground = ([CuNative]::GetForegroundWindow() -eq $w)
            })
        }
        'activate' {
            $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
            Activate-CuWindow $w | Out-Null
            Start-Sleep -Milliseconds 80
            Write-CuResult ([ordered]@{ ok = $true; hwnd = [int64]$w; title = [CuNative]::GetWindowTitle($w); foreground = ([CuNative]::GetForegroundWindow() -eq $w) })
        }
        'minimize' {
            $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
            [CuNative]::ShowWindow($w, 6) | Out-Null
            Write-CuResult ([ordered]@{ ok = $true; hwnd = [int64]$w; minimized = [CuNative]::IsIconic($w) })
        }
        'maximize' {
            $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
            [CuNative]::ShowWindow($w, 3) | Out-Null
            Write-CuResult ([ordered]@{ ok = $true; hwnd = [int64]$w })
        }
        'restore' {
            $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
            [CuNative]::ShowWindow($w, 9) | Out-Null
            Write-CuResult ([ordered]@{ ok = $true; hwnd = [int64]$w })
        }
        'close' {
            $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
            $WM_CLOSE = 0x0010
            [CuNative]::PostMessage($w, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            Start-Sleep -Milliseconds 250
            Write-CuResult ([ordered]@{ ok = $true; hwnd = [int64]$w; visible = [CuNative]::IsWindowVisible($w) })
        }
        'move' {
            $w = Find-CuWindow -Hwnd $Hwnd -Title $Title -TitleRegex $TitleRegex -ProcessId $ProcessId
            if ($X -eq -2147483648 -or $Y -eq -2147483648) { throw 'move needs -X and -Y (and optionally -Width/-Height)' }
            $cur = [CuNative]::GetFrameBounds($w)
            $w0 = $cur.Right - $cur.Left; $h0 = $cur.Bottom - $cur.Top
            if ($Width -gt 0) { $w0 = $Width }
            if ($Height -gt 0) { $h0 = $Height }
            $SWP_NOZORDER = 0x0004
            [CuNative]::SetWindowPos($w, [IntPtr]::Zero, $X, $Y, $w0, $h0, $SWP_NOZORDER) | Out-Null
            $r = [CuNative]::GetFrameBounds($w)
            Write-CuResult ([ordered]@{ ok = $true; hwnd = [int64]$w; rect = [ordered]@{ x = $r.Left; y = $r.Top; width = ($r.Right - $r.Left); height = ($r.Bottom - $r.Top) } })
        }
        default { throw "unknown action '$Action' (list|info|activate|minimize|maximize|restore|close|move)" }
    }
} catch {
    Write-CuResult (New-CuError $_.Exception.Message)
    exit 1
}


