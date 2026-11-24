# PulseOBD — Multi-Vehicle Cloud & Project-Folder OBD-II Telemetry Studio

**Strictly Read-Only** Apple/Adobe-inspired OBD-II diagnostic & live drive telemetry studio supporting all **124 available vehicle variables** (Mode 01/02/03/06/07/09/0A + UDS `0x22`), **6 synchronized zero-jitter real-time charts**, **per-VIN project folder archiving** (`vehicle_history/<VIN>/`), **Bluetooth Multi-Device & Car Audio Coexistence**, and **optional VIN-Based Cloud Telemetry Streaming**.

## Per-Vehicle Project Folder Archiving (`vehicle_history/`)
- **Individual Record per New Vehicle:** Whenever a vehicle is connected via COM3 Bridge, Web Bluetooth, Web Serial, JSON dump import, or the `+ Add / Switch Vehicle` button, PulseOBD automatically identifies its VIN (`0902` / `22F190`), ECU part number (`22F187`), engine code (`22F197`), CALID (`0904`), and CVN (`0906`), creating an isolated subfolder:
  - `vehicle_history/vehicles_index.json` — Master index of all recorded vehicles & latest summaries
  - `vehicle_history/<VIN>/vehicle_profile.json` — ECU metadata & trip index for that vehicle
  - `vehicle_history/<VIN>/latest.json` — Most recent telemetry frame for that VIN
  - `vehicle_history/<VIN>/sessions/<sessionId>.json` — Full timestamped drive/diagnostic logs (plus `rawDump` frames when captured)
  - `vehicle_history/<VIN>/service_log.json` — Per-VIN Service & Maintenance Log, odometer checkpoints, and read-only pre-service OBD-II inspection snapshots
- **Browser Direct Project Folder Link:** On desktop/Android Chrome or Edge, click **Link Project Folder** in the **History** tab and select your project folder (or `vehicle_history/`) so browser BLE/Serial sessions and Service records write individual JSON files directly to disk alongside `PulseOBD_DriveDB` IndexedDB.
- **Automatic Windows Bridge Persistence & HTTP API:** [`bridge/start_obd_web_bridge.ps1`](bridge/start_obd_web_bridge.ps1) automatically queries `0902`/`0904`/`0906`/`090A`/`22F187..F1A3` at startup, writes into `vehicle_history/<VIN>/`, and exposes CORS-enabled endpoints:
  - `GET /api/live` & `GET /api/snapshot` — Live telemetry stream with active vehicle & Bluetooth coexistence metadata (`btCoexist`)
  - `POST /api/bt-yield` & `POST /api/bt-unlock` & `POST /api/bt-resume` & `POST /api/bt-config` — Cooperative BT RF yield (default 20s), manual COM3 release (`Unlock`), instant resume, and live profile switching (`coexist`, `audio_priority`, `shared_release`, `performance`)
  - `GET /api/vehicles` — Master `vehicles_index.json`
  - `GET /api/vehicle-history?vin=<VIN>[&session=<ID>]` — Per-VIN profile, latest snapshot, or full session frames
  - `POST /api/save-history` — Persist browser-recorded sessions straight into `vehicle_history/<VIN>/`
  - `GET /api/service-log?vin=<VIN>` & `POST /api/save-service` — Read and persist per-VIN maintenance history (`vehicle_history/<VIN>/service_log.json`)
  - `GET /vehicle_history/...` — Static access to archived JSON files

