.pragma library

// Trust boundary helpers for Service.qml. Everything the Kavita server sends
// (IDs, titles) is untrusted before it touches argv or the local file system.
// Kept free of QML types so tests/run.js can exercise it with plain node.

// Kavita IDs are positive integers. Anything else (path segments, query
// fragments, floats, exponents) is rejected rather than sanitized.
function isId(v) {
  if (typeof v !== "number" && typeof v !== "string") return false
  return /^[1-9][0-9]{0,17}$/.test(String(v))
}

// Server JSON is untrusted: a tiny response such as {"length":1e100} must not
// reach the synchronous model loops in the panel. Accept real arrays only, cap
// their size and keep plain objects.
var MAX_LIST_ITEMS = 5000
function asList(value) {
  if (!Array.isArray(value)) return []
  var out = []
  var n = Math.min(value.length, MAX_LIST_ITEMS)
  for (var i = 0; i < n; i++) {
    var item = value[i]
    if (item !== null && typeof item === "object" && !Array.isArray(item)) out.push(item)
  }
  return out
}

// asList caps each array, but nested arrays (volumes -> chapters) multiply:
// 5000 x 5000 items fit into a few MB of JSON. One overall budget for the
// flattened result keeps the panel's synchronous model append bounded, and
// titles are clipped so a few huge strings cannot bloat the model either.
var MAX_TOTAL_BOOKS = 5000
var MAX_TITLE_CHARS = 300
function clip(value, max) {
  var s = String(value === undefined || value === null ? "" : value)
  return s.length > max ? s.slice(0, max) : s
}

// Flatten volumes -> chapters into book records, stopping at MAX_TOTAL_BOOKS.
// formatOf(file) maps a Kavita file object to a format label.
function flattenBooks(volumes, formatOf) {
  var books = []
  volumes = asList(volumes)
  for (var i = 0; i < volumes.length && books.length < MAX_TOTAL_BOOKS; i++) {
    var chapters = asList(volumes[i].chapters)
    for (var j = 0; j < chapters.length && books.length < MAX_TOTAL_BOOKS; j++) {
      var chapter = chapters[j]
      if (!isId(chapter.id)) continue
      var files = asList(chapter.files)
      var file = files.length > 0 ? files[0] : null
      books.push({
        id: chapter.id,
        name: clip(chapter.title || chapter.titleName || ("Volume " + chapter.number), MAX_TITLE_CHARS),
        format: formatOf(file),
        extension: file ? clip(file.extension, 16) : "",
        volumeId: chapter.volumeId,
        pages: chapter.pages
      })
    }
  }
  return books
}

// True only for a path strictly below cacheDir without any ".." segment.
function inCache(path, cacheDir) {
  var p = String(path || "")
  var c = String(cacheDir || "").replace(/\/+$/, "")
  if (c === "" || p.indexOf(c + "/") !== 0) return false
  if (/[\n\r\0]/.test(p)) return false
  return p.slice(c.length + 1).split("/").indexOf("..") === -1
}

function safeName(name) {
  return String(name || "").replace(/[^a-zA-Z0-9._-]/g, "_")
}

// curl config (read via `-K -` from stdin) holding the Authorization header,
// so the token never appears in argv or the environment of any process.
function authConfig(token) {
  var t = String(token || "").replace(/[\u0000-\u001f\u007f]/g, "")
  return 'header = "Authorization: Bearer ' + t.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"\n'
}

// Memory budget for API responses that are buffered whole and JSON-parsed in
// QML (login, libraries, series, books, refresh-token). A hostile configured
// server, or anyone who can tamper with a plain-HTTP response, could otherwise
// keep the connection open and stream an unbounded body, growing the shared
// shell's memory without limit before JSON.parse ever runs.
var MAX_API_RESPONSE_BYTES = 16 * 1024 * 1024

