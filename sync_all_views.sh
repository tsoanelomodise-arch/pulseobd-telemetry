#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="/home/antigravity/.gemini/jetski/brain/v1/default/jetski_remote_agents_3p/da11f8e9-2af2-4cb6-bd05-445122ca51c7"
STUDIO_SRC="${STUDIO_SRC:-$ARTIFACT_DIR/obd_drive_studio.html}"
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

echo "=== [3/5] Building standalone offline PulseOBD_Studio.html & index.html ==="
if [[ ! -s "$TAILWIND_CACHE" ]]; then
  echo "Downloading Tailwind standalone runtime to $TAILWIND_CACHE..."
  curl -fsSL "$TAILWIND_URL" -o "$TAILWIND_CACHE"
fi

node -e '
const fs = require("fs");
const vm = require("vm");
const srcHtml = fs.readFileSync(process.env.STUDIO_SRC, "utf8");
const tw = fs.readFileSync(process.env.TAILWIND_CACHE, "utf8").replace(/<\/script/gi, "<\\/script");
const tag = "<script src=\"https://www.gstatic.com/antigravity/web/dev/tailwindcss.min.js\"></script>";
if (!srcHtml.includes(tag)) {
  console.error("ERROR: Expected Tailwind CDN <script> tag not found in source HTML.");
  process.exit(1);
}
const inlined = srcHtml.split(tag).join("<script>\n" + tw + "\n</script>");
const outFiles = [
  process.env.REPO_DIR + "/PulseOBD_Studio.html",
  process.env.REPO_DIR + "/index.html"
];
for (const out of outFiles) {
  fs.writeFileSync(out, inlined, "utf8");
  const scripts = [...inlined.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)];
  scripts.forEach((m, idx) => {
    const code = m[1].trim();
    if (!code) return;
    new vm.Script(code, { filename: out + "#script" + idx });
  });
  console.log("Built & verified:", out, "(" + fs.statSync(out).size + " bytes)");
}
'

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
  if (filePath.endsWith(".json")) return "application/json";
  if (filePath.endsWith(".csv")) return "text/csv";
  if (filePath.endsWith(".html")) return "text/html";
  if (filePath.endsWith(".md")) return "text/markdown";
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
