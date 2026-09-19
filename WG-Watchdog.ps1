# WG-Watchdog.ps1
# Läuft als SYSTEM-Aufgabe im Hintergrund. Überwacht den WireGuard-Tunnel,
# trennt ihn bei Inaktivität und nimmt Befehle vom Tray-Symbol entgegen.

$ErrorActionPreference = 'Continue'

$Base    = Join-Path $env:ProgramData 'WGIdleGuard'
$CfgFile = Join-Path $Base 'config.json'
$StFile  = Join-Path $Base 'status.json'
$CmdDir  = Join-Path $Base 'cmd'
$Log     = Join-Path $Base 'watchdog.log'
$Wg      = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
$WgCli   = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
$ConfDir = Join-Path $env:ProgramFiles 'WireGuard\Data\Configurations'

New-Item -ItemType Directory -Force -Path $CmdDir | Out-Null
Get-ChildItem $CmdDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

function Write-Log([string]$m) {
    try {
        if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 200KB) { Remove-Item $Log -Force }
        "$(Get-Date -Format s)  $m" | Add-Content -Path $Log
    } catch {}
}

# Konfiguration lesen und validieren (die Datei ist für Benutzer beschreibbar!)
function Get-Cfg {
    $c = @{ Tunnel = ''; IdleMinutes = 30; MinBytes = [int64]4096 }
    try {
        $j = Get-Content $CfgFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($j.Tunnel -match '^[A-Za-z0-9_=+.-]{1,32}\z') { $c.Tunnel = [string]$j.Tunnel }
        if ($null -ne $j.IdleMinutes) {
            $m = [int]$j.IdleMinutes
            if ($m -ge 0 -and $m -le 1440) { $c.IdleMinutes = $m }
        }
        if ($null -ne $j.MinBytes) {
            $b = [int64]$j.MinBytes
            if ($b -ge 0) { $c.MinBytes = $b }
        }
    } catch {}
    return $c
}

function Test-Running([string]$t) {
    $svc = Get-Service -Name "WireGuardTunnel`$$t" -ErrorAction SilentlyContinue
    return [bool]($svc -and $svc.Status -eq 'Running')
}

# Summe aus empfangenen und gesendeten Bytes aller Peers des Tunnels
function Get-Bytes([string]$t) {
    $sum = [int64]0
    try {
        foreach ($line in (& $WgCli show $t transfer 2>$null)) {
            $p = "$line" -split "`t"
            if ($p.Count -ge 3) { $sum += [int64]$p[1] + [int64]$p[2] }
        }
    } catch {}
    return $sum
}

function Save-Status($obj) {
    try {
        $tmp = "$StFile.tmp"
        $obj | ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $StFile -Force
    } catch {}
}

function Stop-Tunnel([string]$t) {
    & $Wg /uninstalltunnelservice $t | Out-Null
    Start-Sleep -Seconds 2
}

$eventId   = 0
$eventText = ''
$sess      = $null
Write-Log 'Wächter gestartet'

while ($true) {
    try {
        $cfg = Get-Cfg
        $t   = $cfg.Tunnel
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $running = $false
        if ($t) { $running = Test-Running $t }

        # --- Befehle vom Tray-Symbol ---
        if ($t) {
            if (Test-Path "$CmdDir\disconnect") {
                Remove-Item "$CmdDir\disconnect" -Force -ErrorAction SilentlyContinue
                if ($running) {
                    Stop-Tunnel $t
                    $running = Test-Running $t
                    Write-Log "Tunnel '$t' manuell getrennt"
                }
            }
            if (Test-Path "$CmdDir\connect") {
                Remove-Item "$CmdDir\connect" -Force -ErrorAction SilentlyContinue
                if (-not $running) {
                    $conf = Join-Path $ConfDir "$t.conf.dpapi"
                    if (-not (Test-Path $conf)) { $conf = Join-Path $ConfDir "$t.conf" }
                    if (Test-Path $conf) {
                        & $Wg /installtunnelservice $conf | Out-Null
                        Start-Sleep -Seconds 3
                        $running = Test-Running $t
                        Write-Log "Tunnel '$t' verbunden"
                    } else {
                        Write-Log "Konfiguration für '$t' nicht gefunden"
                    }
                }
            }
            if (Test-Path "$CmdDir\reset") {
                Remove-Item "$CmdDir\reset" -Force -ErrorAction SilentlyContinue
                if ($sess) { $sess.LastActive = $now; $sess.Warned = $false }
            }
        }

        # --- Sitzung und Aktivität verfolgen ---
        if (-not $running) {
            $sess = $null
        }
        elseif (-not $sess) {
            $sess = @{ LastActive = $now; WinStart = $now; WinBytes = (Get-Bytes $t); Warned = $false }
        }
        else {
            $b = Get-Bytes $t
            if ($b -lt $sess.WinBytes) {
                $sess.WinBytes = $b; $sess.WinStart = $now      # Zähler wurde zurückgesetzt
            }
            elseif (($now - $sess.WinStart) -ge 60) {
                if (($b - $sess.WinBytes) -gt $cfg.MinBytes) { $sess.LastActive = $now }
                $sess.WinBytes = $b; $sess.WinStart = $now
            }
        }

        # --- Inaktivität auswerten ---
        $remaining = $null
        $warn = $false
        if ($sess -and $cfg.IdleMinutes -gt 0) {
            $remaining = [int]($cfg.IdleMinutes * 60 - ($now - $sess.LastActive))
            if ($remaining -le 0) {
                Stop-Tunnel $t
                $running = Test-Running $t
                if (-not $running) {
                    $eventId++
                    $eventText = "Der Tunnel '$t' wurde wegen Inaktivität getrennt."
                    Write-Log "Tunnel '$t' wegen Inaktivität getrennt"
                }
                $sess = $null
                $remaining = $null
            }
            elseif ($remaining -le 120) { $warn = $true }
        }

        Save-Status ([pscustomobject]@{
            Tunnel       = $t
            Connected    = $running
            RemainingSec = $remaining
            Warn         = $warn
            IdleMinutes  = $cfg.IdleMinutes
            EventId      = $eventId
            EventText    = $eventText
            Updated      = $now
        })
    }
    catch { Write-Log "Fehler: $($_.Exception.Message)" }

    Start-Sleep -Seconds 5
}
