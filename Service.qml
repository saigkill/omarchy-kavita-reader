import QtQuick
import Quickshell
import Quickshell.Io

// Headless service for the Kavita reader. Owns the session (URL, username,
// token) and every curl call to the Kavita REST API. The shell creates one
// instance per enabled plugin; the bar widget and the panel are views over
// this object and call into it.
Item {
  id: svc

  property string kavitaUrl: ""
  property string username: ""
  property string token: ""

  readonly property bool loggedIn: token.length > 0

  // The token never enters argv: every authenticated curl reads its
  // Authorization header from the environment instead of the world-readable
  // process arguments in /proc.
  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/quickshell/kavita-reader"
  readonly property var authEnv: ({ AUTH: "Authorization: Bearer " + svc.token })

  signal errorOccurred(string message)
  signal librariesLoaded(var list)
  signal seriesLoaded(var list)
  signal booksLoaded(var list)
  signal bookDownloaded(string path)
  signal cbzUnpacked(string dir, var images)
  signal epubConverted(string pdfPath)

  function login(url, user, password) {
    svc.kavitaUrl = String(url || "").replace(/\/+$/, "")
    svc.username = user
    loginReq.payload = JSON.stringify({ username: user, password: password })
    loginReq.command = ["curl", "-s", "-X", "POST", svc.kavitaUrl + "/api/Account/login",
      "-H", "Content-Type: application/json", "-d", "@-"]
    loginReq.running = true
  }

  function getLibraries() {
    if (!svc.loggedIn) return
    libsReq.environment = svc.authEnv
    libsReq.command = ["bash", "-c", 'curl -s -H "$AUTH" "$1"',
      "bash", svc.kavitaUrl + "/api/Library/libraries"]
    libsReq.running = true
  }

  // Kavita has no GET endpoint to list a library's series; the current API is
  // POST /api/Series/v2 with a filter (field 19 = Libraries, comparison 0 =
  // Is). all-v2 ignores its libraryId parameter, so v2 is used instead.
  function libraryFilter(libraryId) {
    return JSON.stringify({
      statements: [{ comparison: 0, field: 19, value: String(libraryId) }]
    })
  }

  function getSeries(libraryId) {
    if (!svc.loggedIn) return
    seriesReq.environment = svc.authEnv
    seriesReq.command = ["bash", "-c",
      'curl -s -H "$AUTH" -H "Content-Type: application/json" -X POST -d "$1" "$2"',
      "bash", svc.libraryFilter(libraryId),
      svc.kavitaUrl + "/api/Series/v2?pageNumber=1&pageSize=10000"]
    seriesReq.running = true
  }

  // A series' readable units are its chapters (one file each), fetched via the
  // volumes endpoint and flattened for the panel.
  function getBooks(seriesId) {
    if (!svc.loggedIn) return
    booksReq.environment = svc.authEnv
    booksReq.command = ["bash", "-c", 'curl -s -H "$AUTH" "$1"',
      "bash", svc.kavitaUrl + "/api/Series/volumes?seriesId=" + seriesId]
    booksReq.running = true
  }

  // MangaFormat: 0 Image, 1 Archive (CBZ/CBR), 3 EPUB, 4 PDF.
  function bookFormat(file) {
    if (!file) return "UNKNOWN"
    var ext = String(file.extension || "").toLowerCase()
    if (file.format === 4) return "PDF"
    if (file.format === 3) return "EPUB"
    if (file.format === 1) return (ext === ".cbr" || ext === ".rar") ? "CBR" : "CBZ"
    if (file.format === 0) return "IMAGE"
    return "UNKNOWN"
  }

  function flattenBooks(volumes) {
    var books = []
    if (!volumes) return books
    for (var i = 0; i < volumes.length; i++) {
      var chapters = volumes[i].chapters || []
      for (var j = 0; j < chapters.length; j++) {
        var chapter = chapters[j]
        var files = chapter.files || []
        var file = files.length > 0 ? files[0] : null
        books.push({
          id: chapter.id,
          name: chapter.title || chapter.titleName || ("Band " + chapter.number),
          format: svc.bookFormat(file),
          extension: file ? String(file.extension || "") : "",
          volumeId: chapter.volumeId,
          pages: chapter.pages
        })
      }
    }
    return books
  }

  function downloadBook(bookId, fileName) {
    if (!svc.loggedIn) return ""
    var safe = String(fileName || "").replace(/[^a-zA-Z0-9._-]/g, "_")
    var dest = svc.cacheDir + "/" + bookId + "_" + safe
    dlReq.destPath = dest
    dlReq.environment = svc.authEnv
    dlReq.command = ["bash", "-c", 'mkdir -p "$1" && curl -sL -H "$AUTH" -o "$2" "$3"',
      "bash", svc.cacheDir, dest, svc.kavitaUrl + "/api/Download/chapter?chapterId=" + bookId]
    dlReq.running = true
    return dest
  }

  // Quickshell cannot host QtWebEngine, so EPUBs are converted to PDF and shown
  // in the panel's PDF viewer. ebook-convert (calibre) is preferred when
  // installed, otherwise pandoc with a LaTeX engine is used as fallback.
  function convertEpub(path) {
    if (!path) return
    epubConv.command = ["bash", "-c",
      'export PATH="$HOME/.local/bin:$PATH"; '
      + 'src="$1"; out="${src%.*}.pdf"; rm -f "$out"; '
      + 'if command -v ebook-convert >/dev/null 2>&1; then '
      + '  ebook-convert "$src" "$out" >/dev/null 2>&1; '
      + 'elif command -v pandoc >/dev/null 2>&1; then '
      + '  pandoc "$src" -o "$out" >/dev/null 2>&1 '
      + '    || pandoc "$src" -o "$out" --pdf-engine=xelatex >/dev/null 2>&1; '
      + 'fi; '
      + 'if [ -s "$out" ]; then printf "%s" "$out"; else exit 1; fi',
      "bash", path]
    epubConv.running = true
  }

  function unpackCbz(path) {
    if (!path) return
    var dir = path + "_unpack"
    unpackProc.dir = dir
    unpackProc.command = ["bash", "-c",
      'rm -rf "$1" && mkdir -p "$1" && unzip -q "$2" -d "$1" '
      + '&& find "$1" -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" '
      + '-o -iname "*.webp" -o -iname "*.gif" \\) | sort',
      "bash", dir, path]
    unpackProc.running = true
  }

  function unpackCbr(path) {
    if (!path) return
    var dir = path + "_unpack"
    cbrProc.dir = dir
    cbrProc.command = ["bash", "-c",
      'rm -rf "$1" && mkdir -p "$1" '
      + '&& (unrar x -inul -y "$2" "$1/" 2>/dev/null || bsdtar -xf "$2" -C "$1" 2>/dev/null '
      + '|| 7z e -o"$1" "$2" >/dev/null 2>&1) '
      + '&& find "$1" -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" '
      + '-o -iname "*.webp" -o -iname "*.gif" \\) | sort',
      "bash", dir, path]
    cbrProc.running = true
  }

  function linesOf(text) {
    var trimmed = String(text || "").trim()
    if (trimmed === "") return []
    return trimmed.split(/\n+/)
  }

  Process {
    id: loginReq
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(text)
          if (res && res.token) {
            svc.token = res.token
          } else {
            svc.errorOccurred("Login fehlgeschlagen")
          }
        } catch (e) {
          svc.errorOccurred("Login-Fehler: " + e)
        }
      }
    }
  }

  Process {
    id: libsReq
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          svc.librariesLoaded(JSON.parse(text))
        } catch (e) {
          svc.errorOccurred("Bibliotheken laden fehlgeschlagen")
        }
      }
    }
  }

  Process {
    id: seriesReq
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          svc.seriesLoaded(JSON.parse(text))
        } catch (e) {
          svc.errorOccurred("Serien laden fehlgeschlagen")
        }
      }
    }
  }

  Process {
    id: booksReq
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          svc.booksLoaded(svc.flattenBooks(JSON.parse(text)))
        } catch (e) {
          svc.errorOccurred("Bücher laden fehlgeschlagen")
        }
      }
    }
  }

  Process {
    id: dlReq
    property string destPath: ""
    onExited: function(exitCode) {
      if (exitCode === 0 && destPath.length > 0) svc.bookDownloaded(destPath)
      else if (exitCode !== 0) svc.errorOccurred("Download fehlgeschlagen")
    }
  }

  Process {
    id: epubConv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        if (out.length > 0) svc.epubConverted(out)
        else svc.errorOccurred("EPUB-Konvertierung fehlgeschlagen (ebook-convert oder pandoc+LaTeX nötig)")
      }
    }
  }

  Process {
    id: unpackProc
    property string dir: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: svc.cbzUnpacked(unpackProc.dir, svc.linesOf(text))
    }
  }

  Process {
    id: cbrProc
    property string dir: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: svc.cbzUnpacked(cbrProc.dir, svc.linesOf(text))
    }
  }
}
