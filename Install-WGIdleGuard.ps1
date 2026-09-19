# Install-WGIdleGuard.ps1
# Richtet den WireGuard-Wächter samt Tray-Symbol ein (oder entfernt ihn mit -Uninstall).
# Muss als Administrator laufen; Install.cmd / Uninstall.cmd erledigen das per Doppelklick.

param(
    [switch]$Uninstall,
    [string]$Tunnel
)

$ErrorActionPreference = 'Stop'

$App  = Join-Path $env:ProgramFiles 'WGIdleGuard'      # Programmdateien (nur Admins dürfen schreiben)
$Data = Join-Path $env:ProgramData  'WGIdleGuard'      # Konfiguration/Status (Benutzer dürfen schreiben)
$Lnk  = Join-Path $env:ProgramData  'Microsoft\Windows\Start Menu\Programs\WireGuard Auto-Trennung.lnk'

try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Bitte als Administrator ausführen (Rechtsklick -> Als Administrator ausführen).'
    }

    # ---------------- Deinstallation ----------------
    if ($Uninstall) {
        foreach ($n in 'WGIdleGuard-Watchdog', 'WGIdleGuard-Tray') {
            Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
        }
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match 'WG-(Watchdog|Tray)\.ps1' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Remove-Item $Lnk, $App, $Data -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'WireGuard-Wächter wurde entfernt.' -ForegroundColor Green
        return
    }

    # ---------------- Installation ----------------
    $Wg      = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    $ConfDir = Join-Path $env:ProgramFiles 'WireGuard\Data\Configurations'
    if (-not (Test-Path $Wg)) { throw 'WireGuard ist nicht installiert.' }

    # Tunnel auswählen
    $tunnels = @(Get-ChildItem $ConfDir -Filter '*.conf*' -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.Name -replace '\.conf(\.dpapi)?$', '' } | Sort-Object -Unique)
    if (-not $Tunnel) {
        if ($tunnels.Count -eq 0) { throw 'Es wurde kein WireGuard-Tunnel gefunden. Bitte zuerst einen Tunnel importieren.' }
        elseif ($tunnels.Count -eq 1) { $Tunnel = $tunnels[0] }
        else {
            Write-Host 'Gefundene Tunnel:'
            for ($i = 0; $i -lt $tunnels.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $tunnels[$i]) }
            $n = [int](Read-Host 'Nummer des zu überwachenden Tunnels')
            if ($n -lt 1 -or $n -gt $tunnels.Count) { throw 'Ungültige Auswahl.' }
            $Tunnel = $tunnels[$n - 1]
        }
    }
    if ($Tunnel -notmatch '^[A-Za-z0-9_=+.-]{1,32}\z') { throw "Ungültiger Tunnelname: '$Tunnel'" }
    Write-Host "Überwachter Tunnel: $Tunnel"

    # Verzeichnisse und Dateien
    New-Item -ItemType Directory -Force -Path $App, $Data, (Join-Path $Data 'cmd') | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'WG-Watchdog.ps1'), (Join-Path $PSScriptRoot 'WG-Tray.ps1') -Destination $App -Force

    # Unsichtbarer Starter fürs Tray-Skript (verhindert das kurze Konsolenfenster)
    $vbs = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' +
           (Join-Path $App 'WG-Tray.ps1') + '""", 0, False'
    Set-Content -Path (Join-Path $App 'WG-Tray.vbs') -Value $vbs -Encoding ASCII

    # Benutzer dürfen nur den Datenordner ändern (Einstellungen, Befehle), nicht die Programmdateien
    icacls $Data /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null

    # Konfiguration (vorhandene Einstellung für die Leerlaufzeit bleibt erhalten)
    $cfgFile = Join-Path $Data 'config.json'
    $idle = 30
    if (Test-Path $cfgFile) { try { $idle = [int](Get-Content $cfgFile -Raw | ConvertFrom-Json).IdleMinutes } catch {} }
    [pscustomobject]@{ Tunnel = $Tunnel; IdleMinutes = $idle; MinBytes = 32768 } |
        ConvertTo-Json | Set-Content -Path $cfgFile -Encoding ASCII

    # Frühere Einzelskripte deaktivieren, damit sie nicht dazwischenfunken
    Unregister-ScheduledTask -TaskName 'WG-IdleOff' -Confirm:$false -ErrorAction SilentlyContinue

    # Aufgabe 1: Wächter (SYSTEM, beim Start des Rechners)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $App 'WG-Watchdog.ps1'))
    Stop-ScheduledTask -TaskName 'WGIdleGuard-Watchdog' -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName 'WGIdleGuard-Watchdog' -Action $act -Trigger (New-ScheduledTaskTrigger -AtStartup) `
            -Settings $set -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'WGIdleGuard-Watchdog'

    # Aufgabe 2: Tray-Symbol (für jeden Benutzer bei der Anmeldung)
    $tAct  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f (Join-Path $App 'WG-Tray.vbs'))
    $tPrin = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $tSet  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'WGIdleGuard-Tray' -Action $tAct -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
            -Principal $tPrin -Settings $tSet -Force | Out-Null

    # Startmenü-Eintrag zum manuellen Starten des Tray-Symbols
    $sh = (New-Object -ComObject WScript.Shell).CreateShortcut($Lnk)
    $sh.TargetPath = 'wscript.exe'
    $sh.Arguments  = ('"{0}"' -f (Join-Path $App 'WG-Tray.vbs'))
    $sh.Save()

    Write-Host ''
    Write-Host 'Installation abgeschlossen.' -ForegroundColor Green
    Write-Host 'Das Tray-Symbol erscheint nach der nächsten Anmeldung,'
    Write-Host "oder sofort über das Startmenü: 'WireGuard Auto-Trennung'."
}
catch {
    Write-Host ''
    Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host ''
    Read-Host 'Zum Beenden Enter drücken'
}
