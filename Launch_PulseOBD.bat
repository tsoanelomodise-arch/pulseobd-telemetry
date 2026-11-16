@echo off
title PulseOBD — Multi-VIN Read-Only Telemetry & Project Archive Bridge
echo ============================================================================
echo   PulseOBD — Strictly Read-Only OBD-II Studio + Project Archive Bridge
echo   Default COM Port: COM3 @ 38400 8N1 (Auto Mode 01/06/09/UDS Read-Only)
echo   Project History : .\vehicle_history\^<VIN^>\ (Auto-Discovers Each Car)
echo   Cloud Relay     : Optional Auto-TX (Firebase / ntfy / Supabase)
echo ============================================================================
echo.
echo [1] Opening PulseOBD_Studio.html in your default browser...
start "" "%~dp0PulseOBD_Studio.html"
echo.
echo [2] Starting COM3 Read-Only Bridge on http://localhost:8765 ...
echo     (Per-VIN History + BT Audio Coexistence + Auto VIN Discovery Active)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge\start_obd_web_bridge.ps1"
if errorlevel 1 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_obd_web_bridge.ps1"
pause
