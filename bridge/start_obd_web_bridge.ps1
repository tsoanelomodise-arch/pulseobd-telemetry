<#
.SYNOPSIS
    PulseOBD — Strictly Read-Only All-Variable Windows Bluetooth (COM3) Bridge + Firebase Auto-Sync Relay
.DESCRIPTION
    Connects to the paired OBDII adapter (00:10:CC:4F:36:03, ELM327 v2.1) on COM3 at 38400 baud (8N1),
    includes WinRT uncached RFCOMM service wake-up to prevent Windows semaphore timeouts,
    enforces the Mandatory Read-Only Operational Rule (blocks Mode 04 / clear / write / reset commands),
    uses cooperative Bluetooth RF pacing (-CoexistGapMs) so car audio / headphones / other BT links stay stable,
    discovers and collects ALL available variables across:
      - Adapter AT queries (ATZ, ATI, AT@1, ATRV, ATDP, ATDPN)
      - All 40 Mode 01 PIDs (0100, 0120, 0140 bitmasks + all 37 live/status PIDs 0101..0156)
      - Mode 02 Freeze Frame support (020000)
      - Mode 03 (Stored), Mode 07 (Pending), Mode 0A (Permanent) DTCs
      - All 17 Mode 06 MIDs (0600..06A0 bitmasks + 0601..06A5 yielding all 18 component tests)
      - All 6 Mode 09 PIDs (0900..090A including all 20 IUMPR counters in 0908)
      - All UDS 0x22 ReadDataByIdentifier DIDs on 7E0 -> 7E8 (F187..2001)
    Serves the PulseOBD Web & Mobile app and /api/live JSON stream on port 8765, saves local
    live_telemetry_latest.json, AND automatically connects to Firebase RTDB (when configured via
    -CloudUrl, $env:PULSEOBD_FIREBASE_URL, or untracked local firebase.local.json) or ntfy/Supabase/Webhook
    to save live frames (latest.json) + trip history (history/<sessionId>/frames.json) with dead-zone buffering.
#>
param(
    [string]$ComPort = 'COM3',
    [int]$BaudRate = 38400,
    [int]$HttpPort = 8765,
    [bool]$EnableCloudStream = $true,
    [ValidateSet('auto','ntfy','firebase','supabase','webhook')]
    [string]$CloudProvider = 'auto',
    [string]$CloudChannel = 'AAVZZZ6RZHU112564',
    [string]$CloudUrl = '',
    [string]$SupabaseTable = 'pulseobd_telemetry',
    [string]$CloudApiKey = '',
    [int]$PollIntervalMs = 900,
    [int]$CloudIntervalMs = 3000,
    [int]$CoexistGapMs = 15,
    [bool]$SaveLocalJson = $true,
    [bool]$SaveCloudHistory = $true
)

$ErrorActionPreference = 'Stop'
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http
} catch {}

# Auto-load private local Firebase configuration (gitignored firebase.local.json or env vars)
$LocalConfigCandidates = @(
    (Join-Path $PSScriptRoot 'firebase.local.json'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'firebase.local.json')
)
foreach ($cfgFile in $LocalConfigCandidates) {
    if (Test-Path $cfgFile) {
        try {
            $localCfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
            if (-not $CloudUrl -and $localCfg.url) { $CloudUrl = [string]$localCfg.url }
            if ($localCfg.channel) { $CloudChannel = [string]$localCfg.channel }
            if (-not $CloudApiKey -and $localCfg.auth) { $CloudApiKey = [string]$localCfg.auth }
            if ($CloudProvider -eq 'auto' -and $localCfg.provider) { $CloudProvider = [string]$localCfg.provider }
            Write-Host "Loaded private cloud config from $cfgFile" -ForegroundColor DarkGreen
            break
        } catch {
            Write-Warning "Could not parse ${cfgFile}: $($_.Exception.Message)"
        }
    }
}
if (-not $CloudUrl -and $env:PULSEOBD_FIREBASE_URL) { $CloudUrl = $env:PULSEOBD_FIREBASE_URL }
if (-not $CloudApiKey -and $env:PULSEOBD_FIREBASE_AUTH) { $CloudApiKey = $env:PULSEOBD_FIREBASE_AUTH }
if ($env:PULSEOBD_CLOUD_CHANNEL) { $CloudChannel = $env:PULSEOBD_CLOUD_CHANNEL }

if ($CloudProvider -eq 'auto') {
    if ($CloudUrl -and ($CloudUrl -match 'firebaseio\.com|firebasedatabase\.app')) {
        $CloudProvider = 'firebase'
    } else {
        $CloudProvider = 'ntfy'
    }
}

