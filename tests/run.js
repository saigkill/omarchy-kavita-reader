// Regression tests for the Kavita reader's trust boundaries. Plain node, no
// dependencies:  node tests/run.js
const assert = require("assert")
const fs = require("fs")
const os = require("os")
const path = require("path")
const { spawnSync } = require("child_process")
// Safety.js starts with the QML-only ".pragma library"; strip it for node.
const S = (() => {
  const src = fs.readFileSync(path.join(__dirname, "../Safety.js"), "utf8").replace(/^\.pragma.*$/m, "")
  const m = { exports: {} }
  new Function("module", src)(m)
  return m.exports
})()

const TOKEN = 'tok"en\\SECRET.abc'
let failed = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) }
  catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message) }
}

// --- chapter / series IDs ---------------------------------------------------
test("isId accepts numeric ids only", () => {
  for (const v of [1, 42, "7", 123456789012]) assert(S.isId(v), String(v))
  for (const v of ["../../../Documents/", "1/../2", "1;rm", "0", "-1", "1.5", 1.5, "1e3",
    "", null, undefined, {}, ["1"], "12 ", "\n1"]) assert(!S.isId(v), JSON.stringify(v))
})

test("inCache rejects escapes", () => {
  const c = "/h/.cache/q/kr"
  assert(S.inCache(c + "/12_a.pdf", c))
  for (const p of [c, c + "/../x", c + "/a/../../x", "/h/Documents/x", c + "x/1", "", c + "/a\nb"])
    assert(!S.inCache(p, c), p)
})

test("authConfig escapes quotes, backslashes and newlines", () => {
  assert.strictEqual(S.authConfig(TOKEN), 'header = "Authorization: Bearer tok\\"en\\\\SECRET.abc"\n')
  assert.strictEqual(S.authConfig("a\nb\r").split("\n").length, 2)
})

// --- static: every authenticated route uses stdin config --------------------
const svcSrc = fs.readFileSync(path.join(__dirname, "../Service.qml"), "utf8")
test("Service.qml has no env/argv token transport", () => {
  assert(!/\$AUTH|authEnv|\.environment\s*=|-H "\$/.test(svcSrc))
  assert(!/Bearer/.test(svcSrc.replace(/\/\/.*$/gm, "")), "Bearer must only be built in Safety.js")
})
test("all authenticated routes read the header via -K -", () => {
  const cmds = svcSrc.match(/\.command = \[[^\]]*\]/g) || []
  const authed = cmds.filter(c => /\/api\//.test(c) && !/login|refresh-token/.test(c))
  assert.strictEqual(authed.length, 4, "libs, series, books, download expected, got " + authed.length)
  for (const c of authed)
    assert(/"-K", "-"/.test(c) || /downloadScript/.test(c), c)
})
test("download script and all cache writers use the private prelude", () => {
  assert(/-K - /.test(S.downloadScript))
  for (const k of ["downloadScript", "epubScript", "unzipScript", "unrarScript"])
    assert(S[k].startsWith(S.PREPARE), k)
})

// --- behavioural: real shell scripts with a fake curl, umask 022 -------------
function sandbox() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "kavita-test-"))
  const bin = path.join(root, "bin"), log = path.join(root, "log")
  fs.mkdirSync(bin); fs.mkdirSync(log)
  fs.writeFileSync(path.join(bin, "curl"), `#!/bin/bash
echo "$@" > "${log}/argv"; env > "${log}/env"; cat > "${log}/stdin"
ps -o args= -p $PPID > "${log}/parent"
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; }; shift; done
[ -n "$out" ] && echo book > "$out"; exit 0
`, { mode: 0o755 })
  return { root, bin, log, cache: path.join(root, "home/.cache/quickshell/kavita-reader") }
}
// The scripts set their own umask; run them under a 022 parent as Quickshell would.
function run(sb, script, args, input) {
  return spawnSync("bash", ["-c", 'umask 022; exec bash -c "$0" bash "$@"', script, ...args], {
    input: input || "", encoding: "utf8",
    env: { PATH: sb.bin + ":" + process.env.PATH, HOME: path.join(sb.root, "home") }
  })
}
const mode = p => (fs.statSync(p).mode & 0o777).toString(8)

test("download: token only on stdin, never argv/env/parent cmdline", () => {
  const sb = sandbox()
  const dest = sb.cache + "/12_a.pdf"
  const r = run(sb, S.downloadScript, [sb.cache, dest, "http://x/api/Download/chapter?chapterId=12"], S.authConfig(TOKEN))
  assert.strictEqual(r.status, 0, r.stderr)
  const rd = n => fs.readFileSync(sb.log + "/" + n, "utf8")
  assert(rd("stdin").includes("SECRET"))
  for (const n of ["argv", "env", "parent"]) assert(!rd(n).includes("SECRET"), n)
  assert(/-K -/.test(rd("argv")))
})

test("download under umask 022: private cache and file", () => {
  const sb = sandbox()
  const dest = sb.cache + "/12_a.pdf"
  const r = run(sb, S.downloadScript, [sb.cache, dest, "http://x/y"], S.authConfig(TOKEN))
  assert.strictEqual(r.status, 0, r.stderr)
  assert.strictEqual(mode(sb.cache), "700")
  assert.strictEqual(mode(dest), "600")
})

