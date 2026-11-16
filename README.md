# PulseOBD — Cloud-Connected OBD-II Mobile & Web Telemetry Studio

**Strictly Read-Only** Apple/Adobe-inspired OBD-II diagnostic & live drive telemetry studio supporting all **124 available vehicle variables** (Mode 01/02/03/06/07/09/0A + UDS `0x22`), **6 synchronized zero-jitter real-time charts**, **Drive History & IndexedDB offline persistence**, **Bluetooth Multi-Device & Car Audio Coexistence**, and **Smart Auto-Connect Real-Time Firebase Telemetry Streaming**.

## Features
- **Strictly Read-Only Safety Firewall:** Permanently blocks `Mode 04` / `14`, ECU resets, coding, adaptations, and write commands across both Web Bluetooth/Serial JS and [`bridge/start_obd_web_bridge.ps1`](bridge/start_obd_web_bridge.ps1).
- **Smart Auto-Connect Firebase Telemetry & History:**
  - **Firebase Realtime Database (Default):** Automatically connects whenever internet is available, saves live telemetry (`latest.json`) and timestamped trip logs (`history/<sessionId>/frames.json`), buffers frames offline in IndexedDB `cloudQueue`, and auto-flushes as soon as mobile signal returns.
  - **Private Endpoint Handling:** Paste your Firebase RTDB URL once in the **Cloud** tab — it saves privately in `localStorage` on your device and is never stored in public GitHub or Google Drive files. On Windows, you can alternatively place a gitignored `bridge/firebase.local.json` file or set `PULSEOBD_FIREBASE_URL`.
  - **Fallbacks:** Instant `ntfy.sh` HTTPS/SSE, Supabase REST table, or Custom HTTPS Webhook.
- **Bluetooth RF Coexistence & Multi-Device Support:** Uses `writeValueWithoutResponse`, cooperative inter-PID gaps (`Coexist` / `Audio Priority`), and a 15-second **Pairing Yield** button so your phone stays connected to car stereo audio (A2DP), hands-free calls (HFP), earbuds, smartwatch, or extra BLE sensors alongside OBD-II.
- **Synchronized Multi-View Deployment:** Run `./sync_all_views.sh` to validate JS, rebuild offline standalone `PulseOBD_Studio.html` & `index.html`, update Google Drive HTML + PowerShell bridge scripts, and deploy to GitHub Pages.

## Usage Examples for `start_obd_web_bridge.ps1`
```powershell
# 1. Auto Mode (uses private bridge/firebase.local.json or PULSEOBD_FIREBASE_URL if present, else ntfy.sh)
.\bridge\start_obd_web_bridge.ps1

# 2. Explicit Firebase Realtime Database Stream (Live + /history/frames)
.\bridge\start_obd_web_bridge.ps1 -CloudProvider firebase -CloudUrl "https://your-project-default-rtdb.firebaseio.com" -CloudChannel "pulseobd-polo-aavzzz6rzhu112564-7d4e9b"

# 3. Supabase Table Stream
.\bridge\start_obd_web_bridge.ps1 -CloudProvider supabase -CloudUrl "https://your-ref.supabase.co" -SupabaseTable "pulseobd_telemetry" -CloudApiKey "<SUPABASE_ANON_KEY>" -CloudChannel "my-polo-stream"
```
