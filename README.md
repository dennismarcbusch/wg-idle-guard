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

**Hinweis zum ZIP-Download:** Dateien aus einem heruntergeladenen ZIP tragen eine Internet-Markierung
(Zone.Identifier), Windows/SmartScreen kann dann beim Start von `Install.cmd` warnen oder blockieren.
Vor dem Entpacken die ZIP-Datei per Rechtsklick → *Eigenschaften* → *Zulassen* entsperren
(oder in PowerShell `Unblock-File` auf die entpackten Dateien anwenden).

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
{ "Tunnel": "schule", "IdleMinutes": 30, "MinBytes": 32768 }
```

- `Tunnel`: Name des überwachten Tunnels
- `IdleMinutes`: Minuten ohne Aktivität bis zur Trennung (0 = aus), im Tray-Menü einstellbar
- `MinBytes`: Bytes pro Minute (Summe aus Empfang und Senden), die noch als Aktivität zählen.
  Verkehr darunter, etwa Keepalives und Hintergrund-DNS, hält den Tunnel nicht offen (siehe unten)

Fehlt `IdleMinutes` oder `MinBytes`, oder ist der Wert ungültig, gelten die Standardwerte (30 bzw. 32768).
`IdleMinutes` muss zwischen 0 und 1440 liegen, `Tunnel` darf nur `A-Z a-z 0-9 _ = + . -` enthalten (max. 32 Zeichen).

## Funktionsweise der Aktivitätserkennung

- Der Wächter prüft alle 5 Sekunden, ob der Tunnel läuft, und liest die Summe aus empfangenen und gesendeten Bytes
  (`wg.exe show <tunnel> transfer`).
- Die Bytes werden in **60-Sekunden-Fenstern** verglichen: Wurden im Fenster mehr als `MinBytes` übertragen,
  gilt der Tunnel als aktiv und der Leerlauf-Timer beginnt von vorn. Keepalive-Pakete (wenige Bytes pro Minute)
  bleiben darunter und halten den Tunnel deshalb nicht offen. Das gilt auch für Hintergrundverkehr, siehe
  „DNS-Server und Hintergrundverkehr“.
- Der Timer startet, sobald der Wächter den laufenden Tunnel erstmals sieht (auch nach einem Neustart des Rechners).
- Noch 2 Minuten vor Ablauf wechselt das Symbol auf orange und eine Meldung erscheint.
  „Timer zurücksetzen“ oder ein Klick auf die Meldung startet die Leerlaufzeit neu.
- Nach Ablauf trennt der Wächter den Tunnel (`wireguard.exe /uninstalltunnelservice`) und meldet das im Tray.
- Die Bewertung erfolgt nur im 60-Sekunden-Raster; sehr kurze Leerlaufzeiten (1–2 Minuten) sind daher ungenau,
  ab 15 Minuten spielt das keine Rolle.
- **Standby/Ruhezustand:** Die Ruhezeit zählt als Leerlauf. Nach dem Aufwachen wird sofort getrennt, wenn die Leerlaufzeit
  abgelaufen ist. Fließen unmittelbar nach dem Aufwachen mehr als `MinBytes` an Daten (z. B. Programme synchronisieren),
  wertet der Wächter das als Aktivität, und die Trennung bleibt aus.

### DNS-Server und Hintergrundverkehr

Sind in der Tunnelkonfiguration eigene DNS-Server eingetragen (`DNS = …` im Abschnitt `[Interface]`),
setzt der WireGuard-Client sie auf dem Tunneladapter mit niedriger Schnittstellenmetrik. Windows fragt in der Regel
zuerst diese Server, sodass auch bei unbenutztem Rechner Namensauflösung und andere Hintergrundprogramme
laufend kleine Pakete durch den Tunnel schicken. Der Tunnel wirkt dann „aktiv“, obwohl niemand ihn benutzt.

Gemessenes Beispiel (Rechner gesperrt, 20 Minuten, Tunnel mit VPN-DNS-Servern): im Median rund 9 KB pro Minute,
höchstens ca. 17,5 KB pro Minute. Mit einer Schwelle von 4096 Byte zählten 17 von 20 Minuten als Aktivität,
und der Timer lief nie ab. Deshalb ist der Standard für `MinBytes` 32768 (32 KiB pro Minute).

Ob das bei euch passt, lässt sich prüfen: Bei gesperrtem Rechner sollte `RemainingSec` in
`C:\ProgramData\WGIdleGuard\status.json` gleichmäßig sinken und nicht immer wieder auf die volle Leerlaufzeit zurückspringen.
Springt der Wert zurück, `MinBytes` erhöhen (oder die Ursache des Verkehrs suchen, z. B. mit Wireshark auf dem Tunneladapter).
Eine zu hohe Schwelle hat den Preis, dass sehr leichte Nutzung (z. B. eine SSH-Sitzung mit seltenem Tippen) nicht mehr
als Aktivität zählt. Dann hilft „Timer zurücksetzen“ oder eine längere Leerlaufzeit.

## Hinweise

- Die Skripte sind unsigniert und werden mit `-ExecutionPolicy Bypass` gestartet; bei AppLocker/WDAC ggf. anpassen.
- Es wird ein einzelner Tunnel überwacht.
- Skriptdateien sind UTF-8 mit BOM (nötig für Windows PowerShell 5.1) und CRLF; `.gitattributes` erhält die Zeilenenden.
- Status: ungetestet auf echter Hardware, bitte erst auf einem Testrechner prüfen.

## Fehlerbehebung

Log des Wächters: `C:\ProgramData\WGIdleGuard\watchdog.log` (wird bei 200 KB automatisch geleert).

| Problem | Ursache / Lösung |
|---|---|
| Symbol ist **rot** („Wächterdienst nicht erreichbar“) | Der Wächter hat seit über 30 Sekunden keinen Status geschrieben. In der Aufgabenplanung prüfen, ob `WGIdleGuard-Watchdog` existiert und läuft (Rechtsklick → *Ausführen*); ggf. `Install.cmd` erneut ausführen. |
| Kein Tray-Symbol | Startmenü → „WireGuard Auto-Trennung“ starten. Nach der Anmeldung startet die Aufgabe `WGIdleGuard-Tray` automatisch. Ein Symbol pro Benutzersitzung genügt, ein zweiter Start beendet sich selbst. |
| „Verbinden“ bewirkt nichts | Im Log steht dann meist „Konfiguration für '…' nicht gefunden“: Der Tunnelname in `config.json` stimmt nicht mit einem WireGuard-Tunnel überein. Name korrigieren oder neu installieren. |
| Tunnel wird getrennt, obwohl er benutzt wird | Der Datenverkehr liegt unter `MinBytes` pro Minute. `MinBytes` in `config.json` senken oder die Leerlaufzeit erhöhen. |
| Tunnel wird nie getrennt (Anzeige bleibt bei der vollen Leerlaufzeit, z. B. „Trennung in ca. 15 min“) | Im Tray-Menü ist „Nie“ gewählt, oder Hintergrundverkehr (z. B. DNS über den Tunnel) liegt über `MinBytes`. `RemainingSec` in `status.json` beobachten und `MinBytes` erhöhen, siehe „DNS-Server und Hintergrundverkehr“. |
| Installation bricht mit „WireGuard ist nicht installiert“ ab | WireGuard für Windows nach `C:\Program Files\WireGuard` installieren und mindestens einen Tunnel importieren. |
| Umlaute erscheinen falsch | Skripte wurden ohne UTF-8-BOM gespeichert; Windows PowerShell 5.1 braucht das BOM (siehe Hinweise). |

## Lizenz

MIT, siehe [LICENSE](LICENSE).
