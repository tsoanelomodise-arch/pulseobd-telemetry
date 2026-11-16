# PulseOBD — Cloud-Connected OBD-II Mobile & Web Telemetry Studio

**Strictly Read-Only** Apple/Adobe-inspired OBD-II diagnostic & live drive telemetry studio supporting all **124 available vehicle variables** (Mode 01/02/03/06/07/09/0A + UDS `0x22`), **6 synchronized real-time charts**, and **Real-Time Cloud Telemetry Streaming**.

## Features
- **Strictly Read-Only Safety Firewall:** Permanently blocks `Mode 04` / `14`, ECU resets, coding, adaptations, and write commands across both Web Bluetooth/Serial JS and [`start_obd_web_bridge.ps1`](bridge/start_obd_web_bridge.ps1).
- **Real-Time Cloud Telemetry Relay:** Stream live vehicle gauges, RPM, speed, fuel trims, coolant/CAT temps, boost/rail pressure, and all 124 variables over mobile data via:
  1. **Zero-Setup Cloud Pub/Sub (`ntfy.sh` HTTPS/SSE)** — works immediately out-of-the-box.
  2. **Firebase Realtime Database (`PUT` + SSE live stream)** — point to your `https://<project>-default-rtdb.firebaseio.com` URL.
  3. **Supabase Table (`REST POST/GET`)** — copy the 1-click SQL schema inside the Cloud Stream tab and provide your project URL + anon key.
  4. **Custom HTTPS Webhook / Worker (`POST/GET`)**.
- **In-Vehicle Connections:**
  - **Mobile / Browser Direct:** Web Bluetooth (`BLE GATT 0xFFF0 / 0xFFE0 / Nordic UART`) or Web Serial (`COM3 38400 8N1`). Automatically starts broadcasting online when connected!
  - **Windows Laptop in Car:** Run [`Launch_PulseOBD.bat`](Launch_PulseOBD.bat) or [`bridge/start_obd_web_bridge.ps1`](bridge/start_obd_web_bridge.ps1) with `-CloudProvider`, `-CloudUrl`, `-CloudApiKey`, and `-CloudChannel`.

## Usage Examples for `start_obd_web_bridge.ps1`
```powershell
# 1. Default Zero-Setup Cloud Stream (ntfy.sh)
.\bridge\start_obd_web_bridge.ps1 -CloudProvider ntfy -CloudChannel "pulseobd-polo-aavzzz6rzhu112564-7d4e9b"

# 2. Firebase Realtime Database Stream
.\bridge\start_obd_web_bridge.ps1 -CloudProvider firebase -CloudUrl "https://your-project-default-rtdb.firebaseio.com" -CloudChannel "my-polo-stream"

# 3. Supabase Table Stream
.\bridge\start_obd_web_bridge.ps1 -CloudProvider supabase -CloudUrl "https://your-ref.supabase.co" -SupabaseTable "pulseobd_telemetry" -CloudApiKey "<SUPABASE_ANON_KEY>" -CloudChannel "my-polo-stream"
```
