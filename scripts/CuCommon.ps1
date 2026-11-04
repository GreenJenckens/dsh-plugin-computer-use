# CuCommon.ps1 - shared helpers for the DSH computer-use skill.
# Windows PowerShell 5.1 compatible. Dot-source from the other scripts.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('CuNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CuNative
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;

    public const int SM_XVIRTUALSCREEN = 76;
    public const int SM_YVIRTUALSCREEN = 77;
    public const int SM_CXVIRTUALSCREEN = 78;
    public const int SM_CYVIRTUALSCREEN = 79;

    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    public static string GetWindowTitle(IntPtr hWnd)
    {
        int len = GetWindowTextLength(hWnd);
        if (len <= 0) return "";
        StringBuilder sb = new StringBuilder(len + 2);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string GetWindowClass(IntPtr hWnd)
    {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static void SetDpiAware()
    {
        try { if (SetProcessDpiAwareness(2) == 0) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    public static RECT GetFrameBounds(IntPtr hwnd)
    {
        RECT r;
        try
        {
            if (DwmGetWindowAttribute(hwnd, 9, out r, Marshal.SizeOf(typeof(RECT))) == 0) return r;
        }
        catch { }
        GetWindowRect(hwnd, out r);
        return r;
    }

    public static void MouseMove(int x, int y)
    {
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (vw < 2) vw = 2;
        if (vh < 2) vh = 2;
        int ax = (int)Math.Round((x - vx) * 65535.0 / (vw - 1));
        int ay = (int)Math.Round((y - vy) * 65535.0 / (vh - 1));
        INPUT inp = new INPUT();
        inp.type = INPUT_MOUSE;
        inp.u.mi.dx = ax;
        inp.u.mi.dy = ay;
        inp.u.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
        INPUT[] arr = new INPUT[] { inp };
        SendInput(1, arr, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void MouseButton(uint downFlag, uint upFlag)
    {
        INPUT down = new INPUT(); down.type = INPUT_MOUSE; down.u.mi.dwFlags = downFlag;
        INPUT up = new INPUT(); up.type = INPUT_MOUSE; up.u.mi.dwFlags = upFlag;
        INPUT[] arr = new INPUT[] { down, up };
        SendInput(2, arr, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void MouseDown(uint flag)
    {
        INPUT down = new INPUT(); down.type = INPUT_MOUSE; down.u.mi.dwFlags = flag;
        INPUT[] arr = new INPUT[] { down };
        SendInput(1, arr, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void MouseUp(uint flag)
    {
        INPUT up = new INPUT(); up.type = INPUT_MOUSE; up.u.mi.dwFlags = flag;
        INPUT[] arr = new INPUT[] { up };
        SendInput(1, arr, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void MouseWheel(int delta)
    {
        INPUT inp = new INPUT();
        inp.type = INPUT_MOUSE;
        inp.u.mi.mouseData = unchecked((uint)delta);
        inp.u.mi.dwFlags = MOUSEEVENTF_WHEEL;
        INPUT[] arr = new INPUT[] { inp };
        SendInput(1, arr, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Key(ushort vk, bool up)
    {
        INPUT inp = new INPUT();
        inp.type = INPUT_KEYBOARD;
        inp.u.ki.wVk = vk;
        inp.u.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        INPUT[] arr = new INPUT[] { inp };
        SendInput(1, arr, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void UnicodeChar(char ch)
    {
        INPUT down = new INPUT(); down.type = INPUT_KEYBOARD;
        down.u.ki.wScan = ch;
        down.u.ki.dwFlags = KEYEVENTF_UNICODE;
        INPUT up = new INPUT(); up.type = INPUT_KEYBOARD;
        up.u.ki.wScan = ch;
        up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        INPUT[] arr = new INPUT[] { down, up };
        SendInput(2, arr, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
}

[CuNative]::SetDpiAware() | Out-Null

function Write-CuResult {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine($json)
}

function New-CuError {
    param([string]$Message, [string]$Code = 'error')
    return [ordered]@{ ok = $false; code = $Code; error = $Message }
}

function Get-CuCursor {
    $p = New-Object CuNative+POINT
    [CuNative]::GetCursorPos([ref]$p) | Out-Null
    return [ordered]@{ x = $p.X; y = $p.Y }
}

function Get-CuScreens {
    $list = @()
    $i = 0
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $list += [ordered]@{
            index      = $i
            primary    = $s.Primary
            deviceName = $s.DeviceName
            x          = $s.Bounds.X
            y          = $s.Bounds.Y
            width      = $s.Bounds.Width
            height     = $s.Bounds.Height
        }
        $i++
    }
    return $list
}

function Get-CuWindows {
    param([int]$Limit = 80)
    $fg = [CuNative]::GetForegroundWindow()
    $script:cuWinRows = @()
    $cb = {
        param([IntPtr]$h, [IntPtr]$l)
        if ([CuNative]::IsWindowVisible($h)) {
            $title = [CuNative]::GetWindowTitle($h)
            if (-not [string]::IsNullOrWhiteSpace($title)) {
                $r = New-Object CuNative+RECT
                [CuNative]::GetWindowRect($h, [ref]$r) | Out-Null
                $w = $r.Right - $r.Left
                $hh = $r.Bottom - $r.Top
                if ($w -gt 40 -and $hh -gt 40) {
                    $procId = 0
                    [CuNative]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
                    $pname = ''
                    try { $pname = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}
                    $script:cuWinRows += [ordered]@{
                        hwnd       = [int64]$h
                        pid        = $procId
                        process    = $pname
                        title      = $title
                        class      = [CuNative]::GetWindowClass($h)
                        x          = $r.Left
                        y          = $r.Top
                        width      = $w
                        height     = $hh
                        foreground = ($h -eq $fg)
                        minimized  = [CuNative]::IsIconic($h)
                    }
                }
            }
        }
        return $true
    }
    $del = [CuNative+EnumWindowsProc]$cb
    [CuNative]::EnumWindows($del, [IntPtr]::Zero) | Out-Null
    $sel = @($script:cuWinRows)
    $fgRows = @($sel | Where-Object { $_.foreground })
    $rest = @($sel | Where-Object { -not $_.foreground })
    $ordered = @($fgRows + $rest)
    if ($ordered.Count -gt $Limit) { $ordered = $ordered[0..($Limit - 1)] }
    return $ordered
}

function Find-CuWindow {
    param([string]$Title, [string]$TitleRegex, [int64]$Hwnd = 0, [int]$ProcessId = 0, [switch]$Foreground)
    if ($Hwnd -gt 0) {
        if (-not [CuNative]::IsWindowVisible([IntPtr]$Hwnd)) { throw "window hwnd $Hwnd is not visible" }
        return [IntPtr]$Hwnd
    }
    if ($Foreground) { return [CuNative]::GetForegroundWindow() }
    $candidates = Get-CuWindows -Limit 500
    if (-not [string]::IsNullOrWhiteSpace($TitleRegex)) {
        $rx = New-Object System.Text.RegularExpressions.Regex($TitleRegex, 'IgnoreCase')
        $hit = @($candidates | Where-Object { $rx.IsMatch($_.title) })
    } elseif (-not [string]::IsNullOrWhiteSpace($Title)) {
        $hit = @($candidates | Where-Object { $_.title -like "*$Title*" })
    } elseif ($ProcessId -gt 0) {
        $hit = @($candidates | Where-Object { $_.pid -eq $ProcessId })
    } else {
        return [CuNative]::GetForegroundWindow()
    }
    if ($hit.Count -eq 0) { throw "no visible window matched the selector" }
    if ($hit.Count -gt 1) {
        $names = ($hit | ForEach-Object { '"' + $_.title + '" (hwnd=' + $_.hwnd + ')' }) -join ', '
        throw "ambiguous window selector, matched $($hit.Count): $names"
    }
    return [IntPtr]$hit[0].hwnd
}

function Activate-CuWindow {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { throw 'no window to activate' }
    if ([CuNative]::IsIconic($Hwnd)) {
        [CuNative]::ShowWindow($Hwnd, 9) | Out-Null
        Start-Sleep -Milliseconds 150
    }
    if ([CuNative]::GetForegroundWindow() -eq $Hwnd) { return $true }

    # A tap of ALT releases Windows' foreground lock for this process.
    [CuNative]::Key([uint16]0x12, $false)
    [CuNative]::Key([uint16]0x12, $true)
    Start-Sleep -Milliseconds 40

    $targetThread = [CuNative]::GetWindowThreadProcessId($Hwnd, [ref]$null)
    $selfThread = [CuNative]::GetCurrentThreadId()
    [CuNative]::AttachThreadInput($selfThread, $targetThread, $true) | Out-Null
    [CuNative]::BringWindowToTop($Hwnd) | Out-Null
    [CuNative]::SetForegroundWindow($Hwnd) | Out-Null
    [CuNative]::SetFocus($Hwnd) | Out-Null
    [CuNative]::AttachThreadInput($selfThread, $targetThread, $false) | Out-Null
    Start-Sleep -Milliseconds 150

    if ([CuNative]::GetForegroundWindow() -ne $Hwnd) {
        [CuNative]::SwitchToThisWindow($Hwnd, $true)
        Start-Sleep -Milliseconds 200
    }
    return ([CuNative]::GetForegroundWindow() -eq $Hwnd)
}
