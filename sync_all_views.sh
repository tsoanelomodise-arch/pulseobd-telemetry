#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="/home/antigravity/.gemini/jetski/brain/v1/default/jetski_remote_agents_3p/da11f8e9-2af2-4cb6-bd05-445122ca51c7"
if [[ -z "${STUDIO_SRC:-}" ]]; then
  if [[ -f "$ARTIFACT_DIR/obd_drive_studio.html" ]]; then
    STUDIO_SRC="$ARTIFACT_DIR/obd_drive_studio.html"
  else
    STUDIO_SRC="$REPO_DIR/PulseOBD_Studio.html"
  fi
fi
WIDGET_SRC="${WIDGET_SRC:-$ARTIFACT_DIR/obd_live_cockpit_widget.html}"
TAILWIND_CACHE="/tmp/tailwind.min.js"
TAILWIND_URL="https://www.gstatic.com/antigravity/web/dev/tailwindcss.min.js"

BUILD_ONLY=0
COMMIT_MSG="Sync PulseOBD views: Firebase auto-sync, BT coexistence & Google Drive/Pages parity"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --message|-m)
      COMMIT_MSG="${2:-$COMMIT_MSG}"
      shift 2
      ;;
    --source)
      STUDIO_SRC="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "=== [1/5] Checking source files & JS syntax ==="
if [[ ! -f "$STUDIO_SRC" ]]; then
  echo "ERROR: Studio source not found at $STUDIO_SRC" >&2
  exit 1
fi

export STUDIO_SRC WIDGET_SRC REPO_DIR TAILWIND_CACHE

node -e '
const fs = require("fs");
const vm = require("vm");
for (const file of [process.env.STUDIO_SRC, process.env.WIDGET_SRC]) {
  if (!file || !fs.existsSync(file)) continue;
  const html = fs.readFileSync(file, "utf8");
  const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)];
  scripts.forEach((m, idx) => {
    const code = m[1].trim();
    if (!code) return;
    new vm.Script(code, { filename: file + "#script" + idx });
  });
  console.log("JS syntax OK:", file, "(" + scripts.length + " script tags)");
}
'

echo "=== [2/5] Security check: verify no private Firebase URLs or *.local.json in public files ==="
cd "$REPO_DIR"
if git ls-files | grep -E 'firebase\.local\.json$|\.local\.json$' >/dev/null 2>&1; then
  echo "ERROR: Local secret JSON file is tracked by git!" >&2
  exit 1
fi

