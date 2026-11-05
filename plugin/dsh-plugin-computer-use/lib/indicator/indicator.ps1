param(
    [string]$StateDir = (Join-Path $env:TEMP 'dsh-cu\indicator')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$strings = Get-Content (Join-Path $PSScriptRoot 'strings.json') -Raw -Encoding UTF8 | ConvertFrom-Json

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class CuNoActivateForm : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT
            cp.ExStyle |= 0x00080000; // WS_EX_LAYERED
            return cp;
        }
    }
}

public class CuHotkeyForm : Form
{
    public const int WM_HOTKEY = 0x0312;
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public event EventHandler Hotkey;
    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        RegisterHotKey(this.Handle, 1, 0x0002 | 0x0001 | 0x0004, 0x51); // Ctrl+Alt+Shift+Q
    }
    protected override void OnHandleDestroyed(EventArgs e)
    {
        UnregisterHotKey(this.Handle, 1);
        base.OnHandleDestroyed(e);
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && Hotkey != null) Hotkey(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$readyPath = Join-Path $StateDir 'ready'
$activePath = Join-Path $StateDir 'active'
$cancelPath = Join-Path $StateDir 'cancel'
$requestPath = Join-Path $StateDir 'confirm-request.json'
$responsePath = Join-Path $StateDir 'confirm-response.json'

# One overlay per state dir. A dead pid does not block a restart.
if (Test-Path $readyPath) {
    try {
        $old = Get-Content $readyPath -Raw | ConvertFrom-Json
        if ($old.pid -and (Get-Process -Id $old.pid -ErrorAction SilentlyContinue)) { exit 0 }
    } catch {}
}

$script:dialogId = ''
$script:dialogStarted = $null
$script:lastActive = 0
$script:visibility = 0.0
$script:cancel = $false

function Write-JsonFile {
    param([string]$Path, $Object)
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
    Move-Item -Force $tmp $Path
}

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

function Set-RoundedRegion {
    param($Control, [int]$Radius)
    $d = $Radius * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc(($Control.Width - $d - 1), 0, $d, $d, 270, 90)
    $p.AddArc(($Control.Width - $d - 1), ($Control.Height - $d - 1), $d, $d, 0, 90)
    $p.AddArc(0, ($Control.Height - $d - 1), $d, $d, 90, 90)
    $p.CloseFigure()
    $Control.Region = New-Object System.Drawing.Region($p)
}

$script:borders = @()
$script:glows = @()
$glowEdges = @(
    @{ x = 0; y = 0; w = $screen.Width; h = 18 },
    @{ x = 0; y = ($screen.Height - 18); w = $screen.Width; h = 18 },
    @{ x = 0; y = 0; w = 18; h = $screen.Height },
    @{ x = ($screen.Width - 18); y = 0; w = 18; h = $screen.Height }
)
foreach ($edge in $glowEdges) {
    $glow = New-Object CuNoActivateForm
    $glow.FormBorderStyle = 'None'
    $glow.ShowInTaskbar = $false
    $glow.TopMost = $true
    $glow.StartPosition = 'Manual'
    $glow.Bounds = New-Object System.Drawing.Rectangle($edge.x, $edge.y, $edge.w, $edge.h)
    $glow.BackColor = [System.Drawing.Color]::FromArgb(56, 130, 246)
    $glow.Opacity = 0
    $glow.Text = 'DSH-CU-OVERLAY-GLOW'
    $glow.Show()
    $script:glows += $glow
}
$edges = @(
    @{ x = 0; y = 0; w = $screen.Width; h = 3 },
    @{ x = 0; y = ($screen.Height - 3); w = $screen.Width; h = 3 },
    @{ x = 0; y = 0; w = 3; h = $screen.Height },
    @{ x = ($screen.Width - 3); y = 0; w = 3; h = $screen.Height }
)
foreach ($edge in $edges) {
    $form = New-Object CuNoActivateForm
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.Bounds = New-Object System.Drawing.Rectangle($edge.x, $edge.y, $edge.w, $edge.h)
    $form.BackColor = [System.Drawing.Color]::FromArgb(96, 165, 250)
    $form.Opacity = 0
    $form.Text = 'DSH-CU-OVERLAY-BORDER'
    $form.Show()
    $script:borders += $form
}

$popup = New-Object CuNoActivateForm
$popup.FormBorderStyle = 'None'
$popup.ShowInTaskbar = $false
$popup.TopMost = $true
$popup.StartPosition = 'Manual'
$popup.Size = New-Object System.Drawing.Size(700, 104)
$popup.Location = New-Object System.Drawing.Point(([int](($screen.Width - 700) / 2)), 18)
$popup.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$popup.Opacity = 0
$popup.Text = 'DSH-CU-OVERLAY-POPUP'
Set-RoundedRegion $popup 22
$popup.Add_Paint({
    param($s, $e)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
    $c1 = if ($script:cancel) { [System.Drawing.Color]::FromArgb(220, 38, 38) } else { [System.Drawing.Color]::FromArgb(37, 99, 235) }
    $c2 = if ($script:cancel) { [System.Drawing.Color]::FromArgb(127, 29, 29) } else { [System.Drawing.Color]::FromArgb(29, 78, 216) }
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 0)
    $e.Graphics.FillRectangle($brush, $rect)
    $brush.Dispose()
})
$dot = New-Object System.Windows.Forms.Panel
$dot.Size = New-Object System.Drawing.Size(10, 10)
$dot.Location = New-Object System.Drawing.Point(26, 44)
$dot.BackColor = [System.Drawing.Color]::White
Set-RoundedRegion $dot 5
$popup.Controls.Add($dot)
$title = New-Object System.Windows.Forms.Label
$title.AutoSize = $true
$title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$title.BackColor = [System.Drawing.Color]::Transparent
$title.Location = New-Object System.Drawing.Point(52, 20)
$title.Text = $strings.title
$popup.Controls.Add($title)
$subtitle = New-Object System.Windows.Forms.Label
$subtitle.AutoSize = $true
$subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(214, 231, 255)
$subtitle.BackColor = [System.Drawing.Color]::Transparent
$subtitle.Location = New-Object System.Drawing.Point(52, 56)
$subtitle.Text = $strings.subtitle
$popup.Controls.Add($subtitle)
$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = $strings.stop
$stopButton.Size = New-Object System.Drawing.Size(124, 36)
$stopButton.Location = New-Object System.Drawing.Point(552, 33)
$stopButton.BackColor = [System.Drawing.Color]::White
$stopButton.ForeColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
$stopButton.FlatStyle = 'Flat'
$stopButton.FlatAppearance.BorderSize = 0
$stopButton.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$stopButton.Cursor = [System.Windows.Forms.Cursors]::Hand
Set-RoundedRegion $stopButton 18
$stopButton.Add_Click({
    try {
        if (Test-Path $cancelPath) { Remove-Item $cancelPath -Force }
        else { [IO.File]::WriteAllText($cancelPath, (Get-Date).ToString('o'), (New-Object Text.UTF8Encoding($false))) }
    } catch {}
})
$popup.Controls.Add($stopButton)

