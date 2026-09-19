# WG-Tray.ps1
# Tray-Symbol für den WireGuard-Wächter: zeigt den Status, erlaubt Verbinden/Trennen
# und warnt vor der automatischen Trennung. Läuft im Kontext des angemeldeten Benutzers.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Nur eine Instanz pro Benutzersitzung
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\WGIdleGuardTray', [ref]$created)
if (-not $created) { exit }

$Base    = Join-Path $env:ProgramData 'WGIdleGuard'
$CfgFile = Join-Path $Base 'config.json'
$StFile  = Join-Path $Base 'status.json'
$CmdDir  = Join-Path $Base 'cmd'

$script:seenEvent  = $null
$script:warnShown  = $false
$script:lastBalloon = ''
$script:lastState  = ''

# ---------- Symbole ----------
function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = [System.Drawing.SolidBrush]::new($color)
    $pen   = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 3)
    $g.FillEllipse($brush, 3, 3, 26, 26)
    $g.DrawEllipse($pen, 3, 3, 26, 26)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$script:icoOn   = New-DotIcon ([System.Drawing.Color]::FromArgb(46, 160, 67))
$script:icoOff  = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 140, 140))
$script:icoWarn = New-DotIcon ([System.Drawing.Color]::FromArgb(230, 140, 0))
$script:icoErr  = New-DotIcon ([System.Drawing.Color]::FromArgb(200, 50, 50))

# ---------- Hilfsfunktionen ----------
function Get-Status {
    try {
        $s = Get-Content $StFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$s.Updated
        if ($age -gt 30) { return $null }
        return $s
    } catch { return $null }
}

function Read-Cfg {
    try { return (Get-Content $CfgFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Send-Command([string]$name) {
    try { New-Item -ItemType File -Path (Join-Path $CmdDir $name) -Force | Out-Null } catch {}
}

function Set-Idle([int]$minutes) {
    $c = Read-Cfg
    if ($c) {
        $c.IdleMinutes = $minutes
        $c | ConvertTo-Json | Set-Content -Path $CfgFile -Encoding UTF8
        Update-Ui
    }
}

function Show-Balloon([string]$text, [string]$kind) {
    $script:lastBalloon = $kind
    $script:ni.BalloonTipTitle = 'WireGuard'
    $script:ni.BalloonTipText  = $text
    $script:ni.BalloonTipIcon  = 'Info'
    $script:ni.ShowBalloonTip(10000)
}

# ---------- Menü ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$script:miStatus = $menu.Items.Add('Status wird geladen ...')
$script:miStatus.Enabled = $false
$menu.Items.Add('-') | Out-Null

$script:miToggle = $menu.Items.Add('Verbinden')
$script:miToggle.add_Click({
    $s = Get-Status
    if ($s -and $s.Connected) { Send-Command 'disconnect'; Show-Balloon 'Tunnel wird getrennt ...' 'info' }
    else                      { Send-Command 'connect';    Show-Balloon 'Tunnel wird verbunden ...' 'info' }
})

$script:miReset = $menu.Items.Add('Timer zurücksetzen (Tunnel offen halten)')
$script:miReset.add_Click({ Send-Command 'reset' })

$script:miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Automatisch trennen nach'
$options = @(
    @{ Label = '15 Minuten'; Value = 15 },
    @{ Label = '30 Minuten'; Value = 30 },
    @{ Label = '1 Stunde';   Value = 60 },
    @{ Label = '2 Stunden';  Value = 120 },
    @{ Label = 'Nie (nicht empfohlen)'; Value = 0 }
)
foreach ($o in $options) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $o.Label
    $mi.Tag = $o.Value
    $mi.add_Click({ param($sender, $e) Set-Idle ([int]$sender.Tag) })
    $script:miAuto.DropDownItems.Add($mi) | Out-Null
}
$menu.Items.Add($script:miAuto) | Out-Null

$menu.Items.Add('-') | Out-Null
$miExit = $menu.Items.Add('Symbol beenden (Wächter läuft weiter)')
$miExit.add_Click({
    $script:timer.Stop()
    $script:ni.Visible = $false
    $script:ni.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# ---------- Tray-Symbol ----------
$script:ni = New-Object System.Windows.Forms.NotifyIcon
$script:ni.Icon = $script:icoOff
$script:ni.Text = 'WireGuard'
$script:ni.ContextMenuStrip = $menu
$script:ni.Visible = $true

# Linksklick öffnet ebenfalls das Menü
$script:ni.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $m = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu',
             [System.Reflection.BindingFlags]'NonPublic,Instance')
        $m.Invoke($script:ni, $null)
    }
})

# Klick auf die Warnmeldung verlängert die Sitzung
$script:ni.add_BalloonTipClicked({
    if ($script:lastBalloon -eq 'warn') { Send-Command 'reset' }
})

# ---------- Oberfläche aktualisieren ----------
function Set-TrayText([string]$t) {
    if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + '...' }
    $script:ni.Text = $t
}

function Update-Ui {
    $s = Get-Status
    $c = Read-Cfg

    if ($c) {
        foreach ($mi in $script:miAuto.DropDownItems) { $mi.Checked = ([int]$mi.Tag -eq [int]$c.IdleMinutes) }
    }

    if (-not $s) {
        $script:ni.Icon = $script:icoErr
        $script:miStatus.Text = 'Wächterdienst nicht erreichbar'
        $script:miToggle.Enabled = $false
        $script:miReset.Enabled  = $false
        Set-TrayText 'WireGuard: Wächterdienst nicht erreichbar'
        return
    }

    $name = [string]$s.Tunnel
    $script:miToggle.Enabled = $true

    if ($s.Connected) {
        $script:miToggle.Text = 'Trennen'
        $script:miReset.Enabled = ($null -ne $s.RemainingSec)
        if ($null -ne $s.RemainingSec) {
            $min = [math]::Ceiling([int]$s.RemainingSec / 60)
            $txt = "Verbunden – Trennung in ca. $min min"
        } else {
            $txt = 'Verbunden – automatische Trennung aus'
        }
        $script:miStatus.Text = "$name`: $txt"
        Set-TrayText "WireGuard $name`: $txt"
        $script:ni.Icon = if ($s.Warn) { $script:icoWarn } else { $script:icoOn }
    } else {
        $script:miToggle.Text = 'Verbinden'
        $script:miReset.Enabled = $false
        $script:miStatus.Text = "$name`: nicht verbunden"
        Set-TrayText "WireGuard $name`: nicht verbunden"
        $script:ni.Icon = $script:icoOff
    }

    # Vorwarnung
    if ($s.Warn -and -not $script:warnShown) {
        $script:warnShown = $true
        Show-Balloon "Der Tunnel '$name' wird in ca. 2 Minuten wegen Inaktivität getrennt. Hier klicken, um ihn offen zu halten." 'warn'
    }
    if (-not $s.Warn) { $script:warnShown = $false }

    # Meldung über automatische Trennung (ältere Meldungen beim Start nicht erneut anzeigen)
    if ($null -eq $script:seenEvent) { $script:seenEvent = [int]$s.EventId }
    elseif ([int]$s.EventId -gt $script:seenEvent) {
        $script:seenEvent = [int]$s.EventId
        Show-Balloon ([string]$s.EventText) 'event'
    }
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 2000
$script:timer.add_Tick({ try { Update-Ui } catch {} })
$script:timer.Start()

Update-Ui
[System.Windows.Forms.Application]::Run()