node -e '
const fs = require("fs");
const path = require("path");
function walkFiles(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walkFiles(p, out);
    else if (ent.isFile()) out.push(p);
  }
  return out;
}
const files = [
  process.env.STUDIO_SRC,
  process.env.WIDGET_SRC,
  process.env.REPO_DIR + "/bridge/start_obd_web_bridge.ps1",
  process.env.REPO_DIR + "/Launch_PulseOBD.bat",
  process.env.REPO_DIR + "/README.md",
  process.env.REPO_DIR + "/manifest.json",
  ...walkFiles(process.env.REPO_DIR + "/vehicle_history")
];
const allowedHost = /your-project(-ref)?(-default-rtdb)?\.(firebaseio\.com|firebasedatabase\.app)/i;
const firebaseRe = /https:\/\/[a-z0-9.-]+\.(firebaseio\.com|firebasedatabase\.app)[^\s"'"'"'`<]*/gi;
for (const f of files) {
  if (!f || !fs.existsSync(f)) continue;
  const txt = fs.readFileSync(f, "utf8");
  const matches = txt.match(firebaseRe) || [];
  for (const m of matches) {
    if (!allowedHost.test(m)) {
      console.error("ERROR: Private Firebase URL detected in public file:", f, "->", m);
      process.exit(1);
    }
  }
}
console.log("Security check PASSED: 0 private Firebase URLs across " + files.length + " public file(s).");
'

echo "=== [3/5] Precompiling / syncing standalone PulseOBD_Studio.html & index.html ==="
if grep -q 'tailwindcss\.min\.js' "$STUDIO_SRC"; then
  if [[ ! -s "$TAILWIND_CACHE" ]]; then
    echo "Downloading Tailwind standalone runtime to $TAILWIND_CACHE..."
    curl -fsSL "$TAILWIND_URL" -o "$TAILWIND_CACHE"
  fi
  CHROME_BIN="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
  if [[ -z "$CHROME_BIN" ]]; then
    echo "ERROR: Headless Chrome/Chromium is required to precompile static Tailwind CSS." >&2
    exit 1
  fi
  export CHROME_BIN
fi

node - <<'NODESCRIPT'
const fs = require("fs");
const vm = require("vm");
const { spawn } = require("child_process");

const studioSrc = process.env.STUDIO_SRC;
const repoDir = process.env.REPO_DIR;
const tailwindCache = process.env.TAILWIND_CACHE;
const chromeBin = process.env.CHROME_BIN || "";

const srcHtml = fs.readFileSync(studioSrc, "utf8");
const cdnTag = '<script src="https://www.gstatic.com/antigravity/web/dev/tailwindcss.min.js"></script>';

if (!srcHtml.includes(cdnTag)) {
  if (!srcHtml.includes("pulseobd_theme") || !srcHtml.includes("pulseobd-tailwind-static")) {
    console.error("ERROR: Source HTML is neither a Tailwind CDN template nor a precompiled PulseOBD standalone HTML.");
    process.exit(1);
  }
  const outFiles = [
    repoDir + "/PulseOBD_Studio.html",
    repoDir + "/index.html"
  ];
  for (const out of outFiles) {
    if (fs.realpathSync(studioSrc) !== (fs.existsSync(out) ? fs.realpathSync(out) : "")) {
      fs.writeFileSync(out, srcHtml, "utf8");
    }
    const scripts = [...srcHtml.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)];
    scripts.forEach((m, idx) => {
      const code = m[1].trim();
      if (!code) return;
      new vm.Script(code, { filename: out + "#script" + idx });
    });
    console.log("Synced & verified precompiled standalone HTML:", out, "(" + fs.statSync(out).size + " bytes)");
  }
  process.exit(0);
}

const twJs = fs.readFileSync(tailwindCache, "utf8").replace(/<\/script/gi, "<\\/script");

// 1. Collect all static + dynamic Tailwind utility tokens across HTML and JS literals
const tokenSet = new Set();
function addTokens(str) {
  if (!str) return;
  const cleaned = str.replace(/\$\{[^}]*\}/g, " ");
  for (const tok of cleaned.split(/\s+/)) {
    if (tok.length < 2 || tok.length > 90) continue;
    if (/^(https?:|file:|mailto:|data:)/i.test(tok)) continue;
    if (/\.(html|json|csv|js|ps1|bat|md|svg|png|txt)$/i.test(tok)) continue;
    if (!/^[a-zA-Z0-9_:\-/\[\].%#(),!]+$/.test(tok)) continue;
    const opens = (tok.match(/\[/g) || []).length;
    const closes = (tok.match(/\]/g) || []).length;
    if (opens !== closes || tok.includes("[]")) continue;
    if (!/^(?:2xl:)?(?:[a-z0-9-]+:)*!?-?[a-z][a-z0-9-]*(?:\/[0-9.]+)?(?:\[[^\]]+\])?(?:\/[0-9.]+)?$/.test(tok)) continue;
    tokenSet.add(tok);
  }
}

for (const m of srcHtml.matchAll(/\bclass=["']([^"']+)["']/gi)) {
  addTokens(m[1]);
}
for (const m of srcHtml.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
  const body = m[1];
  for (const s of body.matchAll(/`([^`]*)`/g)) addTokens(s[1]);
  for (const s of body.matchAll(/"([^"\n\\]*(?:\\.[^"\n\\]*)*)"/g)) addTokens(s[1]);
  for (const s of body.matchAll(/'([^'\n\\]*(?:\\.[^'\n\\]*)*)'/g)) addTokens(s[1]);
}

const safelistClasses = [...tokenSet].join(" ").replace(/"/g, "&quot;");
const tmpCompileHtml = `/tmp/__tw_compile_${process.pid}.html`;
const tmpProfileDir = `/tmp/pw_tw_profile_${process.pid}`;

const compileDoc = srcHtml
  .split(cdnTag).join("<script>\n" + twJs + "\n</script>")
  .replace("  <style>", () => '  <style id="pulseobd-base-styles">')
  .replace("</body>", () => `<div id="__tw_safelist" style="display:none" aria-hidden="true" class="${safelistClasses}"></div>\n</body>`);

fs.writeFileSync(tmpCompileHtml, compileDoc, "utf8");
fs.mkdirSync(tmpProfileDir, { recursive: true });

(async () => {
  let chrome = null;
  let ws = null;
  try {
    chrome = spawn(chromeBin, [
      "--headless=new",
      "--disable-gpu",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--remote-debugging-port=0",
      "--user-data-dir=" + tmpProfileDir,
      "about:blank"
    ], { stdio: ["ignore", "pipe", "pipe"] });

    const wsBrowserUrl = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Headless Chrome startup timeout")), 20000);
      const onChunk = (buf) => {
        const m = buf.toString().match(/DevTools listening on (ws:\/\/[^\s]+)/);
        if (m) {
          clearTimeout(timer);
          resolve(m[1]);
        }
      };
      chrome.stderr.on("data", onChunk);
      chrome.stdout.on("data", onChunk);
      chrome.on("exit", (code) => {
        clearTimeout(timer);
        reject(new Error("Chrome exited early with code " + code));
      });
    });

    const port = wsBrowserUrl.match(/:(\d+)\//)[1];
    const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const target = pages.find((p) => p.type === "page") || pages[0];
    if (!target || !target.webSocketDebuggerUrl) {
      throw new Error("No Chrome page target found for CSS compilation");
    }

    ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = reject;
    });

    let seq = 0;
    const pending = new Map();
    const listeners = [];
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && pending.has(msg.id)) {
        const { resolve, reject } = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      } else if (msg.method) {
        for (const fn of listeners) fn(msg);
      }
    };
    const cdp = (method, params = {}) => new Promise((resolve, reject) => {
      const id = ++seq;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });

    await cdp("Page.enable");
    await cdp("Runtime.enable");
    const pageLoaded = new Promise((resolve) => {
      listeners.push((msg) => {
        if (msg.method === "Page.loadEventFired") resolve();
      });
    });
    await cdp("Page.navigate", { url: "file://" + tmpCompileHtml });
    await pageLoaded;

    const evalRes = await cdp("Runtime.evaluate", {
      awaitPromise: true,
      returnByValue: true,
      expression: `(function() {
        document.documentElement.classList.add("dark");
        try { if (typeof renderStaticInfographics === "function") renderStaticInfographics(); } catch (e) {}
        try { if (typeof renderAllVariablesTable === "function") renderAllVariablesTable({ force: true }); } catch (e) {}
        try { if (typeof refreshServiceTab === "function") refreshServiceTab(); } catch (e) {}
        try { if (typeof refreshHistoryTab === "function") refreshHistoryTab(); } catch (e) {}
        try { if (typeof togglePhoneFrame === "function") { togglePhoneFrame(true); togglePhoneFrame(false); } } catch (e) {}
        return new Promise(function(resolve) {
          setTimeout(function() {
            var twStyles = [].slice.call(document.head.querySelectorAll("style")).filter(function(el) {
              return el.id !== "pulseobd-base-styles" && (el.textContent.indexOf("--tw-") >= 0 || el.textContent.indexOf("tailwindcss") >= 0);
            });
            resolve(twStyles.map(function(el) { return el.textContent; }).join("\\n"));
          }, 500);
        });
      })()`
    });

    if (evalRes.exceptionDetails) {
      throw new Error("CSS compilation exception: " + JSON.stringify(evalRes.exceptionDetails));
    }
    const compiledCss = String((evalRes.result && evalRes.result.value) || "").trim();
    if (compiledCss.length < 8000) {
      throw new Error("Compiled Tailwind CSS unexpectedly small (" + compiledCss.length + " bytes)");
    }

    // 2. Transform source HTML -> pure static CSS offline HTML (preserve pulseobd_theme FOUC IIFE)
    const strippedConfigRe = /\n\s*window\.tailwind\s*=\s*window\.tailwind\s*\|\|\s*\{\};\s*\n\s*window\.tailwind\.config\s*=\s*\{[\s\S]*?\n\s*\};/;
    if (!strippedConfigRe.test(srcHtml)) {
      throw new Error("Could not match window.tailwind.config block in source HTML");
    }
    const safeCss = compiledCss.replace(/<\/style>/gi, "<\\/style>");
    const staticHtml = srcHtml
      .replace("  " + cdnTag + "\n", () => "")
      .split(cdnTag).join("")
      .replace(strippedConfigRe, () => "")
      .replace("  <style>", () => `  <style id="pulseobd-tailwind-static">\n${safeCss}\n  </style>\n  <style>`);

    if (staticHtml.includes("tailwindcss.min.js") || staticHtml.includes("window.tailwind")) {
      throw new Error("Tailwind runtime artifacts were not cleanly stripped");
    }
    if (!staticHtml.includes("pulseobd_theme") || !staticHtml.includes("pulseobd-tailwind-static")) {
      throw new Error("Required theme init script or static stylesheet missing after transform");
    }

    const outFiles = [
      repoDir + "/PulseOBD_Studio.html",
      repoDir + "/index.html"
    ];
    for (const out of outFiles) {
      fs.writeFileSync(out, staticHtml, "utf8");
      const scripts = [...staticHtml.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)];
      scripts.forEach((m, idx) => {
        const code = m[1].trim();
        if (!code) return;
        new vm.Script(code, { filename: out + "#script" + idx });
      });
      console.log(
        "Built & verified (static CSS " + compiledCss.length + " bytes, " + tokenSet.size + " tokens):",
        out,
        "(" + fs.statSync(out).size + " bytes)"
      );
    }
  } finally {
    if (ws) { try { ws.close(); } catch {} }
    if (chrome && !chrome.killed) { try { chrome.kill("SIGKILL"); } catch {} }
    try { fs.rmSync(tmpCompileHtml, { force: true }); } catch {}
    try { fs.rmSync(tmpProfileDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 80 }); } catch {}
  }
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
NODESCRIPT

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo "=== Build-only complete (Drive & GitHub sync skipped) ==="
  exit 0