# Cursor marker: a thin ring with a small center dot. A thin ring avoids the
# heavy donut look and does not depend on a magenta transparency key.
$ring = New-Object CuNoActivateForm
$ring.FormBorderStyle = 'None'
$ring.ShowInTaskbar = $false
$ring.TopMost = $true
$ring.StartPosition = 'Manual'
$ring.Size = New-Object System.Drawing.Size(40, 40)
$ring.BackColor = [System.Drawing.Color]::FromArgb(147, 197, 253)
$ring.Opacity = 0
$ring.Text = 'DSH-CU-OVERLAY-CURSOR'
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate
$path.AddEllipse(0, 0, 40, 40)
$path.AddEllipse(4, 4, 32, 32)
$path.AddEllipse(17, 17, 6, 6)
$ring.Region = New-Object System.Drawing.Region($path)

$confirm = New-Object System.Windows.Forms.Form
$confirm.FormBorderStyle = 'None'
$confirm.ShowInTaskbar = $false
$confirm.TopMost = $true
$confirm.StartPosition = 'Manual'
$confirm.Size = New-Object System.Drawing.Size(560, 210)
$confirm.BackColor = [System.Drawing.Color]::FromArgb(16, 24, 36)
$confirm.Text = 'DSH-CU-CONFIRM'
$confirm.KeyPreview = $true
$confirmTitle = New-Object System.Windows.Forms.Label
$confirmTitle.AutoSize = $true
$confirmTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$confirmTitle.ForeColor = [System.Drawing.Color]::White
$confirmTitle.BackColor = [System.Drawing.Color]::Transparent
$confirmTitle.Location = New-Object System.Drawing.Point(24, 18)
$confirmTitle.Text = $strings.confirmTitle
$confirm.Controls.Add($confirmTitle)
$confirmBody = New-Object System.Windows.Forms.Label
$confirmBody.AutoSize = $false
$confirmBody.Size = New-Object System.Drawing.Size(512, 74)
$confirmBody.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$confirmBody.ForeColor = [System.Drawing.Color]::FromArgb(220, 230, 240)
$confirmBody.BackColor = [System.Drawing.Color]::Transparent
$confirmBody.Location = New-Object System.Drawing.Point(24, 52)
$confirm.Controls.Add($confirmBody)
$countdown = New-Object System.Windows.Forms.Label
$countdown.AutoSize = $true
$countdown.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$countdown.ForeColor = [System.Drawing.Color]::FromArgb(160, 180, 200)
$countdown.BackColor = [System.Drawing.Color]::Transparent
$countdown.Location = New-Object System.Drawing.Point(24, 132)
$confirm.Controls.Add($countdown)
$allow = New-Object System.Windows.Forms.Button
$allow.Text = $strings.allow
$allow.Size = New-Object System.Drawing.Size(150, 34)
$allow.Location = New-Object System.Drawing.Point(236, 158)
$allow.BackColor = [System.Drawing.Color]::FromArgb(30, 120, 220)
$allow.ForeColor = [System.Drawing.Color]::White
$allow.FlatStyle = 'Flat'
$confirm.Controls.Add($allow)
$deny = New-Object System.Windows.Forms.Button
$deny.Text = $strings.deny
$deny.Size = New-Object System.Drawing.Size(150, 34)
$deny.Location = New-Object System.Drawing.Point(392, 158)
$deny.BackColor = [System.Drawing.Color]::FromArgb(60, 70, 85)
$deny.ForeColor = [System.Drawing.Color]::White
$deny.FlatStyle = 'Flat'
$confirm.Controls.Add($deny)