test("existing world-readable cache data is restricted", () => {
  const sb = sandbox()
  fs.mkdirSync(sb.cache + "/old_unpack/sub", { recursive: true })
  fs.writeFileSync(sb.cache + "/old.pdf", "x"); fs.writeFileSync(sb.cache + "/old_unpack/sub/1.png", "x")
  fs.chmodSync(sb.cache, 0o755); fs.chmodSync(sb.cache + "/old.pdf", 0o644)
  fs.chmodSync(sb.cache + "/old_unpack/sub/1.png", 0o644); fs.chmodSync(sb.cache + "/old_unpack/sub", 0o755)
  const r = run(sb, S.downloadScript, [sb.cache, sb.cache + "/12_a.pdf", "http://x/y"], S.authConfig(TOKEN))
  assert.strictEqual(r.status, 0, r.stderr)
  assert.strictEqual(mode(sb.cache), "700")
  assert.strictEqual(mode(sb.cache + "/old.pdf"), "600")
  assert.strictEqual(mode(sb.cache + "/old_unpack/sub/1.png"), "600")
  assert.strictEqual(mode(sb.cache + "/old_unpack/sub"), "700")
})

function oldCache(sb) {
  fs.mkdirSync(sb.cache + "/old_unpack/sub", { recursive: true })
  fs.writeFileSync(sb.cache + "/old.pdf", "x"); fs.writeFileSync(sb.cache + "/old_unpack/sub/1.png", "x")
  fs.chmodSync(sb.cache, 0o755); fs.chmodSync(sb.cache + "/old.pdf", 0o644)
  fs.chmodSync(sb.cache + "/old_unpack/sub/1.png", 0o644); fs.chmodSync(sb.cache + "/old_unpack/sub", 0o755)
}

test("startup alone (no download/convert/unpack) restricts an old cache", () => {
  const sb = sandbox()
  oldCache(sb)
  const r = run(sb, S.startupScript, [sb.cache])
  assert.strictEqual(r.status, 0, r.stderr)
  assert.strictEqual(mode(sb.cache), "700")
  assert.strictEqual(mode(sb.cache + "/old.pdf"), "600")
  assert.strictEqual(mode(sb.cache + "/old_unpack/sub"), "700")
  assert.strictEqual(mode(sb.cache + "/old_unpack/sub/1.png"), "600")
})

test("startup does not create a missing cache", () => {
  const sb = sandbox()
  assert.strictEqual(run(sb, S.startupScript, [sb.cache]).status, 0)
  assert(!fs.existsSync(sb.cache))
})

test("startup never follows symlinks (cache dir or entries)", () => {
  const sb = sandbox()
  const outside = path.join(sb.root, "outside"); fs.mkdirSync(outside)
  fs.writeFileSync(outside + "/secret", "x"); fs.chmodSync(outside + "/secret", 0o644); fs.chmodSync(outside, 0o755)
  // symlinked entry inside a real cache
  fs.mkdirSync(sb.cache, { recursive: true })
  fs.symlinkSync(outside + "/secret", sb.cache + "/link"); fs.symlinkSync(outside, sb.cache + "/dirlink")
  assert.strictEqual(run(sb, S.startupScript, [sb.cache]).status, 0)
  assert.strictEqual(mode(outside + "/secret"), "644"); assert.strictEqual(mode(outside), "755")
  // symlinked cache dir itself
  const sb2 = sandbox(); fs.mkdirSync(path.dirname(sb2.cache), { recursive: true })
  fs.symlinkSync(outside, sb2.cache)
  assert.notStrictEqual(run(sb2, S.startupScript, [sb2.cache]).status, 0)
  assert.notStrictEqual(run(sb2, S.downloadScript, [sb2.cache, sb2.cache + "/1_a", "http://x"], "").status, 0)
  assert.strictEqual(mode(outside + "/secret"), "644"); assert.strictEqual(mode(outside), "755")
})

test("Service.qml runs the startup restriction on initialization", () => {
  assert(/Component\.onCompleted:\s*\{[^}]*cacheInit\.running = true/.test(svcSrc))
  assert(/id: cacheInit[\s\S]*?Safety\.startupScript/.test(svcSrc))
})

test("unzip extracts privately under umask 022", () => {
  const sb = sandbox()
  const src = path.join(sb.root, "src"); fs.mkdirSync(src)
  fs.writeFileSync(src + "/1.png", "x")
  fs.mkdirSync(sb.cache, { recursive: true })
  const zip = sb.cache + "/12_a.cbz"
  assert.strictEqual(spawnSync("zip", ["-qj", zip, src + "/1.png"]).status, 0)
  const dir = zip + "_unpack"
  const r = run(sb, S.unzipScript, [sb.cache, dir, zip])
  assert.strictEqual(r.status, 0, r.stderr)
  assert(r.stdout.includes("1.png"))
  assert.strictEqual(mode(dir), "700")
  assert.strictEqual(mode(dir + "/1.png"), "600")
})

test("asList rejects non-arrays and caps hostile lists", () => {
  for (const v of [{ length: 1e100 }, "abc", 5, null, undefined, {}])
    assert.deepStrictEqual(S.asList(v), [], JSON.stringify(v))
  assert.deepStrictEqual(S.asList([{ id: 1 }, null, 3, "x", [1], { id: 2 }]), [{ id: 1 }, { id: 2 }])
  const big = new Array(S.MAX_LIST_ITEMS * 4).fill({ id: 1 })
  assert.strictEqual(S.asList(big).length, S.MAX_LIST_ITEMS)
  assert.strictEqual(S.asList(JSON.parse('{"length":1e100}')).length, 0)
})

test("crafted chapter id never reaches a path outside the cache", () => {
  const evil = "../../../Documents/"
  assert(!S.isId(evil))
  const dest = "/h/.cache/q/kr/" + evil + "_" + S.safeName("report.pdf")
  assert(!S.inCache(dest, "/h/.cache/q/kr"))
})

process.exit(failed ? 1 : 0)