fi

echo "=== [4/5] Updating Google Drive OBD Bluetooth folder, bridge & vehicle_history/ ==="
gdrive mutate update "1ErHDt-dQW86WOMwN2DM27kAOZ2n-dns-" "$REPO_DIR/PulseOBD_Studio.html" --mime-type "text/html"
gdrive mutate update "1rxttCdZx1OGBIGJWxrqNnhDWenRPpjd2" "$REPO_DIR/bridge/start_obd_web_bridge.ps1" --mime-type "text/plain"
gdrive mutate update "1vjjopceo9hM92F1tfIHdTXGcZdAJVjUG" "$REPO_DIR/bridge/start_obd_web_bridge.ps1" --mime-type "text/plain"
gdrive mutate update "1ZaQvDXSopHY_IvJbtH6WirzMJdqyeQyz" "$REPO_DIR/Launch_PulseOBD.bat" --mime-type "text/plain"
gdrive mutate update "1_GGRDObOc8TJCE5QQ8AbKLCU7o2NwBNQ" "$REPO_DIR/README.md" --mime-type "text/markdown"
gdrive mutate update "1nHAs0fUW0haAjmbqcIJ1Y1YHmEq6-fwk" "$REPO_DIR/manifest.json" --mime-type "application/json"

node -e '
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT_DRIVE_ID = "1yj79G8flllc1YV9AV7q_ZobILwT4gTxx";
const LOCAL_VH = path.join(process.env.REPO_DIR, "vehicle_history");

