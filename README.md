# omarchy-kavita-reader

Quickshell-Plugin für Omarchy: verbindet sich mit [Kavita](https://www.kavitareader.com/) und liest EBooks (EPUB, PDF, CBZ/CBR) direkt aus der Leiste.

## Features

- Login an Kavita (JWT)
- Bibliotheken → Serien → Bücher durchsuchen
- Live-Suche in der Serien-Spalte (case-insensitiv, Teilstring, z. B. `C#`)
- EPUB: wird nach PDF konvertiert und im PDF-Viewer angezeigt
- PDF: `QtQuick.Pdf` mit Fit-to-Width und vertikalem Scrollen
- CBZ/CBR: Download, Entpacken und Anzeige als Bilder
- Lokaler Cache unter `~/.cache/quickshell/kavita-reader/`

## Voraussetzungen

Für CBR werden je nach System `unrar`, `bsdtar` oder `7z` benötigt, für CBZ reicht `unzip`.

EPUB wird konvertiert (Quickshell kann kein QtWebEngine hosten): bevorzugt `ebook-convert` (Calibre), sonst `pandoc` mit LaTeX-Engine.

## Bedienung

Das Plugin stellt ein Bar-Widget (Buch-Icon) bereit, das das Panel öffnet. Über den IPC-Target `saigkill.kavita-reader` stehen `open`, `close`, `show`, `hide` und `toggle` zur Verfügung.

## Kavita-API

Verwendete Endpunkte:

| Zweck | Aufruf |
|---|---|
| Login | `POST /api/Account/login` |
| Bibliotheken | `GET /api/Library/libraries` |
| Serien einer Bibliothek | `POST /api/Series/v2` mit Filter (`field: 19` = Libraries, `comparison: 0` = Is) |
| Bücher (Chapters) | `GET /api/Series/volumes?seriesId=` |
| Download | `GET /api/Download/chapter?chapterId=` |

Der Authorization-Header kommt über die Umgebung (`$AUTH`) statt über die Prozessargumente, damit der Token nicht in `/proc` auftaucht.

`MangaFormat`: 0 Image, 1 Archive (CBZ/CBR), 3 EPUB, 4 PDF.

## Entwicklung

Im Verzeichnis `omarchy-kavita-reader/` bearbeiten. Quickshell lädt das Plugin bei Änderungen. Diese Version wird zusätzlich unter `~/.dotfiles/.config/omarchy/plugins/saigkill.kavita-reader/` installiert; beide Kopien werden identisch gehalten.

## Lizenz

MIT