// Runs curl with the given arguments and caps its combined stdout (JSON body
// plus, where used, the trailing "-w" status line) at MAX_API_RESPONSE_BYTES.
// `head -c` closes the pipe once the budget is hit, which stops curl with
// SIGPIPE instead of letting it keep buffering. A response cut off this way
// fails JSON.parse and is handled like any other malformed response. Stdin
// (an auth config or POST body) passes through to curl unchanged.
var cappedCurlScript = 'curl "$@" | head -c ' + MAX_API_RESPONSE_BYTES

// Restricts an existing cache to its owner. A symlinked or foreign-owned cache
// dir is refused (chmod would follow the link); inside it, symlinks are never
// chmod'ed (find -type l is skipped, -xdev stays on one filesystem) and only
// the owner's own files are touched. "$1" is always the cache directory.
var RESTRICT = 'if [ -L "$1" ] || [ ! -O "$1" ]; then exit 1; fi; '
  + 'chmod 700 "$1" && find "$1" -xdev -user "$(id -u)" ! -type l -exec chmod go-rwx {} + || exit 1; '

// Runs once at service startup, so data cached by an older version is locked
// down on upgrade without waiting for the next download. Never creates the dir.
var startupScript = 'umask 077; [ -d "$1" ] || exit 0; ' + RESTRICT

// Every script that writes into the cache starts with this: private umask,
// a 0700 cache dir and any pre-existing content restricted to the owner.
var PREPARE = 'umask 077; if [ -L "$1" ]; then exit 1; fi; mkdir -p -m 700 "$1" || exit 1; ' + RESTRICT

// $1 cache dir, $2 destination file, $3 URL. The header arrives on stdin.
var downloadScript = PREPARE + 'rm -f "$2" && curl -sL -K - -o "$2" "$3"'

// $1 cache dir, $2 source EPUB.
var epubScript = PREPARE
  + 'export PATH="$HOME/.local/bin:$PATH"; '
  + 'src="$2"; out="${src%.*}.pdf"; rm -f "$out"; '
  + 'if command -v ebook-convert >/dev/null 2>&1; then '
  + '  ebook-convert "$src" "$out" >/dev/null 2>&1; '
  + 'elif command -v pandoc >/dev/null 2>&1; then '
  + '  pandoc "$src" -o "$out" >/dev/null 2>&1 '
  + '    || pandoc "$src" -o "$out" --pdf-engine=xelatex >/dev/null 2>&1; '
  + 'fi; '
  + 'if [ -s "$out" ]; then printf "%s" "$out"; else exit 1; fi'

// Archives carry their own modes (often 644); tighten them after extraction.
var IMAGES = 'chmod -R go-rwx "$2" && find "$2" -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" '
  + '-o -iname "*.webp" -o -iname "*.gif" \\) | sort'

// $1 cache dir, $2 unpack dir, $3 archive.
var unzipScript = PREPARE + 'rm -rf "$2" && mkdir -p "$2" && unzip -q "$3" -d "$2" && ' + IMAGES

var unrarScript = PREPARE + 'rm -rf "$2" && mkdir -p "$2" '
  + '&& (unrar x -inul -y "$3" "$2/" 2>/dev/null || bsdtar -xf "$3" -C "$2" 2>/dev/null '
  + '|| 7z e -o"$2" "$3" >/dev/null 2>&1) && ' + IMAGES

if (typeof module !== "undefined") {
  module.exports = {
    isId: isId, asList: asList, MAX_LIST_ITEMS: MAX_LIST_ITEMS,
    flattenBooks: flattenBooks, clip: clip, MAX_TOTAL_BOOKS: MAX_TOTAL_BOOKS, MAX_TITLE_CHARS: MAX_TITLE_CHARS, inCache: inCache, safeName: safeName, authConfig: authConfig,
    MAX_API_RESPONSE_BYTES: MAX_API_RESPONSE_BYTES, cappedCurlScript: cappedCurlScript,
    PREPARE: PREPARE, startupScript: startupScript, downloadScript: downloadScript, epubScript: epubScript,
    unzipScript: unzipScript, unrarScript: unrarScript
  }
}