## Additional Features
- **Vehicle Service & Automated Pre-Service Health Engine (`Service` Tab):** Evaluates live/captured OBD-II telemetry (`0101` DTCs & readiness, `0130`/`0131` clear-code audit, `0142`/`ATRV` 12V battery & alternator health, coolant thermal balance, fuel trims + HPFP rail pressure, Mode 06 `06A2–06A5` cylinder EWMA misfires & `0641/0642` O2 heater resistance, fuel reserve), displays copy-ready ECU/engine parts reference (`04E906027LH` / `R4 1.2l TFS`), tracks maintenance intervals with manual odometer entry (transparently flagging OEM cluster/CAN-gateway boundaries such as `22 F4A6`), supports uploading or camera-capturing service photos/receipts with inline thumbnail & full-screen lightbox previews on saved records, and archives per-VIN maintenance records to IndexedDB, `vehicle_history/<VIN>/service_log.json`, and optional Firebase (`/vehicles/<VIN>/service_log.json`) with JSON/CSV export.
- **Strictly Read-Only Safety Firewall:** Permanently blocks `Mode 04` / `14`, ECU resets, coding, adaptations, and write commands across both Web Bluetooth/Serial JS and [`bridge/start_obd_web_bridge.ps1`](bridge/start_obd_web_bridge.ps1).
- **Authentic Stopped & Engine-Off Telemetry:** Static captures and stopped/engine-off states stay frozen without fake sine motion and clearly separate active sensors (`ATRV` Pin 16 battery voltage, barometric/resting MAP, fuel tank level, thermal sensors, KOEO pedal, BT/Cloud) from stopped engine subsystems (`0 RPM`, `0 km/h`, `0.00 L/h` fuel flow, alternator off, closed-loop O2 off).
- **Optional VIN-Based Cloud Sync (Firebase / ntfy / Supabase / Webhook):** Project folder storage works 100% locally without any cloud configuration. Whenever desired, apply or paste a Firebase RTDB URL once (stored privately in browser `localStorage` or untracked `bridge/firebase.local.json`) to auto-sync `/vehicles/<VIN>/latest.json` and `/history/`.
- **Keep Mobile Screen Active While Running:** Automatically acquires the Screen Wake Lock API on startup, re-arms on return from background/tab switch or first touch, provides a 1-tap `SCREEN ON` pill in the header and `Bluetooth` tab, and falls back to a silent zero-audio loop (`disableRemotePlayback`) on browsers/WebViews without native Wake Lock without interrupting car Bluetooth audio.
- **Bluetooth Multi-Device Coexistence & Port Unlock (Android / iOS / Windows):** Uses a serialized GATT command FIFO (`writeValueWithoutResponse`), bounded `gatt.connect()` cancellation timeouts, pre-scan RF settle pauses before opening device pickers, true post-poll RF idle rest windows (`550ms`–`2200ms`), `Unlock / Release BT` + `Yield 20s` buttons (releasing both browser GATT/Serial and Windows `COM3` via `/api/bt-unlock` / `/api/bt-yield`), and **Shared BT Unlock (`shared_release` / `-ReleaseBetweenPolls`)** so car stereo audio (A2DP), hands-free calls (HFP), earbuds, smartwatches, and extra BLE sensors never get blocked.
- **Synchronized Multi-View Deployment:** Run `./sync_all_views.sh` to validate JS, audit zero private URLs, rebuild offline standalone `PulseOBD_Studio.html` & `index.html`, mirror `vehicle_history/` + HTML + bridge files to Google Drive, and deploy to GitHub Pages.

## Usage Examples for `start_obd_web_bridge.ps1`
```powershell
# 1. Default Project Folder Archive + Balanced BT Coexistence (750ms RF rest after fast 8-PID sweep)
.\bridge\start_obd_web_bridge.ps1

# 2. Shared BT Unlock Mode (opens COM3 per fast burst, closes COM3 between polls so Windows BT pairs any 2nd Classic device freely)
.\bridge\start_obd_web_bridge.ps1 -BtCoexistMode shared_release -ReleaseBetweenPolls $true

# 3. Audio / Multi-BT Priority Profile (48ms inter-PID gap + 1100ms true idle rest)
.\bridge\start_obd_web_bridge.ps1 -BtCoexistMode audio_priority

# 4. Explicit VIN Firebase Realtime Database Stream (/vehicles/<VIN>/latest.json + /history/)
.\bridge\start_obd_web_bridge.ps1 -CloudProvider firebase -CloudUrl "https://your-project-default-rtdb.firebaseio.com" -CloudChannel "AAVZZZ6RZHU112564"

# 5. Supabase Table Stream
.\bridge\start_obd_web_bridge.ps1 -CloudProvider supabase -CloudUrl "https://your-ref.supabase.co" -SupabaseTable "pulseobd_telemetry" -CloudApiKey "<SUPABASE_ANON_KEY>" -CloudChannel "AAVZZZ6RZHU112564"
```