$TripSessionId = 'drive-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$ResolvedCloudMethod = 'POST'
$ResolvedCloudUrl = ''
$FirebaseLatestUrl = ''
$FirebaseHistoryFramesUrl = ''
$FirebaseHistoryMetaUrl = ''

function Add-FirebaseAuthQuery {
    param([string]$Url, [string]$Auth)
    if (-not $Url -or -not $Auth) { return $Url }
    $sep = if ($Url.Contains('?')) { '&' } else { '?' }
    return "${Url}${sep}auth=$([Uri]::EscapeDataString($Auth))"
}

if ($CloudProvider -eq 'ntfy') {
    $ntfyTopic = if ($CloudChannel -match '^(?i)pulseobd-') { $CloudChannel } else { "pulseobd-$CloudChannel" }
    $ResolvedCloudUrl = "https://ntfy.sh/$([Uri]::EscapeDataString($ntfyTopic))"
    $ResolvedCloudMethod = 'POST'
} elseif ($CloudProvider -eq 'firebase') {
    $fbBase = $CloudUrl.TrimEnd('/')
    if ($fbBase) {
        $safeCh = [Uri]::EscapeDataString($CloudChannel)
        if ($fbBase.EndsWith('/latest.json')) {
            $prefix = $fbBase.Substring(0, $fbBase.Length - 12)
        } elseif ($fbBase.EndsWith('.json')) {
            $prefix = $fbBase.Substring(0, $fbBase.Length - 5)
        } elseif ($fbBase -match '/vehicles/[^/]+$' -or $fbBase -match '/pulseobd/[^/]+$') {
            $prefix = $fbBase
        } elseif ($fbBase -match '/vehicles$') {
            $prefix = "$fbBase/$safeCh"
        } else {
            $prefix = "$fbBase/vehicles/$safeCh"
        }
        $FirebaseLatestUrl = Add-FirebaseAuthQuery -Url "$prefix/latest.json" -Auth $CloudApiKey
        $FirebaseHistoryFramesUrl = Add-FirebaseAuthQuery -Url "$prefix/history/$TripSessionId/frames.json" -Auth $CloudApiKey
        $FirebaseHistoryMetaUrl = Add-FirebaseAuthQuery -Url "$prefix/history/$TripSessionId/meta.json" -Auth $CloudApiKey
        $ResolvedCloudUrl = $FirebaseLatestUrl
        $ResolvedCloudMethod = 'PUT'
    }
} elseif ($CloudProvider -eq 'supabase') {
    $sbBase = $CloudUrl.TrimEnd('/')
    if ($sbBase) {
        $ResolvedCloudUrl = "$sbBase/rest/v1/$([Uri]::EscapeDataString($SupabaseTable))"
    }
    $ResolvedCloudMethod = 'POST'
} else {
    $ResolvedCloudUrl = $CloudUrl.Trim()
    $ResolvedCloudMethod = 'POST'
}

function Refresh-ObdRfcomm {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
        function Await($WinRtTask, $ResultType) {
            $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
            $netTask = $asTask.Invoke($null, @($WinRtTask))
            $netTask.Wait(-1) | Out-Null
            $netTask.Result
        }
        [Windows.Devices.Bluetooth.BluetoothDevice,Windows.Devices.Bluetooth,ContentType=WindowsRuntime] | Out-Null
        [Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceService,Windows.Devices.Bluetooth,ContentType=WindowsRuntime] | Out-Null
        $dev = Await ([Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync(0x0010CC4F3603)) ([Windows.Devices.Bluetooth.BluetoothDevice])
        $null = Await ($dev.GetRfcommServicesForIdAsync([Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId]::SerialPort, [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult])
    } catch {
        Write-Warning "RFCOMM wake-up note: $($_.Exception.Message)"
    }
}

function Test-ReadOnlyCommand {
    param([string]$Cmd)
    $c = ($Cmd -replace '\s+', '').ToUpperInvariant()
    if ($c.StartsWith('AT')) {
        $allowedAt = @('ATZ','ATI','AT@1','ATRV','ATE0','ATL0','ATS1','ATH1','ATSP0','ATSP6','ATST32','ATDP','ATDPN','ATSH','ATCRA','ATFCSH','ATFCSD','ATFCSM','ATCM','ATCF','ATMA','ATD')
        foreach ($a in $allowedAt) {
            if ($c.StartsWith($a)) { return $true }
        }
        return $false
    }
    $mode = if ($c.Length -ge 2) { $c.Substring(0, 2) } else { '' }
    if ($mode -in @('04','08','10','11','14','27','28','2E','31','34','36','37')) {
        return $false
    }
    return ($mode -in @('01','02','03','05','06','07','09','0A','22'))
}

function Send-ElmReadOnly {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [string]$Cmd,
        [int]$TimeoutMs = 2000
    )
    if (-not (Test-ReadOnlyCommand -Cmd $Cmd)) {
        throw "STRICTLY READ-ONLY FIREWALL BLOCKED COMMAND: $Cmd"
    }
    $null = $Port.ReadExisting()
    $Port.Write("$Cmd`r")
    $sb = New-Object System.Text.StringBuilder
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($Port.BytesToRead -gt 0) {
            $null = $sb.Append($Port.ReadExisting())
            if ($sb.ToString().Contains('>')) { break }
        } else {
            Start-Sleep -Milliseconds 18
        }
    }
    return ($sb.ToString() -replace '\r', "`n" -replace '>', '').Trim()
}

