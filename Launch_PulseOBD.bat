@echo off
title PulseOBD — VW Polo 1.2 TSI Read-Only Telemetry & Cloud Bridge
echo ============================================================================
echo   PulseOBD — Read-Only OBD-II Telemetry Studio + Online Cloud Relay
echo   Adapter: OBDII (00:10:CC:4F:36:03) on COM3 @ 38400 baud (Strictly Read-Only)
echo   Cloud Channel: pulseobd-polo-aavzzz6rzhu112564-7d4e9b (ntfy.sh HTTPS/SSE)
echo ============================================================================
echo.
echo [1] Opening PulseOBD_Studio.html in your default browser...
start "" "%~dp0PulseOBD_Studio.html"
echo.
echo [2] Starting COM3 Read-Only Bridge on http://localhost:8765 + Cloud TX...
echo     (Streams to local Wi-Fi AND broadcasts live online for remote viewing)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge\start_obd_web_bridge.ps1"
if errorlevel 1 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_obd_web_bridge.ps1"
pause