function gdriveJson(args) {
  const out = execFileSync("gdrive", args, { encoding: "utf8" }).trim();
  if (!out) return null;
  try { return JSON.parse(out); } catch {
    const m = out.match(/(\[[\s\S]*\]|\{[\s\S]*\})/);
    if (m) return JSON.parse(m[1]);
    return null;
  }
}

function listDriveFolder(folderId) {
  const res = gdriveJson(["readonly", "ls", folderId, "--max", "0", "--json"]);
  return Array.isArray(res) ? res : [];
}

function ensureDriveFolder(parentId, name) {
  const entries = listDriveFolder(parentId);
  const existing = entries.find(e => e.name === name && e.mimeType === "application/vnd.google-apps.folder");
  if (existing && existing.id) return existing.id;
  const created = gdriveJson(["mutate", "mkdir", name, "--parent", parentId, "--json"]);
  if (created && created.id) return created.id;
  if (created && created.file && created.file.id) return created.file.id;
  const retry = listDriveFolder(parentId).find(e => e.name === name && e.mimeType === "application/vnd.google-apps.folder");
  if (!retry || !retry.id) throw new Error("Failed to resolve Drive folder: " + name);
  return retry.id;
}

function getMimeType(filePath) {
  const lower = filePath.toLowerCase();
  if (lower.endsWith(".json")) return "application/json";
  if (lower.endsWith(".csv")) return "text/csv";
  if (lower.endsWith(".html")) return "text/html";
  if (lower.endsWith(".md")) return "text/markdown";
  if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
  if (lower.endsWith(".png")) return "image/png";
  if (lower.endsWith(".webp")) return "image/webp";
  return "text/plain";
}

