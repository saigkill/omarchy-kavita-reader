import QtQuick
import Quickshell
import Quickshell.Io
import "Safety.js" as Safety

// Headless service for the Kavita reader. Owns the session (URL, username,
// token) and every curl call to the Kavita REST API. The shell creates one
// instance per enabled plugin; the bar widget and the panel are views over
// this object and call into it.
Item {
  id: svc

  property string kavitaUrl: ""
  property string username: ""
  property string token: ""
  property string refreshToken: ""
  property bool refreshTried: false

  readonly property bool loggedIn: token.length > 0

  // The token never enters argv or the environment: every authenticated curl
  // reads its Authorization header as a config (`-K -`) from stdin, so neither
  // curl nor any wrapper shell exposes it in /proc. The cache is private
  // (0700, umask 077) and only receives server data under validated numeric IDs.
  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/quickshell/kavita-reader"
  // The session survives a reboot: URL, user and tokens (never the password)
  // live in a private file outside the plugin directory.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy-kavita-reader"
  readonly property string sessionFile: stateDir + "/session.json"

  signal errorOccurred(string message)
  signal librariesLoaded(var list)
  signal seriesLoaded(var list)
  signal booksLoaded(var list)
  signal bookDownloaded(string path)
  signal cbzUnpacked(string dir, var images)
  signal epubConverted(string pdfPath)

  Component.onCompleted: {
    loadReq.running = true
    cacheInit.running = true
  }

  function saveSession() {
    saveReq.payload = JSON.stringify({
      url: svc.kavitaUrl, username: svc.username,
      token: svc.token, refreshToken: svc.refreshToken
    })
    saveReq.running = true
  }

  function clearSession() {
    svc.token = ""
    svc.refreshToken = ""
    clearReq.running = true
  }

  // Only a 401 means the stored session is dead. Anything else (server or
  // network not up yet right after boot) must keep it.
  function handleHttpStatus(code) {
    if (code !== "401") return false
    if (svc.refreshToken === "" || svc.refreshTried) {
      svc.clearSession()
      svc.errorOccurred("Session expired, please log in again")
      return true
    }
    svc.refreshTried = true
    refreshReq.payload = JSON.stringify({ token: svc.token, refreshToken: svc.refreshToken })
    refreshReq.command = ["bash", "-c", Safety.cappedCurlScript, "bash",
      "-s", "-w", "\n%{http_code}", "-X", "POST",
      svc.kavitaUrl + "/api/Account/refresh-token",
      "-H", "Content-Type: application/json", "-d", "@-"]
    refreshReq.running = true
    return true
  }

  // Splits curl's "-w \n%{http_code}" output into body and status code.
  function splitStatus(raw) {
    var t = String(raw || "")
    var i = t.lastIndexOf("\n")
    return i < 0 ? { body: t, code: "" } : { body: t.slice(0, i), code: t.slice(i + 1).trim() }
  }

  function login(url, user, password) {
    svc.kavitaUrl = String(url || "").replace(/\/+$/, "")
    svc.username = user
    loginReq.payload = JSON.stringify({ username: user, password: password })
    loginReq.command = ["bash", "-c", Safety.cappedCurlScript, "bash",
      "-s", "-X", "POST", svc.kavitaUrl + "/api/Account/login",
      "-H", "Content-Type: application/json", "-d", "@-"]
    loginReq.running = true
  }

  function getLibraries() {
    if (!svc.loggedIn) return
    libsReq.payload = Safety.authConfig(svc.token)
    libsReq.command = ["bash", "-c", Safety.cappedCurlScript, "bash",
      "-s", "-w", "\\n%{http_code}", "-K", "-",
      svc.kavitaUrl + "/api/Library/libraries"]
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
    if (!svc.loggedIn || !Safety.isId(libraryId)) return
    seriesReq.payload = Safety.authConfig(svc.token)
    seriesReq.command = ["bash", "-c", Safety.cappedCurlScript, "bash",
      "-s", "-K", "-", "-H", "Content-Type: application/json",
      "-X", "POST", "-d", svc.libraryFilter(libraryId),
      svc.kavitaUrl + "/api/Series/v2?pageNumber=1&pageSize=10000"]
    seriesReq.running = true
  }

  // A series' readable units are its chapters (one file each), fetched via the
  // volumes endpoint and flattened for the panel.
  function getBooks(seriesId) {
    if (!svc.loggedIn || !Safety.isId(seriesId)) return
    booksReq.payload = Safety.authConfig(svc.token)
    booksReq.command = ["bash", "-c", Safety.cappedCurlScript, "bash",
      "-s", "-K", "-",
      svc.kavitaUrl + "/api/Series/volumes?seriesId=" + seriesId]
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
    volumes = Safety.asList(volumes)
    for (var i = 0; i < volumes.length; i++) {
      var chapters = Safety.asList(volumes[i].chapters)
      for (var j = 0; j < chapters.length; j++) {
        var chapter = chapters[j]
        var files = Safety.asList(chapter.files)
        var file = files.length > 0 ? files[0] : null
        if (!Safety.isId(chapter.id)) continue
        books.push({
          id: chapter.id,
          name: chapter.title || chapter.titleName || ("Volume " + chapter.number),
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
    if (!Safety.isId(bookId)) {
      svc.errorOccurred("Invalid book id")
      return ""
    }
    var dest = svc.cacheDir + "/" + bookId + "_" + Safety.safeName(fileName)
    if (!Safety.inCache(dest, svc.cacheDir)) {
      svc.errorOccurred("Invalid download path")
      return ""
    }
    dlReq.destPath = dest
    dlReq.payload = Safety.authConfig(svc.token)
    dlReq.command = ["bash", "-c", Safety.downloadScript,
      "bash", svc.cacheDir, dest, svc.kavitaUrl + "/api/Download/chapter?chapterId=" + bookId]
    dlReq.running = true
    return dest
  }

  // Quickshell cannot host QtWebEngine, so EPUBs are converted to PDF and shown
  // in the panel's PDF viewer. ebook-convert (calibre) is preferred when
  // installed, otherwise pandoc with a LaTeX engine is used as fallback.
  function convertEpub(path) {
    if (!path || !Safety.inCache(path, svc.cacheDir)) return
    epubConv.command = ["bash", "-c", Safety.epubScript, "bash", svc.cacheDir, path]
    epubConv.running = true
  }

  function unpackCbz(path) {
    if (!path || !Safety.inCache(path, svc.cacheDir)) return
    var dir = path + "_unpack"
    unpackProc.dir = dir
    unpackProc.command = ["bash", "-c", Safety.unzipScript, "bash", svc.cacheDir, dir, path]
    unpackProc.running = true
  }

  function unpackCbr(path) {
    if (!path || !Safety.inCache(path, svc.cacheDir)) return
    var dir = path + "_unpack"
    cbrProc.dir = dir
    cbrProc.command = ["bash", "-c", Safety.unrarScript, "bash", svc.cacheDir, dir, path]
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
            svc.refreshToken = res.refreshToken || ""
            svc.refreshTried = false
            svc.token = res.token
            svc.saveSession()
          } else {
            svc.errorOccurred("Login failed")
          }
        } catch (e) {
          svc.errorOccurred("Login error: " + e)
        }
      }
    }
  }

  Process {
    id: libsReq
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      stdinEnabled = false
    }
    onRunningChanged: if (!running) stdinEnabled = true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = svc.splitStatus(text)
        if (svc.handleHttpStatus(r.code)) return
        try {
          svc.librariesLoaded(Safety.asList(JSON.parse(r.body)))
        } catch (e) {
          svc.errorOccurred("Failed to load libraries")
        }
      }
    }
  }

  Process {
    id: loadReq
    command: ["sh", "-c", 'cat "$1" 2>/dev/null', "sh", svc.sessionFile]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (s && s.token && s.url && !svc.loggedIn) {
            svc.kavitaUrl = s.url
            svc.username = s.username || ""
            svc.refreshToken = s.refreshToken || ""
            svc.token = s.token
          }
        } catch (e) {
          // No stored session yet: the login form stays.
        }
      }
    }
  }

  Process {
    id: saveReq
    property string payload: ""
    stdinEnabled: true
    command: ["sh", "-c",
      'umask 077; mkdir -p "$1" && chmod 700 "$1" && cat > "$2.tmp" && mv "$2.tmp" "$2"',
      "sh", svc.stateDir, svc.sessionFile]
    onStarted: {
      write(payload)
      stdinEnabled = false
    }
    onRunningChanged: if (!running) stdinEnabled = true
  }

  // Locks down a cache left by an older version (0755/0644) at startup.
  Process {
    id: cacheInit
    command: ["bash", "-c", Safety.startupScript, "bash", svc.cacheDir]
  }

  Process {
    id: clearReq
    command: ["rm", "-f", svc.sessionFile]
  }

  Process {
    id: refreshReq
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      stdinEnabled = false
    }
    onRunningChanged: if (!running) stdinEnabled = true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = svc.splitStatus(text)
        try {
          var res = JSON.parse(r.body)
          if (res && res.token) {
            svc.token = res.token
            svc.refreshToken = res.refreshToken || svc.refreshToken
            svc.refreshTried = false
            svc.saveSession()
            svc.getLibraries()
            return
          }
        } catch (e) {}
        if (r.code === "400" || r.code === "401") {
          svc.clearSession()
          svc.errorOccurred("Session expired, please log in again")
        } else {
          svc.errorOccurred("Session could not be renewed")
        }
      }
    }
  }

  Process {
    id: seriesReq
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      stdinEnabled = false
    }
    onRunningChanged: if (!running) stdinEnabled = true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          svc.seriesLoaded(Safety.asList(JSON.parse(text)))
        } catch (e) {
          svc.errorOccurred("Failed to load series")
        }
      }
    }
  }

  Process {
    id: booksReq
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      stdinEnabled = false
    }
    onRunningChanged: if (!running) stdinEnabled = true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          svc.booksLoaded(svc.flattenBooks(JSON.parse(text)))
        } catch (e) {
          svc.errorOccurred("Failed to load books")
        }
      }
    }
  }

  Process {
    id: dlReq
    property string destPath: ""
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      stdinEnabled = false
    }
    onRunningChanged: if (!running) stdinEnabled = true
    onExited: function(exitCode) {
      if (exitCode === 0 && destPath.length > 0) svc.bookDownloaded(destPath)
      else if (exitCode !== 0) svc.errorOccurred("Download failed")
    }
  }

  Process {
    id: epubConv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        if (out.length > 0) svc.epubConverted(out)
        else svc.errorOccurred("EPUB conversion failed (ebook-convert or pandoc+LaTeX required)")
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