function Parse-CanDataBytes {
    param([string]$RawResp)
    $lines = @($RawResp -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^7E[8-F]' })
    if ($lines.Count -eq 0) { return @() }
    $tokens = @($lines[0] -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -lt 5) { return @() }
    $len = [Convert]::ToInt32($tokens[1], 16)
    $dataCount = $len - 2
    $bytes = @()
    for ($i = 0; $i -lt $dataCount -and (4 + $i) -lt $tokens.Count; $i++) {
        $bytes += [Convert]::ToInt32($tokens[4 + $i], 16)
    }
    return ,$bytes
}

function Read-AllLiveTelemetry {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [string[]]$PidList,
        [hashtable]$StaticSession,
        [int]$GapMs = 15
    )
    $rawMap = [ordered]@{}
    $bytesMap = @{}
    foreach ($p in $PidList) {
        $r = Send-ElmReadOnly $Port $p 1500
        $rawMap[$p] = $r
        $bytesMap[$p] = Parse-CanDataBytes $r
        if ($GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
    }
    $atrv = Send-ElmReadOnly $Port 'ATRV' 1500
    $m03  = Send-ElmReadOnly $Port '03' 1500
    $m07  = Send-ElmReadOnly $Port '07' 1500

    $b01 = $bytesMap['0101']; $b04 = $bytesMap['0104']
    $b05 = $bytesMap['0105']; $b06 = $bytesMap['0106']; $b07 = $bytesMap['0107']
    $b0B = $bytesMap['010B']; $b0C = $bytesMap['010C']; $b0D = $bytesMap['010D']
    $b0E = $bytesMap['010E']; $b0F = $bytesMap['010F']; $b11 = $bytesMap['0111']
    $b14 = $bytesMap['0114']; $b15 = $bytesMap['0115']; $b1F = $bytesMap['011F']
    $b21 = $bytesMap['0121']; $b23 = $bytesMap['0123']; $b2E = $bytesMap['012E']
    $b2F = $bytesMap['012F']; $b30 = $bytesMap['0130']; $b31 = $bytesMap['0131']
    $b33 = $bytesMap['0133']; $b3C = $bytesMap['013C']; $b42 = $bytesMap['0142']
    $b43 = $bytesMap['0143']; $b44 = $bytesMap['0144']; $b45 = $bytesMap['0145']
    $b46 = $bytesMap['0146']; $b47 = $bytesMap['0147']; $b49 = $bytesMap['0149']
    $b4A = $bytesMap['014A']; $b4C = $bytesMap['014C']; $b56 = $bytesMap['0156']

    $rpmVal = if ($b0C.Count -ge 2) { [Math]::Round((256 * $b0C[0] + $b0C[1]) / 4.0, 1) } else { 0 }
    $ecuAwake = ($b0C.Count -ge 2 -or $b42.Count -ge 2 -or $b05.Count -ge 1)
    $engineRunning = ($rpmVal -ge 50)
    $atrvVolt = 0.0
    if ($atrv -match '(\d+(?:\.\d+)?)\s*V') {
        try { $atrvVolt = [double]$Matches[1] } catch { $atrvVolt = 0.0 }
    }
    $voltVal = if ($b42.Count -ge 2) { [Math]::Round((256 * $b42[0] + $b42[1]) / 1000.0, 3) } else { [Math]::Round($atrvVolt, 3) }
    $fuelSysLabel = if ($engineRunning) { 'Closed loop (using O2 sensor)' } elseif ($ecuAwake) { 'Open loop — Engine Off' } else { 'Open loop — Engine/ECU Off' }

    $payload = [ordered]@{
        timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        readOnly      = $true
        ecuAwake      = $ecuAwake
        engineRunning = $engineRunning
        fuelSys1      = $fuelSysLabel
        atrv          = $atrv
        milOn      = if ($b01.Count -ge 1) { ($b01[0] -band 0x80) -ne 0 } else { $false }
        dtcCount   = if ($b01.Count -ge 1) { ($b01[0] -band 0x7F) } else { 0 }
        load       = if ($b04.Count -ge 1) { [Math]::Round($b04[0] * 100.0 / 255.0, 1) } else { 0 }
        coolant    = if ($b05.Count -ge 1) { $b05[0] - 40 } else { 0 }
        stft       = if ($b06.Count -ge 1) { [Math]::Round(($b06[0] - 128) * 100.0 / 128.0, 2) } else { 0 }
        ltft       = if ($b07.Count -ge 1) { [Math]::Round(($b07[0] - 128) * 100.0 / 128.0, 2) } else { 0 }
        map        = if ($b0B.Count -ge 1) { $b0B[0] } else { 0 }
        rpm        = $rpmVal
        spd        = if ($b0D.Count -ge 1) { $b0D[0] } else { 0 }
        timing     = if ($b0E.Count -ge 1) { [Math]::Round($b0E[0] / 2.0 - 64.0, 1) } else { 0 }
        iat        = if ($b0F.Count -ge 1) { $b0F[0] - 40 } else { 0 }
        thr        = if ($b11.Count -ge 1) { [Math]::Round($b11[0] * 100.0 / 255.0, 1) } else { 0 }
        o2s1       = if ($b14.Count -ge 1) { [Math]::Round($b14[0] / 200.0, 3) } else { 0 }
        o2s1Trim   = if ($b14.Count -ge 2 -and $b14[1] -ne 255) { [Math]::Round(($b14[1] - 128) * 100.0 / 128.0, 2) } else { 0 }
        o2s2       = if ($b15.Count -ge 1) { [Math]::Round($b15[0] / 200.0, 3) } else { 0 }
        runtime    = if ($b1F.Count -ge 2) { 256 * $b1F[0] + $b1F[1] } else { 0 }
        distMilOn  = if ($b21.Count -ge 2) { 256 * $b21[0] + $b21[1] } else { 0 }
        rail       = if ($b23.Count -ge 2) { [Math]::Round((10.0 * (256 * $b23[0] + $b23[1])) / 1000.0, 2) } else { 0 }
        evap       = if ($b2E.Count -ge 1) { [Math]::Round($b2E[0] * 100.0 / 255.0, 1) } else { 0 }
        fuel       = if ($b2F.Count -ge 1) { [Math]::Round($b2F[0] * 100.0 / 255.0, 1) } else { 0 }
        warmups    = if ($b30.Count -ge 1) { $b30[0] } else { 0 }
        distClear  = if ($b31.Count -ge 2) { 256 * $b31[0] + $b31[1] } else { 0 }
        baro       = if ($b33.Count -ge 1) { $b33[0] } else { 83 }
        cat        = if ($b3C.Count -ge 2) { [Math]::Round((256 * $b3C[0] + $b3C[1]) / 10.0 - 40.0, 1) } else { 0 }
        volt       = $voltVal
        absLoad    = if ($b43.Count -ge 2) { [Math]::Round((256 * $b43[0] + $b43[1]) * 100.0 / 255.0, 1) } else { 0 }
        lambda     = if ($b44.Count -ge 2) { [Math]::Round(2.0 / 65536.0 * (256 * $b44[0] + $b44[1]), 4) } else { 1.0 }
        relThr     = if ($b45.Count -ge 1) { [Math]::Round($b45[0] * 100.0 / 255.0, 1) } else { 0 }
        amb        = if ($b46.Count -ge 1) { $b46[0] - 40 } else { 0 }
        thrB       = if ($b47.Count -ge 1) { [Math]::Round($b47[0] * 100.0 / 255.0, 1) } else { 0 }
        pedalD     = if ($b49.Count -ge 1) { [Math]::Round($b49[0] * 100.0 / 255.0, 1) } else { 0 }
        pedalE     = if ($b4A.Count -ge 1) { [Math]::Round($b4A[0] * 100.0 / 255.0, 1) } else { 0 }
        actThr     = if ($b4C.Count -ge 1) { [Math]::Round($b4C[0] * 100.0 / 255.0, 1) } else { 0 }
        secO2Trim  = if ($b56.Count -ge 1) { [Math]::Round(($b56[0] - 128) * 100.0 / 128.0, 2) } else { 0 }
        mode03Raw  = $m03
        mode07Raw  = $m07
        mode01Raw  = $rawMap
        staticDump = $StaticSession
    }
    return $payload
}

function Invoke-CloudRequest {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Method,
        [string]$Url,
        [string]$JsonBody,
        [string]$Provider,
        [string]$ApiKey
    )
    if ($null -eq $Client -or -not $Url) { return $false }
    $httpMethod = switch ($Method.ToUpperInvariant()) {
        'PUT'   { [System.Net.Http.HttpMethod]::Put }
        'PATCH' { New-Object System.Net.Http.HttpMethod('PATCH') }
        default { [System.Net.Http.HttpMethod]::Post }
    }
    $reqMsg = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $Url)
    $reqMsg.Content = New-Object System.Net.Http.StringContent($JsonBody, [System.Text.Encoding]::UTF8, 'application/json')
    if ($Provider -eq 'supabase') {
        $reqMsg.Headers.Add('Prefer', 'return=minimal')
        if ($ApiKey) {
            $reqMsg.Headers.Add('apikey', $ApiKey)
            $reqMsg.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $ApiKey)
        }
    } elseif ($Provider -eq 'webhook' -and $ApiKey) {
        $reqMsg.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $ApiKey)
    }
    $resp = $Client.SendAsync($reqMsg).GetAwaiter().GetResult()
    return $resp.IsSuccessStatusCode
}