function Complete-Confirmation {
    param([bool]$Allow, [string]$Reason = 'human')
    if (-not $script:dialogId) { return }
    Write-JsonFile $responsePath ([ordered]@{ id = $script:dialogId; allow = $Allow; reason = $Reason; at = (Get-Date).ToString('o') })
    $script:dialogId = ''
    $script:dialogStarted = $null
    $confirm.Hide()
}

$allow.Add_Click({ Complete-Confirmation $true 'allow' })
$deny.Add_Click({ Complete-Confirmation $false 'deny' })
$confirm.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Complete-Confirmation $false 'escape' } })
$confirm.Add_FormClosing({ param($s, $e) if ($script:dialogId) { $e.Cancel = $true; Complete-Confirmation $false 'closed' } })

function Update-Overlay {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $active = 0
    try { if (Test-Path $activePath) { [void][long]::TryParse((Get-Content $activePath -Raw), [ref]$active) } } catch {}
    $script:cancel = Test-Path $cancelPath
    if ($script:cancel -and $script:dialogId) { Complete-Confirmation $false 'cancelled' }
    # Keep the glow continuous between calls; only a longer idle period fades it.
    $isActive = ($active -gt 0 -and ($now - $active) -lt 15000)
    if ($isActive) { $script:lastActive = $now }
    $want = $isActive -or $script:cancel -or [bool]$script:dialogId
    if ($want) { $script:visibility = [Math]::Min(1.0, $script:visibility + 0.14) }
    else { $script:visibility = [Math]::Max(0.0, $script:visibility - 0.06) }
    $show = $script:visibility -gt 0.01
    $alpha = 0.0
    $color = [System.Drawing.Color]::FromArgb(96, 165, 250)
    if ($script:cancel) {
        $alpha = 0.30
        $color = [System.Drawing.Color]::FromArgb(239, 68, 68)
    } elseif ($want) {
        $alpha = 0.20
        $g = [int](155 + 55 * (0.5 + 0.5 * [Math]::Sin($now / 420.0)))
        $color = [System.Drawing.Color]::FromArgb(96, $g, 250)
    }
    $alpha = $alpha * $script:visibility
    foreach ($border in $script:borders) {
        $border.BackColor = $color
        $border.Opacity = [Math]::Max(0.0, [Math]::Min(0.45, $alpha))
    }
    foreach ($glow in $script:glows) {
        $glow.BackColor = $color
        $glow.Opacity = [Math]::Max(0.0, [Math]::Min(0.20, $alpha * 0.45))
    }
    if ($show) {
        if (-not $popup.Visible) { $popup.Show() }
        $popup.Opacity = 0.96 * $script:visibility
        $popup.Invalidate()
        if ($script:cancel) {
            $title.Text = $strings.paused
            $subtitle.Text = $strings.resume
            $dot.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
            $stopButton.Text = $strings.resumeAction
            $stopButton.ForeColor = [System.Drawing.Color]::FromArgb(153, 27, 27)
        } elseif ($script:dialogId) {
            $title.Text = $strings.waiting
            $subtitle.Text = $strings.confirmTitle
            $dot.BackColor = [System.Drawing.Color]::White
            $stopButton.Text = $strings.stop
            $stopButton.ForeColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
        } else {
            $title.Text = $strings.title
            $subtitle.Text = $strings.subtitle
            $dot.BackColor = [System.Drawing.Color]::White
            $stopButton.Text = $strings.stop
            $stopButton.ForeColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
        }
    } else {
        $popup.Opacity = 0
        if ($popup.Visible) { $popup.Hide() }
    }
    if ($show) {
        $cursor = [System.Windows.Forms.Cursor]::Position
        $ring.Location = New-Object System.Drawing.Point(($cursor.X - 20), ($cursor.Y - 20))
        $ring.BackColor = if ($script:cancel) { [System.Drawing.Color]::FromArgb(248, 113, 113) } else { [System.Drawing.Color]::FromArgb(147, 197, 253) }
        $ringBase = if ($script:cancel) { 0.55 } else { 0.8 }
        $ring.Opacity = $ringBase * $script:visibility
        if (-not $ring.Visible) { $ring.Show() }
    } else {
        $ring.Opacity = 0
        if ($ring.Visible) { $ring.Hide() }
    }

    if (Test-Path $requestPath) {
        try {
            $req = Get-Content $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($req.id -and $req.id -ne $script:dialogId) {
                $script:dialogId = [string]$req.id
                $script:dialogStarted = $now
                $confirmBody.Text = ([string]$req.action) + "`r`n" + ([string]$req.detail)
                $confirm.Location = New-Object System.Drawing.Point(([int](($screen.Width - 560) / 2)), 138)
                $confirm.Show()
                $confirm.BringToFront()
                $confirm.Activate()
            }
        } catch {}
    }
    if ($script:dialogId) {
        $elapsed = $now - $script:dialogStarted
        $left = [Math]::Max(0, 30 - [int]($elapsed / 1000))
        $countdown.Text = ($strings.timeout -f $left)
        if ($elapsed -gt 30000) { Complete-Confirmation $false 'timeout' }
    }
}

$hotkeyForm = New-Object CuHotkeyForm
$hotkeyForm.ShowInTaskbar = $false
$hotkeyForm.FormBorderStyle = 'None'
$hotkeyForm.Opacity = 0
$hotkeyForm.Size = New-Object System.Drawing.Size(1, 1)
$hotkeyForm.Location = New-Object System.Drawing.Point(-100, -100)
$hotkeyForm.Add_Hotkey({
    if (Test-Path $cancelPath) { Remove-Item -Force $cancelPath }
    else {
        [IO.File]::WriteAllText($cancelPath, (Get-Date).ToString('o'), (New-Object Text.UTF8Encoding($false)))
        Complete-Confirmation $false 'cancelled'
    }
})
$hotkeyForm.Show()

Write-JsonFile $readyPath ([ordered]@{ pid = $PID; at = (Get-Date).ToString('o') })
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 80
$timer.Add_Tick({ Update-Overlay })
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run($hotkeyForm)
} finally {
    try { $timer.Stop() } catch {}
    try { Remove-Item -Force $readyPath, $activePath, $requestPath, $responsePath, $cancelPath -ErrorAction SilentlyContinue } catch {}
}
