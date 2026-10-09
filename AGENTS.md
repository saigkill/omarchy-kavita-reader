# AGENTS.md

Dieses Plugin folgt exakt dem Stil der anderen Omarchy-Quickshell-Plugins hier im Ordner:

- Flache Struktur: `manifest.json`, `BarWidget.qml`, `Panel.qml`, `Service.qml`, `Model.js`
- Keine `mod/`, `pages/`, `qmldir`, `config.qmltype`
- `BarWidget.qml` + `Panel.qml` minimal & konsistent
- HTTP via `curl` in `Process` (wie bei bestehenden Plugins)
- State in `Model.js` (.pragma library)
- Assets unter `assets/`

Änderungen bitte chirurgisch & stilgetreu vornehmen.

## Architektur

- `Service.qml`: headless Service, hält Session (URL, User, Token) und alle curl-Aufrufe an die Kavita-REST-API. Gibt Signale (`librariesLoaded`, `seriesLoaded`, `booksLoaded`, `bookDownloaded`, `cbzUnpacked`, `epubConverted`, `errorOccurred`) aus.
- `BarWidget.qml`: Buch-Icon in der Leiste, Host für das Panel, liest den Service über `bar.shell.serviceFor(moduleName)`.
- `Panel.qml`: Login- und Browser-/Reader-Ansicht; reine View über den Service.
- `Model.js`: nicht-reaktiver View-State des Panels.

## Kavita-API (verifiziert)

- Bibliotheken: `GET /api/Library/libraries` (nicht `/api/Library`).
- Serien: `POST /api/Series/v2` mit Body `{statements:[{comparison:0,field:19,value:"<libraryId>"}]}` und `?pageNumber=1&pageSize=10000`. `FilterField.Libraries = 19`, `comparison 0 = Is`. Hinweis: `all-v2` ignoriert seinen `libraryId`-Parameter.
- Bücher: `GET /api/Series/volumes?seriesId=` → Volumes mit `chapters`, im Service flachgeklopft.
- Download: `GET /api/Download/chapter?chapterId=` (nicht `/api/Book/Download/{id}`).
- Auth-Header immer über die Umgebung (`$AUTH`) in `bash -c 'curl -s -H "$AUTH" ...'`, damit der Token nicht in `/proc` steht.
- `MangaFormat`: 0 Image, 1 Archive (CBZ/CBR), 3 EPUB, 4 PDF.

## Darstellung

- Serien-Suche ist clientseitig: pro Bibliothek werden alle Serien geladen, das Suchfeld filtert per case-insensitivem Teilstring auf `name` (kein Extra-Request).
- PDF: `QtQuick.Pdf` mit `scaleToWidth(width, height)` (Fit-to-Width), `clip: true` und vertikalem Scrollen.
- EPUB: Quickshell kann kein QtWebEngine hosten, daher Konvertierung nach PDF (`ebook-convert`, sonst `pandoc`+LaTeX).
- CBZ/CBR: Download nach `~/.cache/quickshell/kavita-reader/`, entpacken (`unzip` bzw. `unrar`/`bsdtar`/`7z`) und Bilder anzeigen. Die Seite im `Flickable` gegen die Flickable-Breite skalieren (`width: cbzView.width`), nicht gegen `parent.width`: da `contentHeight` der Bildhöhe folgt, entstünde sonst eine Bindingschleife und das Bild kollabiert auf 0 (leerer Reader).

## Verifikation

- `qmllint Panel.qml` und `qmllint Service.qml` müssen fehlerfrei durchlaufen.
- `qmllint BarWidget.qml` endet mit 255 (nicht auflösbare `qs.*`-Imports) — das ist bei allen funktionierenden Omarchy-Plugins so und kein echter Fehler.

## Zwei Kopien

Die Quelle liegt im Dropbox-Repo, installiert wird nach `~/.dotfiles/.config/omarchy/plugins/saigkill.kavita-reader/` (aktiv via `~/.config/omarchy/plugins/saigkill.kavita-reader`). Nach Änderungen beide Kopien mit `rsync -a --delete` identisch halten und mit `diff -rq` prüfen.
