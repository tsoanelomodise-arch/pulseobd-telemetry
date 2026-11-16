# PulseOBD — Cloud-Connected OBD-II Mobile & Web Telemetry Studio

**Strictly Read-Only** Apple/Adobe-inspired OBD-II diagnostic & live drive telemetry studio supporting all **124 available vehicle variables** (Mode 01/02/03/06/07/09/0A + UDS `0x22`), **6 synchronized zero-jitter real-time charts**, **Drive History & IndexedDB offline persistence**, **Bluetooth Multi-Device & Car Audio Coexistence**, and **Smart Auto-Connect Real-Time Firebase Telemetry Streaming**.

## Features
- **Strictly Read-Only Safety Firewall:** Permanently blocks `Mode 04` / `14`, ECU resets, coding, adaptations, and write commands across both Web Bluetooth/Serial JS and [`bridge/start_obd_web_bridge.ps1`](bridge/start_obd_web_bridge.ps1).
- **Authentic Stopped & Engine-Off Telemetry:** Static captures and stopped/engine-off states stay frozen without fake sine motion and clearly separate active sensors (`ATRV` Pin 16 battery voltage, barometric/resting MAP, fuel tank level, thermal sensors, KOEO pedal, BT/Firebase) from stopped engine subsystems (`0 RPM`, `0 km/h`, `0.00 L/h` fuel flow, alternator off, closed-loop O2 off).
- **Smart Auto-Connect VIN-Based Firebase Telemetry & History:**
  - **Firebase Realtime Database (Default):** Automatically connects whenever internet is available, routes live telemetry (`/vehicles/<VIN>/latest.json`) and trip logs (`/vehicles/<VIN>/history/<sessionId>/frames.json`), buffers frames offline in IndexedDB `cloudQueue`, and auto-flushes as soon as signal returns.
  - **One-Click VIN Endpoint & Private Storage:** Use **Apply VIN Firebase URL** in the **Cloud** tab or paste your Firebase RTDB URL once — it saves privately in `localStorage` and is never stored in public GitHub or Google Drive files. On Windows, click **Download `bridge/firebase.local.json`** or set `PULSEOBD_FIREBASE_URL`.
  - **Fallbacks:** Instant `ntfy.sh` HTTPS/SSE (`pulseobd-<VIN>`), Supabase REST table, or Custom HTTPS Webhook.
- **Bluetooth RF Coexistence & Multi-Device Support:** Uses `writeValueWithoutResponse`, cooperative inter-PID gaps (`Coexist` / `Audio Priority`), and a 15-second **Pairing Yield** button so your phone stays connected to car stereo audio (A2DP), hands-free calls (HFP), earbuds, smartwatch, or extra BLE sensors alongside OBD-II.
- **Synchronized Multi-View Deployment:** Run `./sync_all_views.sh` to validate JS, rebuild offline standalone `PulseOBD_Studio.html` & `index.html`, update Google Drive HTML + PowerShell bridge scripts, and deploy to GitHub Pages.

## Usage Examples for `start_obd_web_bridge.ps1`
```powershell
# 1. Auto Mode (uses private bridge/firebase.local.json or PULSEOBD_FIREBASE_URL if present, else ntfy.sh)
.\bridge\start_obd_web_bridge.ps1

# 2. Explicit VIN Firebase Realtime Database Stream (/vehicles/AAVZZZ6RZHU112564/latest.json + /history/)
.\bridge\start_obd_web_bridge.ps1 -CloudProvider firebase -CloudUrl "https://your-project-default-rtdb.firebaseio.com" -CloudChannel "AAVZZZ6RZHU112564"

# 3. Supabase Table Stream
.\bridge\start_obd_web_bridge.ps1 -CloudProvider supabase -CloudUrl "https://your-ref.supabase.co" -SupabaseTable "pulseobd_telemetry" -CloudApiKey "<SUPABASE_ANON_KEY>" -CloudChannel "AAVZZZ6RZHU112564"
```
