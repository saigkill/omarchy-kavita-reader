# omarchy-kavita-reader

Quickshell plugin for Omarchy: connects to [Kavita](https://www.kavitareader.com/) and reads eBooks (EPUB, PDF, CBZ/CBR) straight from the bar.

## Features

- Login to Kavita (JWT)
- Browse libraries → series → books
- Live search in the series column (case-insensitive substring, e.g. `C#`)
- EPUB: converted to PDF and shown in the PDF viewer
- PDF: `QtQuick.Pdf` with fit-to-width and vertical scrolling
- CBZ/CBR: download, unpack and display as images
- Local cache at `~/.cache/quickshell/kavita-reader/`

## Requirements

For CBR you need `unrar`, `bsdtar` or `7z` depending on your system; for CBZ, `unzip` is enough.

EPUB is converted (Quickshell cannot host QtWebEngine): preferably with `ebook-convert` (Calibre), otherwise `pandoc` with a LaTeX engine.

## Usage

The plugin provides a bar widget (book icon) that opens the panel. The IPC target `saigkill.kavita-reader` exposes `open`, `close`, `show`, `hide` and `toggle`.

## Kavita API

Endpoints used:

| Purpose | Call |
|---|---|
| Login | `POST /api/Account/login` |
| Libraries | `GET /api/Library/libraries` |
| Series of a library | `POST /api/Series/v2` with filter (`field: 19` = Libraries, `comparison: 0` = Is) |
| Books (chapters) | `GET /api/Series/volumes?seriesId=` |
| Download | `GET /api/Download/chapter?chapterId=` |

The Authorization header is passed via the environment (`$AUTH`) rather than the process arguments so the token does not show up in `/proc`.

`MangaFormat`: 0 Image, 1 Archive (CBZ/CBR), 3 EPUB, 4 PDF.

## Development

Edit inside the `omarchy-kavita-reader/` directory. Quickshell reloads the plugin on changes. This version is additionally installed at `~/.dotfiles/.config/omarchy/plugins/saigkill.kavita-reader/`; both copies are kept identical.

## License

MIT