$allMode01Pids = @(
    '0101','0103','0104','0105','0106','0107','010B','010C','010D','010E',
    '010F','0111','0113','0114','0115','011C','011F','0121','0123','012E',
    '012F','0130','0131','0133','013C','0141','0142','0143','0144','0145',
    '0146','0147','0149','014A','014C','0151','0156'
)

$port = New-Object System.IO.Ports.SerialPort $ComPort, $BaudRate, 'None', 8, 'One'
$port.ReadTimeout = 2000
$port.WriteTimeout = 2000
$port.DtrEnable = $true
$port.RtsEnable = $true

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$HttpPort/")

$httpClient = $null
try {
    $httpClient = New-Object System.Net.Http.HttpClient
    $httpClient.Timeout = [TimeSpan]::FromSeconds(4)
} catch {}
$cloudOfflineQueue = New-Object System.Collections.Generic.Queue[hashtable]
$lastPollSw = [System.Diagnostics.Stopwatch]::StartNew()
$lastCloudSw = [System.Diagnostics.Stopwatch]::StartNew()
$lastMetaSw = [System.Diagnostics.Stopwatch]::StartNew()
$latestPayload = $null
$cloudTxCount = 0
$sessionStartedAt = (Get-Date).ToUniversalTime().ToString('o')
$sessionFrameCount = 0

