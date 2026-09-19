# WG Idle Guard

Ergänzung für den **WireGuard-Client für Windows**: trennt den Tunnel automatisch,
wenn er längere Zeit nicht genutzt wurde (z. B. weil man vergessen hat, ihn zu deaktivieren).
Bedienung über ein Tray-Symbol, keine Skriptkenntnisse nötig.

## Funktionen

- Tray-Symbol mit Status: grün = verbunden, grau = getrennt, orange = Trennung steht bevor, rot = Wächter nicht erreichbar
- Menü: Verbinden/Trennen, Timer zurücksetzen, Leerlaufzeit wählen (15 min, 30 min, 1 h, 2 h, nie)
- Vorwarnung 2 Minuten vor der Trennung; Klick auf die Meldung hält den Tunnel offen
- Meldung nach einer automatischen Trennung

## Installation

1. Repository herunterladen/entpacken (Voraussetzung: WireGuard für Windows mit mindestens einem Tunnel).
2. `Install.cmd` doppelklicken (fordert Administratorrechte an).
3. Das Tray-Symbol erscheint nach der nächsten Anmeldung oder sofort über das Startmenü („WireGuard Auto-Trennung“).

Entfernen: `Uninstall.cmd`.

## Aufbau

| Datei | Aufgabe |
|---|---|
| `WG-Watchdog.ps1` | Läuft als SYSTEM-Aufgabe, misst den Tunnel-Traffic (`wg.exe show <tunnel> transfer`), trennt/verbindet den Tunnel über `wireguard.exe /uninstalltunnelservice` bzw. `/installtunnelservice` |
| `WG-Tray.ps1` | Tray-Symbol im Benutzerkontext (WinForms), schreibt Befehle als Dateien nach `C:\ProgramData\WGIdleGuard\cmd` |
| `Install-WGIdleGuard.ps1` | Installer/Deinstaller (Aufgabenplanung, Verzeichnisse, Rechte) |

Programmdateien liegen in `C:\Program Files\WGIdleGuard` (nur Administratoren dürfen schreiben),
Konfiguration und Status in `C:\ProgramData\WGIdleGuard` (für Benutzer beschreibbar, der Wächter validiert alle Werte).

## Konfiguration

`C:\ProgramData\WGIdleGuard\config.json`

```json
{ "Tunnel": "schule", "IdleMinutes": 30, "MinBytes": 4096 }
```

- `Tunnel`: Name des überwachten Tunnels
- `IdleMinutes`: Minuten ohne Aktivität bis zur Trennung (0 = aus), im Tray-Menü einstellbar
- `MinBytes`: Bytes pro Minute, die noch als Aktivität zählen (Keepalives liegen darunter)

## Hinweise

- Die Skripte sind unsigniert und werden mit `-ExecutionPolicy Bypass` gestartet; bei AppLocker/WDAC ggf. anpassen.
- Es wird ein einzelner Tunnel überwacht.
- Skriptdateien sind UTF-8 mit BOM (nötig für Windows PowerShell 5.1) und CRLF; `.gitattributes` erhält die Zeilenenden.
- Status: ungetestet auf echter Hardware, bitte erst auf einem Testrechner prüfen.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
