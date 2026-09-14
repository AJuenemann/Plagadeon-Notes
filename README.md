# Plagadeon Notes

Lokale macOS-Notizen-App auf Basis von SwiftUI.

## Start in VS Code

Im integrierten Terminal:

```bash
swift run PlagadeonNotes
```

Der Befehl baut die App bei Bedarf und startet sie anschließend.

Alternativ die bereits gebaute Debug-App starten:

```bash
open .build/arm64-apple-macosx/debug/PlagadeonNotes
```

## Als normale App starten (ohne Terminalfenster)

Einmalig im Projekt ausführen:

```bash
chmod +x scripts/install-app-bundle.sh
scripts/install-app-bundle.sh
```

Danach liegt eine normale App unter `~/Applications/Plagadeon Notes.app` und kann wie jede macOS-App per App-Icon gestartet werden.

Beim Start prüft der Launcher automatisch, ob Quellcode neuer als das gebaute Binary ist. Falls nötig, wird automatisch `swift build -c debug` ausgeführt und dann die App gestartet.

## Tests

```bash
swift test
```

## Aktueller Import

Über die Schaltfläche **Exportordner importieren** kann ein Ordner mit exportierten Text- oder Markdown-Dateien ausgewählt werden. Jede Textdatei wird zu einer Notiz. Medien im gleichen Ordner werden als Originalanhänge übernommen.

Der Import liest die Quelle nur und erstellt eine Kopie im lokalen App-Support-Ordner. Der direkte Parser für Apples internes Notes-Format folgt separat, da dieses Format nicht als stabile öffentliche API dokumentiert ist.

## Apple-Notes-Snapshot

Über **Apple-Notes-Ordner sichern** kann der lokale Apple-Notes-Datenordner ausgewählt werden. macOS fragt beim ersten Zugriff nach der Dateiberechtigung. Die App kopiert den ausgewählten Ordner unverändert nach `Application Support/PlagadeonNotes/Snapshots` und zeigt die Anzahl der Dateien, Datenbanken und Mediendateien an.

Der Snapshot ist zunächst nur eine sichere Arbeitskopie. Die eigentliche Auswertung des proprietären Apple-Formats erfolgt in einem nachgelagerten Parser, damit die Originaldaten nicht verändert werden.

Der aktuelle Vorläufer liest die SQLite-Schemata der Arbeitskopie nur lesend aus und zeigt die Anzahl erkannter Tabellen im Snapshot-Bericht. Zusätzlich wird innerhalb des Snapshots ein `schema-report.json` mit Datenbanknamen, Tabellen, Spalten, Zeilenzahlen und heuristischen Rollen (`note`, `folder`, `attachment`, `unknown`) abgelegt. Notizinhalte werden dabei noch nicht verändert oder importiert.

Über **Snapshot importieren** können erkannte Textspalten aus einer Snapshot-Datenbank als neue lokale Notizen übernommen werden. Der Import verwendet Titel-/Namensspalten sowie `body`, `content`, `text` oder `notetext` und überspringt identische Titel-/Textpaare mit einem strukturierten Schlüssel. Nach jedem Import werden Kandidaten, neue Notizen und übersprungene Duplikate angezeigt. Binäre Apple-Notes-Inhalte werden noch nicht interpretiert.

Der Hauptbutton **Apple-Notizen importieren** bündelt inzwischen Ordnerauswahl, Snapshot-Erstellung und Import in einem Schritt. Der getrennte Snapshot-Import bleibt nur als interne technische Funktion bestehen.

Notizen besitzen zusätzlich einen Ordner und eine Tagliste. Beide Felder werden lokal gespeichert, können im Editor bearbeitet werden und Tags werden von der Suche berücksichtigt. Alte `notes.json`-Dateien ohne diese Felder bleiben kompatibel.

Über das Exportmenü können einzelne Notizen als Markdown, HTML oder PDF sowie der gesamte lokale Notizbestand als JSON-Backup exportiert werden. Lange PDF-Notizen werden auf mehrere Seiten verteilt. Ein JSON-Backup kann über **Backup wiederherstellen** wieder eingelesen werden; bereits vorhandene Titel-/Textpaare werden dabei übersprungen. Snapshot- und Backup-Importe speichern die neuen Notizen in einem gemeinsamen Vorgang.

Das Wiederherstellen meldet beschädigte oder unlesbare Backups. Das Löschen einer Notiz verlangt eine Bestätigung.