try {
    Write-Host "Opening $ComPort @ $BaudRate baud (Strictly Read-Only + BT Coexistence Gap ${CoexistGapMs}ms)..." -ForegroundColor Cyan
    $opened = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if ($attempt -gt 1) { Refresh-ObdRfcomm; Start-Sleep -Milliseconds 800 }
            $port.Open()
            $opened = $true
            break
        } catch {
            Write-Warning "Attempt $attempt to open $ComPort failed: $($_.Exception.Message)"
        }
    }
    if (-not $opened) { throw "Could not open $ComPort after 3 attempts." }

    $null  = Send-ElmReadOnly $port 'ATZ' 4000
    $null  = Send-ElmReadOnly $port 'ATE0'
    $null  = Send-ElmReadOnly $port 'ATL0'
    $null  = Send-ElmReadOnly $port 'ATS1'
    $null  = Send-ElmReadOnly $port 'ATH1'
    $null  = Send-ElmReadOnly $port 'ATSP6'
    $null  = Send-ElmReadOnly $port 'ATST32'
    $ati   = Send-ElmReadOnly $port 'ATI'
    $at1   = Send-ElmReadOnly $port 'AT@1'
    $atdp  = Send-ElmReadOnly $port 'ATDP'
    $atdpn = Send-ElmReadOnly $port 'ATDPN'

    Write-Host "Performing initial read-only sweep of Mode 01/02/03/06/07/09/0A and UDS 0x22..." -ForegroundColor Cyan
    $staticSession = [ordered]@{
        ATI     = $ati
        AT1     = $at1
        ATDP    = $atdp
        ATDPN   = $atdpn
        Mode01_0100 = Send-ElmReadOnly $port '0100' 3000
        Mode01_0120 = Send-ElmReadOnly $port '0120' 2500
        Mode01_0140 = Send-ElmReadOnly $port '0140' 2500
        Mode02_0000 = Send-ElmReadOnly $port '020000' 2000
        Mode03      = Send-ElmReadOnly $port '03' 2500
        Mode07      = Send-ElmReadOnly $port '07' 2500
        Mode0A      = Send-ElmReadOnly $port '0A' 2500
        Mode06      = [ordered]@{}
        Mode09      = [ordered]@{}
        Uds7E0      = [ordered]@{}
    }
    foreach ($m6 in @('0600','0620','0640','0660','0680','06A0','0601','0602','0621','0635','063D','0641','0642','06A2','06A3','06A4','06A5')) {
        $staticSession.Mode06[$m6] = Send-ElmReadOnly $port $m6 2500
    }
    foreach ($m9 in @('0900','0902','0904','0906','0908','090A')) {
        $staticSession.Mode09[$m9] = Send-ElmReadOnly $port $m9 3000
    }
    $null = Send-ElmReadOnly $port 'ATSH 7E0'
    $null = Send-ElmReadOnly $port 'ATCRA 7E8'
    $null = Send-ElmReadOnly $port 'ATFCSH 7E0'
    $null = Send-ElmReadOnly $port 'ATFCSD 30 00 00'
    $null = Send-ElmReadOnly $port 'ATFCSM 1'
    foreach ($did in @('F187','F189','F190','F191','F197','F19E','F1A2','F1A3','F400','1002','2001')) {
        $staticSession.Uds7E0[$did] = Send-ElmReadOnly $port ("22" + $did) 2000
    }
    $null = Send-ElmReadOnly $port 'ATFCSM 0'
    $null = Send-ElmReadOnly $port 'ATD'
    $null = Send-ElmReadOnly $port 'ATE0'
    $null = Send-ElmReadOnly $port 'ATL0'
    $null = Send-ElmReadOnly $port 'ATS1'
    $null = Send-ElmReadOnly $port 'ATH1'
    $null = Send-ElmReadOnly $port 'ATSP6'
    $null = Send-ElmReadOnly $port 'ATST32'

    # Initial live sample
    $latestPayload = Read-AllLiveTelemetry -Port $port -PidList $allMode01Pids -StaticSession $staticSession -GapMs $CoexistGapMs

    $listener.Start()
    Write-Host "PulseOBD Bridge listening on http://localhost:$HttpPort/api/live" -ForegroundColor Green
    if ($EnableCloudStream -and $ResolvedCloudUrl) {
        Write-Host "Auto Cloud Relay ACTIVE [$CloudProvider] -> $ResolvedCloudUrl" -ForegroundColor Cyan
        if ($CloudProvider -eq 'firebase' -and $SaveCloudHistory) {
            Write-Host "Firebase Trip History Archive -> $FirebaseHistoryFramesUrl" -ForegroundColor Cyan
        }
        Write-Host "Remote Watch URL -> PulseOBD_Studio.html?cloud=watch&provider=$CloudProvider&channel=$CloudChannel" -ForegroundColor Cyan
    }
    Write-Host "Press Ctrl+C to stop and cleanly unlock $ComPort." -ForegroundColor Yellow

    $ctxTask = $listener.GetContextAsync()

    while ($listener.IsListening) {
        # 1. Serve incoming local / Wi-Fi HTTP requests without blocking COM3/Cloud telemetry
        if ($ctxTask.IsCompleted) {
            $ctx = $ctxTask.Result
            $ctxTask = $listener.GetContextAsync()
            $req = $ctx.Request
            $res = $ctx.Response
            $res.Headers.Add('Access-Control-Allow-Origin', '*')

            if ($req.Url.AbsolutePath -eq '/api/live' -or $req.Url.AbsolutePath -eq '/api/snapshot') {
                if (-not $latestPayload) {
                    $latestPayload = Read-AllLiveTelemetry -Port $port -PidList $allMode01Pids -StaticSession $staticSession -GapMs $CoexistGapMs
                }
                $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes(($latestPayload | ConvertTo-Json -Depth 6))
                $res.ContentType = 'application/json'
                $res.OutputStream.Write($jsonBytes, 0, $jsonBytes.Length)
            } elseif ($req.Url.AbsolutePath -eq '/api/cloud-status') {
                $statusJson = [ordered]@{
                    provider     = $CloudProvider
                    channel      = $CloudChannel
                    sessionId    = $TripSessionId
                    txCount      = $cloudTxCount
                    queuedCount  = $cloudOfflineQueue.Count
                    saveHistory  = $SaveCloudHistory
                    configured   = [bool]$ResolvedCloudUrl
                } | ConvertTo-Json
                $sBytes = [System.Text.Encoding]::UTF8.GetBytes($statusJson)
                $res.ContentType = 'application/json'
                $res.OutputStream.Write($sBytes, 0, $sBytes.Length)
            } else {
                $candidates = @(
                    (Join-Path $PSScriptRoot 'PulseOBD_Studio.html'),
                    (Join-Path $PSScriptRoot 'index.html'),
                    (Join-Path $PSScriptRoot '..\PulseOBD_Studio.html'),
                    (Join-Path $PSScriptRoot '..\index.html')
                )
                $htmlPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($htmlPath) {
                    $bytes = [System.IO.File]::ReadAllBytes($htmlPath)
                    $res.ContentType = 'text/html; charset=utf-8'
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $msg = [System.Text.Encoding]::UTF8.GetBytes('PulseOBD Read-Only All-Variable COM3 + Firebase Auto-Sync Bridge Running.')
                    $res.OutputStream.Write($msg, 0, $msg.Length)
                }
            }
            $res.Close()
        }

        # 2. Periodic autonomous COM3 poll + local JSON snapshot + Auto Cloud TX (Live + History)
        if ($lastPollSw.ElapsedMilliseconds -ge $PollIntervalMs) {
            $lastPollSw.Restart()
            $latestPayload = Read-AllLiveTelemetry -Port $port -PidList $allMode01Pids -StaticSession $staticSession -GapMs $CoexistGapMs

            if ($SaveLocalJson) {
                try {
                    $diagDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'diagnostics'
                    if (-not (Test-Path $diagDir)) { $diagDir = $PSScriptRoot }
                    $outJsonPath = Join-Path $diagDir 'live_telemetry_latest.json'
                    [System.IO.File]::WriteAllText($outJsonPath, ($latestPayload | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
                } catch {}
            }

            if ($EnableCloudStream -and $ResolvedCloudUrl -and $lastCloudSw.ElapsedMilliseconds -ge $CloudIntervalMs) {
                $lastCloudSw.Restart()
                $sessionFrameCount++
                $metricsObj = [ordered]@{
                    rpm        = $latestPayload.rpm
                    spd        = $latestPayload.spd
                    load       = $latestPayload.load
                    absLoad    = $latestPayload.absLoad
                    coolant    = $latestPayload.coolant
                    iat        = $latestPayload.iat
                    amb        = $latestPayload.amb
                    cat        = $latestPayload.cat
                    stft       = $latestPayload.stft
                    ltft       = $latestPayload.ltft
                    secO2Trim  = $latestPayload.secO2Trim
                    map        = $latestPayload.map
                    baro       = $latestPayload.baro
                    rail       = $latestPayload.rail
                    timing     = $latestPayload.timing
                    thr        = $latestPayload.thr
                    thrB       = $latestPayload.thrB
                    relThr     = $latestPayload.relThr
                    actThr     = $latestPayload.actThr
                    pedalD     = $latestPayload.pedalD
                    pedalE     = $latestPayload.pedalE
                    o2s1       = $latestPayload.o2s1
                    o2s1Trim   = $latestPayload.o2s1Trim
                    o2s2       = $latestPayload.o2s2
                    lambda     = $latestPayload.lambda
                    fuel       = $latestPayload.fuel
                    evap       = $latestPayload.evap
                    volt       = $latestPayload.volt
                    runtime    = $latestPayload.runtime
                    distMilOn  = $latestPayload.distMilOn
                    warmups    = $latestPayload.warmups
                    distClear  = $latestPayload.distClear
                    milOn         = $latestPayload.milOn
                    dtcCount      = $latestPayload.dtcCount
                    engineRunning = $latestPayload.engineRunning
                    ecuAwake      = $latestPayload.ecuAwake
                    fuelSys1      = $latestPayload.fuelSys1
                    atrv          = $latestPayload.atrv
                }

                $packetObj = [ordered]@{
                    v             = 3
                    ts            = $latestPayload.timestamp
                    sessionId     = $TripSessionId
                    vin           = 'AAVZZZ6RZHU112564'
                    src           = 'com3_bridge'
                    variableCount = 124
                    metrics       = $metricsObj
                }
                if ($CloudProvider -ne 'ntfy') {
                    $packetObj['mode01Raw'] = $latestPayload.mode01Raw
                    $packetObj['staticDump'] = $latestPayload.staticDump
                }

                $wireObj = if ($CloudProvider -eq 'supabase') {
                    [ordered]@{
                        channel_id = $CloudChannel
                        vin        = 'AAVZZZ6RZHU112564'
                        payload    = $packetObj
                    }
                } else {
                    $packetObj
                }

                $cloudPacket = ($wireObj | ConvertTo-Json -Depth 7 -Compress)
                $historyJson = ''
                if ($CloudProvider -eq 'firebase' -and $SaveCloudHistory) {
                    $historyJson = ([ordered]@{
                        ts        = $latestPayload.timestamp
                        src       = 'com3_bridge'
                        rpm       = $latestPayload.rpm
                        spd       = $latestPayload.spd
                        load      = $latestPayload.load
                        coolant   = $latestPayload.coolant
                        iat       = $latestPayload.iat
                        cat       = $latestPayload.cat
                        map       = $latestPayload.map
                        rail      = $latestPayload.rail
                        stft      = $latestPayload.stft
                        ltft      = $latestPayload.ltft
                        lambda    = $latestPayload.lambda
                        thr       = $latestPayload.thr
                        pedalD    = $latestPayload.pedalD
                        fuel      = $latestPayload.fuel
                        volt      = $latestPayload.volt
                    } | ConvertTo-Json -Compress)
                }

                try {
                    while ($cloudOfflineQueue.Count -gt 0) {
                        $qItem = $cloudOfflineQueue.Peek()
                        if (Invoke-CloudRequest -Client $httpClient -Method $qItem.Method -Url $qItem.Url -JsonBody $qItem.Body -Provider $CloudProvider -ApiKey $CloudApiKey) {
                            $null = $cloudOfflineQueue.Dequeue()
                        } else {
                            break
                        }
                    }

                    $okLive = Invoke-CloudRequest -Client $httpClient -Method $ResolvedCloudMethod -Url $ResolvedCloudUrl -JsonBody $cloudPacket -Provider $CloudProvider -ApiKey $CloudApiKey
                    if ($okLive) {
                        if ($CloudProvider -eq 'firebase' -and $SaveCloudHistory -and $FirebaseHistoryFramesUrl) {
                            $okHist = Invoke-CloudRequest -Client $httpClient -Method 'POST' -Url $FirebaseHistoryFramesUrl -JsonBody $historyJson -Provider $CloudProvider -ApiKey $CloudApiKey
                            if (-not $okHist -and $cloudOfflineQueue.Count -lt 250) {
                                $cloudOfflineQueue.Enqueue(@{ Method = 'POST'; Url = $FirebaseHistoryFramesUrl; Body = $historyJson })
                            }
                            if ($lastMetaSw.ElapsedMilliseconds -ge 12000 -and $FirebaseHistoryMetaUrl) {
                                $lastMetaSw.Restart()
                                $metaBody = ([ordered]@{
                                    id          = $TripSessionId
                                    vin         = 'AAVZZZ6RZHU112564'
                                    transport   = 'com3_bridge'
                                    startedAt   = $sessionStartedAt
                                    updatedAt   = $latestPayload.timestamp
                                    sampleCount = $sessionFrameCount
                                    lastRpm     = $latestPayload.rpm
                                    lastSpd     = $latestPayload.spd
                                    lastCoolant = $latestPayload.coolant
                                } | ConvertTo-Json -Compress)
                                $null = Invoke-CloudRequest -Client $httpClient -Method 'PATCH' -Url $FirebaseHistoryMetaUrl -JsonBody $metaBody -Provider $CloudProvider -ApiKey $CloudApiKey
                            }
                        }
                        $cloudTxCount++
                        Write-Host "[CLOUD TX #$cloudTxCount -> $CloudProvider] RPM=$($latestPayload.rpm) SPD=$($latestPayload.spd) km/h COOL=$($latestPayload.coolant)C RAIL=$($latestPayload.rail) MPa" -ForegroundColor DarkCyan
                    } else {
                        if ($cloudOfflineQueue.Count -lt 250) {
                            $cloudOfflineQueue.Enqueue(@{ Method = $ResolvedCloudMethod; Url = $ResolvedCloudUrl; Body = $cloudPacket })
                            if ($CloudProvider -eq 'firebase' -and $SaveCloudHistory -and $FirebaseHistoryFramesUrl) {
                                $cloudOfflineQueue.Enqueue(@{ Method = 'POST'; Url = $FirebaseHistoryFramesUrl; Body = $historyJson })
                            }
                        }
                        Write-Warning "Cloud TX queued offline ($($cloudOfflineQueue.Count) buffered)"
                    }
                } catch {
                    if ($cloudOfflineQueue.Count -lt 250) {
                        $cloudOfflineQueue.Enqueue(@{ Method = $ResolvedCloudMethod; Url = $ResolvedCloudUrl; Body = $cloudPacket })
                        if ($CloudProvider -eq 'firebase' -and $SaveCloudHistory -and $FirebaseHistoryFramesUrl) {
                            $cloudOfflineQueue.Enqueue(@{ Method = 'POST'; Url = $FirebaseHistoryFramesUrl; Body = $historyJson })
                        }
                    }
                    Write-Host "[CLOUD QUEUE] Offline dead-zone ($($cloudOfflineQueue.Count) buffered)" -ForegroundColor DarkYellow
                }
            }
        }

        Start-Sleep -Milliseconds 35
    }
} finally {
    if ($null -ne $httpClient) { $httpClient.Dispose() }
    if ($listener.IsListening) { $listener.Stop() }
    if ($port.IsOpen) {
        try { $null = Send-ElmReadOnly $port 'ATD' 1000 } catch {}
        $port.Close()
        Write-Host "Closed $ComPort cleanly." -ForegroundColor Green
    }
    $port.Dispose()
}