function mirrorDirectory(localDir, driveFolderId) {
  const remoteEntries = listDriveFolder(driveFolderId);
  const items = fs.readdirSync(localDir, { withFileTypes: true });
  for (const ent of items) {
    const localPath = path.join(localDir, ent.name);
    if (ent.isDirectory()) {
      const sub = remoteEntries.find(e => e.name === ent.name && e.mimeType === "application/vnd.google-apps.folder");
      const subId = (sub && sub.id) ? sub.id : ensureDriveFolder(driveFolderId, ent.name);
      mirrorDirectory(localPath, subId);
    } else if (ent.isFile()) {
      const mime = getMimeType(localPath);
      const existingFile = remoteEntries.find(e => e.name === ent.name && e.mimeType !== "application/vnd.google-apps.folder");
      if (existingFile && existingFile.id) {
        execFileSync("gdrive", ["mutate", "update", existingFile.id, localPath, "--mime-type", mime], { stdio: "inherit" });
        console.log("Updated Drive vehicle_history file:", ent.name, "(" + existingFile.id + ")");
      } else {
        const up = gdriveJson(["mutate", "upload", localPath, "--parent", driveFolderId, "--mime-type", mime, "--json"]);
        const upId = (up && (up.id || (up.file && up.file.id))) || "uploaded";
        console.log("Uploaded Drive vehicle_history file:", ent.name, "(" + upId + ")");
      }
    }
  }
}

if (fs.existsSync(LOCAL_VH)) {
  const vhFolderId = ensureDriveFolder(ROOT_DRIVE_ID, "vehicle_history");
  mirrorDirectory(LOCAL_VH, vhFolderId);
  console.log("Drive vehicle_history/ mirror complete (folder " + vhFolderId + ")");
}
'

echo "=== [5/5] Committing & pushing to GitHub main + waiting for Pages build ==="
git add -A
if ! git diff --cached --quiet; then
  git commit -m "$COMMIT_MSG"
else
  echo "No git changes to commit."
fi

git push origin main
HEAD_SHA="$(git rev-parse HEAD)"
echo "Waiting for GitHub Pages build of commit $HEAD_SHA..."
for i in $(seq 1 30); do
  BUILD_JSON="$(gh api repos/tsoanelomodise-arch/pulseobd-telemetry/pages/builds/latest 2>/dev/null || echo '{}')"
  INFO="$(printf '%s' "$BUILD_JSON" | HEAD_SHA="$HEAD_SHA" node -e 'const fs=require("fs"); try{const j=JSON.parse(fs.readFileSync(0,"utf8")); console.log((j.status||"unknown")+"|"+(j.commit||"none")+"|"+(j.commit===process.env.HEAD_SHA?"match":"stale"));}catch{console.log("unknown|none|stale");}')"
  echo "  [$i/30] GitHub Pages: $INFO"
  if [[ "$INFO" == built\|*\|match ]]; then
    echo "GitHub Pages build completed cleanly for $HEAD_SHA!"
    break
  elif [[ "$INFO" == errored\|*\|match ]]; then
    echo "ERROR: GitHub Pages build failed:" >&2
    printf '%s\n' "$BUILD_JSON" >&2
    exit 1
  fi
  sleep 4
done

echo "=== All views synced cleanly! ==="
