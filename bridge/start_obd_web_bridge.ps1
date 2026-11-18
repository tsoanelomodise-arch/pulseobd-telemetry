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
    [string]$CloudChannel = 'auto',
    [string]$CloudUrl = '',
    [string]$SupabaseTable = 'pulseobd_telemetry',
    [string]$CloudApiKey = '',
    [int]$PollIntervalMs = 750,
    [int]$CloudIntervalMs = 3000,
    [int]$CoexistGapMs = 28,
    [ValidateSet('coexist','audio_priority','shared_release','performance')]
    [string]$BtCoexistMode = 'coexist',
    [bool]$ReleaseBetweenPolls = $false,
    [int]$ReleaseRestMs = 2200,
    [bool]$SaveLocalJson = $true,
    [bool]$SaveCloudHistory = $true
)

if ($BtCoexistMode -eq 'shared_release') {
    $ReleaseBetweenPolls = $true
} elseif ($BtCoexistMode -eq 'audio_priority') {
    if ($PollIntervalMs -lt 1100) { $PollIntervalMs = 1100 }
    if ($CoexistGapMs -lt 45) { $CoexistGapMs = 45 }
} elseif ($BtCoexistMode -eq 'performance') {
    $ReleaseBetweenPolls = $false
    $PollIntervalMs = [Math]::Min($PollIntervalMs, 200)
    $CoexistGapMs = [Math]::Min($CoexistGapMs, 8)
}

$ErrorActionPreference = 'Stop'
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http
} catch {}

$ScriptFolderLeaf = Split-Path $PSScriptRoot -Leaf
$ProjectRoot = if ($ScriptFolderLeaf -ieq 'bridge') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }
$VehicleHistoryRoot = Join-Path $ProjectRoot 'vehicle_history'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Auto-load private local Firebase configuration (gitignored firebase.local.json or env vars)
$LocalConfigCandidates = @(
    (Join-Path $PSScriptRoot 'firebase.local.json'),
    (Join-Path $ProjectRoot 'firebase.local.json')
)
$ExplicitCloudChannel = ($CloudChannel -and $CloudChannel -ne 'auto')
foreach ($cfgFile in $LocalConfigCandidates) {
    if (Test-Path $cfgFile) {
        try {
            $localCfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
            if (-not $CloudUrl -and $localCfg.url) { $CloudUrl = [string]$localCfg.url }
            if (-not $ExplicitCloudChannel -and $localCfg.channel -and $localCfg.channel -ne 'auto') { $CloudChannel = [string]$localCfg.channel }
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

function Initialize-CloudEndpointUrls {
    param([string]$ActiveVin)
    if (-not $script:CloudChannel -or $script:CloudChannel -eq 'auto' -or $script:ExplicitCloudChannel -eq $false) {
        if ($ActiveVin) { $script:CloudChannel = $ActiveVin }
    }
    if (-not $script:CloudChannel -or $script:CloudChannel -eq 'auto') {
        $script:CloudChannel = 'AAVZZZ6RZHU112564'
    }

    if ($script:CloudProvider -eq 'ntfy') {
        $ntfyTopic = if ($script:CloudChannel -match '^(?i)pulseobd-') { $script:CloudChannel } else { "pulseobd-$($script:CloudChannel)" }
        $script:ResolvedCloudUrl = "https://ntfy.sh/$([Uri]::EscapeDataString($ntfyTopic))"
        $script:ResolvedCloudMethod = 'POST'
    } elseif ($script:CloudProvider -eq 'firebase') {
        $fbBase = $script:CloudUrl.TrimEnd('/')
        if ($fbBase) {
            $safeCh = [Uri]::EscapeDataString($script:CloudChannel)
            if ($fbBase.EndsWith('/latest.json')) {
                $prefix = $fbBase.Substring(0, $fbBase.Length - 12)
            } elseif ($fbBase.EndsWith('.json')) {
                $prefix = $fbBase.Substring(0, $fbBase.Length - 5)
            } elseif ($fbBase -match '/vehicles/[^/]+$' -or $fbBase -match '/pulseobd/[^/]+$') {
                $prefix = Split-Path $fbBase -Parent
                $prefix = ($prefix -replace '\\','/') + "/$safeCh"
                if ($fbBase -match '/vehicles/[^/]+$' -and (-not $ActiveVin -or $fbBase.EndsWith("/$ActiveVin"))) {
                    $prefix = $fbBase
                }
            } elseif ($fbBase -match '/vehicles$') {
                $prefix = "$fbBase/$safeCh"
            } else {
                $prefix = "$fbBase/vehicles/$safeCh"
            }
            $script:FirebaseLatestUrl = Add-FirebaseAuthQuery -Url "$prefix/latest.json" -Auth $script:CloudApiKey
            $script:FirebaseHistoryFramesUrl = Add-FirebaseAuthQuery -Url "$prefix/history/$($script:TripSessionId)/frames.json" -Auth $script:CloudApiKey
            $script:FirebaseHistoryMetaUrl = Add-FirebaseAuthQuery -Url "$prefix/history/$($script:TripSessionId)/meta.json" -Auth $script:CloudApiKey
            $script:ResolvedCloudUrl = $script:FirebaseLatestUrl
            $script:ResolvedCloudMethod = 'PUT'
        }
    } elseif ($script:CloudProvider -eq 'supabase') {
        $sbBase = $script:CloudUrl.TrimEnd('/')
        if ($sbBase) {
            $script:ResolvedCloudUrl = "$sbBase/rest/v1/$([Uri]::EscapeDataString($script:SupabaseTable))"
        }
        $script:ResolvedCloudMethod = 'POST'
    } else {
        $script:ResolvedCloudUrl = $script:CloudUrl.Trim()
        $script:ResolvedCloudMethod = 'POST'
    }
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

function Open-ObdComPort {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [switch]$FastReopen
    )
    if ($Port.IsOpen) { return $true }
    $maxTries = if ($FastReopen) { 2 } else { 3 }
    for ($attempt = 1; $attempt -le $maxTries; $attempt++) {
        try {
            if (-not $FastReopen -and $attempt -gt 1) {
                Refresh-ObdRfcomm
                Start-Sleep -Milliseconds 700
            } elseif ($FastReopen -and $attempt -gt 1) {
                Start-Sleep -Milliseconds 350
            }
            $Port.Open()
            Start-Sleep -Milliseconds 120
            return $true
        } catch {
            if ($attempt -eq $maxTries) {
                throw "Could not open $($Port.PortName) after $maxTries attempts: $($_.Exception.Message)"
            }
        }
    }
    return $false
}

function Close-ObdComPort {
    param(
        [System.IO.Ports.SerialPort]$Port
    )
    if ($null -eq $Port -or -not $Port.IsOpen) { return }
    try { $Port.DiscardInBuffer() } catch {}
    try { $Port.DiscardOutBuffer() } catch {}
    try { $Port.Close() } catch {}
}

function Invoke-FastElmInit {
    param([System.IO.Ports.SerialPort]$Port)
    $gap = [Math]::Min(20, [Math]::Max(8, $script:CoexistGapMs))
    foreach ($cmd in @('ATE0','ATL0','ATS1','ATH1','ATSP6','ATST32')) {
        if ($script:BtManualUnlocked -or ([DateTime]::UtcNow -lt $script:BtYieldUntilUtc) -or -not $Port.IsOpen) { return }
        $null = Send-ElmReadOnly $Port $cmd 1500
        if ($gap -gt 0) { Start-Sleep -Milliseconds $gap }
    }
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
    if ($null -eq $Port -or -not $Port.IsOpen) {
        throw "COM port is temporarily yielded/released for Bluetooth coexistence."
    }
    $null = $Port.ReadExisting()
    $Port.Write("$Cmd`r")
    $sb = New-Object System.Text.StringBuilder
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not $Port.IsOpen) { break }
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

function Parse-IsoTpAllBytes {
    param([string]$RawResp)
    if (-not $RawResp) { return @() }
    $lines = @($RawResp -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $frameLines = @($lines | Where-Object { $_ -match '^7E[8-F]\s' })
    if ($frameLines.Count -eq 0) {
        return (Parse-CanDataBytes -RawResp $RawResp)
    }
    $firstTokens = @($frameLines[0] -split '\s+' | Where-Object { $_ -ne '' })
    if ($firstTokens.Count -lt 3) { return @() }
    $pci0 = 0
    try { $pci0 = [Convert]::ToInt32($firstTokens[1], 16) } catch { return @() }
    $out = New-Object System.Collections.ArrayList
    if (($pci0 -band 0xF0) -eq 0x10 -and $firstTokens.Count -ge 4) {
        $lenHi = ($pci0 -band 0x0F) * 256
        $lenLo = [Convert]::ToInt32($firstTokens[2], 16)
        $totalLen = $lenHi + $lenLo
        for ($i = 3; $i -lt $firstTokens.Count; $i++) {
            try { $null = $out.Add([Convert]::ToInt32($firstTokens[$i], 16)) } catch {}
        }
        for ($l = 1; $l -lt $frameLines.Count; $l++) {
            $toks = @($frameLines[$l] -split '\s+' | Where-Object { $_ -ne '' })
            if ($toks.Count -ge 2 -and $toks[1] -match '^2[0-9A-Fa-f]$') {
                for ($j = 2; $j -lt $toks.Count; $j++) {
                    try { $null = $out.Add([Convert]::ToInt32($toks[$j], 16)) } catch {}
                }
            }
        }
        $limit = [Math]::Min($totalLen, $out.Count)
        $sliced = @()
        for ($k = 0; $k -lt $limit; $k++) { $sliced += [int]$out[$k] }
        return ,$sliced
    } elseif (($pci0 -band 0xF0) -eq 0x00) {
        $sfLen = $pci0 -band 0x0F
        $sliced = @()
        for ($i = 0; $i -lt $sfLen -and (2 + $i) -lt $firstTokens.Count; $i++) {
            try { $sliced += [Convert]::ToInt32($firstTokens[2 + $i], 16) } catch {}
        }
        return ,$sliced
    }
    return @()
}

function Decode-IsoTpAscii {
    param([int[]]$Bytes, [int]$SkipCount = 3)
    if ($null -eq $Bytes -or $Bytes.Count -le $SkipCount) { return '' }
    $sb = New-Object System.Text.StringBuilder
    for ($i = $SkipCount; $i -lt $Bytes.Count; $i++) {
        $b = $Bytes[$i]
        if ($b -ge 0x20 -and $b -le 0x7E) {
            $null = $sb.Append([char]$b)
        }
    }
    return $sb.ToString().Trim()
}

function Decode-IsoTpHex {
    param([int[]]$Bytes, [int]$SkipCount = 3)
    if ($null -eq $Bytes -or $Bytes.Count -le $SkipCount) { return '' }
    $sb = New-Object System.Text.StringBuilder
    for ($i = $SkipCount; $i -lt $Bytes.Count; $i++) {
        $null = $sb.Append($Bytes[$i].ToString('X2'))
    }
    return $sb.ToString()
}

function Get-SafeVinName {
    param([string]$RawVin, [string]$FallbackPart)
    if ($RawVin) {
        $clean = ($RawVin.ToUpperInvariant() -replace '[^A-Z0-9]', '')
        if ($clean.Length -ge 6) { return $clean }
    }
    if ($FallbackPart) {
        $cleanPart = ($FallbackPart.ToUpperInvariant() -replace '[^A-Z0-9_-]', '')
        if ($cleanPart.Length -ge 4) { return "ECU_$cleanPart" }
    }
    return 'UNKNOWN_VEHICLE_' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
}

function Resolve-VehicleIdentity {
    param($StaticSession)
    $rawVin = ''
    if ($StaticSession.Mode09 -and $StaticSession.Mode09['0902']) {
        $rawVin = Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Mode09['0902']) -SkipCount 3
    }
    if ((-not $rawVin -or ($rawVin -replace '[^A-Z0-9]', '').Length -lt 6) -and $StaticSession.Uds7E0 -and $StaticSession.Uds7E0['F190']) {
        $rawVin = Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Uds7E0['F190']) -SkipCount 3
    }

    $partNum = if ($StaticSession.Uds7E0 -and $StaticSession.Uds7E0['F187']) { Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Uds7E0['F187']) -SkipCount 3 } else { '' }
    $swVer   = if ($StaticSession.Uds7E0 -and $StaticSession.Uds7E0['F189']) { Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Uds7E0['F189']) -SkipCount 3 } else { '' }
    $hwPart  = if ($StaticSession.Uds7E0 -and $StaticSession.Uds7E0['F191']) { Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Uds7E0['F191']) -SkipCount 3 } else { '' }
    $engine  = if ($StaticSession.Uds7E0 -and $StaticSession.Uds7E0['F197']) { Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Uds7E0['F197']) -SkipCount 3 } else { '' }
    $asamNm  = if ($StaticSession.Uds7E0 -and $StaticSession.Uds7E0['F19E']) { Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Uds7E0['F19E']) -SkipCount 3 } else { '' }
    $asamVer = if ($StaticSession.Uds7E0 -and $StaticSession.Uds7E0['F1A2']) { Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Uds7E0['F1A2']) -SkipCount 3 } else { '' }
    $hwVer   = if ($StaticSession.Uds7E0 -and $StaticSession.Uds7E0['F1A3']) { Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Uds7E0['F1A3']) -SkipCount 3 } else { '' }
    $calid   = if ($StaticSession.Mode09 -and $StaticSession.Mode09['0904']) { Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Mode09['0904']) -SkipCount 3 } else { '' }
    $cvn     = if ($StaticSession.Mode09 -and $StaticSession.Mode09['0906']) { Decode-IsoTpHex   -Bytes (Parse-IsoTpAllBytes $StaticSession.Mode09['0906']) -SkipCount 3 } else { '' }
    $ecuName = if ($StaticSession.Mode09 -and $StaticSession.Mode09['090A']) { (Decode-IsoTpAscii -Bytes (Parse-IsoTpAllBytes $StaticSession.Mode09['090A']) -SkipCount 3) -replace '\s+', '' } else { '' }

    $vin = Get-SafeVinName -RawVin $rawVin -FallbackPart $partNum
    if (-not $engine -and $ecuName) { $engine = $ecuName }
    $label = if ($vin -eq 'AAVZZZ6RZHU112564') {
        "VW Polo 1.2L TSI ($engine)"
    } elseif ($engine) {
        "$vin ($engine)"
    } else {
        "Vehicle $vin"
    }

    return [ordered]@{
        vin             = $vin
        label           = $label
        engine          = $engine
        ecuName         = $ecuName
        partNumber      = $partNum
        softwareVersion = $swVer
        hardwarePart    = $hwPart
        hardwareVersion = $hwVer
        asamDataset     = $asamNm
        asamVersion     = $asamVer
        calid           = $calid
        cvn             = $cvn
        protocol        = "$($StaticSession.ATDP) ($($StaticSession.ATDPN))"
        adapter         = [ordered]@{
            ATI  = $StaticSession.ATI
            AT1  = $StaticSession.AT1
            ATDP = $StaticSession.ATDP
        }
    }
}

$script:SessionFrames = New-Object System.Collections.ArrayList
$script:SessionCsvWrittenHeader = $false

function ConvertTo-PlainOrdered {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        $ht = [ordered]@{}
        foreach ($k in $Obj.Keys) { $ht[$k] = ConvertTo-PlainOrdered $Obj[$k] }
        return $ht
    }
    if ($Obj -is [PSCustomObject]) {
        $ht = [ordered]@{}
        foreach ($p in $Obj.PSObject.Properties) { $ht[$p.Name] = ConvertTo-PlainOrdered $p.Value }
        return $ht
    }
    if (($Obj -is [System.Collections.IEnumerable]) -and -not ($Obj -is [string])) {
        $arr = New-Object System.Collections.ArrayList
        foreach ($item in $Obj) { $null = $arr.Add((ConvertTo-PlainOrdered $item)) }
        return ,$arr.ToArray()
    }
    return $Obj
}

function Write-JsonFileNoBom {
    param([string]$FilePath, $DataObj, [int]$Depth = 8)
    $parent = Split-Path $FilePath -Parent
    if ($parent -and -not (Test-Path $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $json = ($DataObj | ConvertTo-Json -Depth $Depth) + "`n"
    [System.IO.File]::WriteAllText($FilePath, $json, $script:Utf8NoBom)
}

function Upsert-ProjectVehicleFiles {
    param(
        [string]$HistoryRoot,
        $VehicleInfo,
        [string]$SessionId,
        [string]$SessionStartedAt,
        [string]$TransportLabel,
        $FramesArray,
        $LatestMetrics,
        $StaticDump,
        [string]$SourceTag = 'com3_bridge'
    )
    if (-not $HistoryRoot) { return $null }
    $safeVin = Get-SafeVinName -RawVin ([string]$VehicleInfo.vin) -FallbackPart ([string]$VehicleInfo.partNumber)
    $vinDir = Join-Path $HistoryRoot $safeVin
    $sessDir = Join-Path $vinDir 'sessions'
    if (-not (Test-Path $sessDir)) {
        $null = New-Item -ItemType Directory -Path $sessDir -Force
    }

    $profilePath = Join-Path $vinDir 'vehicle_profile.json'
    $latestPath  = Join-Path $vinDir 'latest.json'
    $indexPath   = Join-Path $HistoryRoot 'vehicles_index.json'

    $existingProfile = $null
    if (Test-Path $profilePath) {
        try { $existingProfile = ConvertTo-PlainOrdered (Get-Content $profilePath -Raw | ConvertFrom-Json) } catch {}
    }

    $framesList = @($FramesArray)
    $maxRpm = 0.0; $maxSpd = 0; $maxCool = 0
    foreach ($fr in $framesList) {
        if ($null -eq $fr) { continue }
        $r = 0.0; $sp = 0; $co = 0
        try { $r = [double]$fr['rpm'] } catch { try { $r = [double]$fr.rpm } catch {} }
        try { $sp = [int]$fr['spd'] } catch { try { $sp = [int]$fr.spd } catch {} }
        try { $co = [int]$fr['coolant'] } catch { try { $co = [int]$fr.coolant } catch {} }
        if ($r -gt $maxRpm) { $maxRpm = $r }
        if ($sp -gt $maxSpd) { $maxSpd = $sp }
        if ($co -gt $maxCool) { $maxCool = $co }
    }
    $nowIso = (Get-Date).ToUniversalTime().ToString('o')
    if ($LatestMetrics -and $LatestMetrics['timestamp']) { $nowIso = [string]$LatestMetrics['timestamp'] }
    elseif ($LatestMetrics -and $LatestMetrics['ts']) { $nowIso = [string]$LatestMetrics['ts'] }

    $sessFileRel = "sessions/$SessionId.json"
    if ($SessionId) {
        $sessionObj = [ordered]@{
            id              = $SessionId
            vin             = $safeVin
            vehicleLabel    = $VehicleInfo.label
            engine          = $VehicleInfo.engine
            partNumber      = $VehicleInfo.partNumber
            transport       = $TransportLabel
            readOnlyEnforced = $true
            startedAt       = $SessionStartedAt
            updatedAt       = $nowIso
            sampleCount     = $framesList.Count
            maxRpm          = $maxRpm
            maxSpd          = $maxSpd
            maxCoolant      = $maxCool
            frames          = $framesList
        }
        if ($StaticDump) { $sessionObj['staticDump'] = $StaticDump }
        Write-JsonFileNoBom -FilePath (Join-Path $sessDir "$SessionId.json") -DataObj $sessionObj -Depth 8
    }

    $mergedSessions = New-Object System.Collections.ArrayList
    if ($existingProfile -and $existingProfile['sessions']) {
        foreach ($es in @($existingProfile['sessions'])) {
            $esId = if ($es -is [System.Collections.IDictionary]) { $es['id'] } else { $es.id }
            if ($esId -and $esId -ne $SessionId) {
                $null = $mergedSessions.Add($es)
            }
        }
    }
    if ($SessionId) {
        $sessMetaEntry = [ordered]@{
            id          = $SessionId
            startedAt   = $SessionStartedAt
            updatedAt   = $nowIso
            transport   = $TransportLabel
            sampleCount = $framesList.Count
            maxRpm      = $maxRpm
            maxSpd      = $maxSpd
            maxCoolant  = $maxCool
            file        = $sessFileRel
        }
        $null = $mergedSessions.Add($sessMetaEntry)
    }

    $firstSeen = if ($existingProfile -and $existingProfile['firstSeenAt']) { $existingProfile['firstSeenAt'] } elseif ($SessionStartedAt) { $SessionStartedAt } else { $nowIso }
    $profileObj = [ordered]@{
        vin             = $safeVin
        label           = if ($VehicleInfo.label) { $VehicleInfo.label } elseif ($existingProfile -and $existingProfile['label']) { $existingProfile['label'] } else { "Vehicle $safeVin" }
        engine          = if ($VehicleInfo.engine) { $VehicleInfo.engine } elseif ($existingProfile) { $existingProfile['engine'] } else { '' }
        ecuName         = if ($VehicleInfo.ecuName) { $VehicleInfo.ecuName } elseif ($existingProfile) { $existingProfile['ecuName'] } else { '' }
        partNumber      = if ($VehicleInfo.partNumber) { $VehicleInfo.partNumber } elseif ($existingProfile) { $existingProfile['partNumber'] } else { '' }
        softwareVersion = if ($VehicleInfo.softwareVersion) { $VehicleInfo.softwareVersion } elseif ($existingProfile) { $existingProfile['softwareVersion'] } else { '' }
        hardwarePart    = if ($VehicleInfo.hardwarePart) { $VehicleInfo.hardwarePart } elseif ($existingProfile) { $existingProfile['hardwarePart'] } else { '' }
        hardwareVersion = if ($VehicleInfo.hardwareVersion) { $VehicleInfo.hardwareVersion } elseif ($existingProfile) { $existingProfile['hardwareVersion'] } else { '' }
        asamDataset     = if ($VehicleInfo.asamDataset) { $VehicleInfo.asamDataset } elseif ($existingProfile) { $existingProfile['asamDataset'] } else { '' }
        asamVersion     = if ($VehicleInfo.asamVersion) { $VehicleInfo.asamVersion } elseif ($existingProfile) { $existingProfile['asamVersion'] } else { '' }
        calid           = if ($VehicleInfo.calid) { $VehicleInfo.calid } elseif ($existingProfile) { $existingProfile['calid'] } else { '' }
        cvn             = if ($VehicleInfo.cvn) { $VehicleInfo.cvn } elseif ($existingProfile) { $existingProfile['cvn'] } else { '' }
        protocol        = if ($VehicleInfo.protocol) { $VehicleInfo.protocol } elseif ($existingProfile) { $existingProfile['protocol'] } else { '' }
        firstSeenAt     = $firstSeen
        lastSeenAt      = $nowIso
        sessionCount    = $mergedSessions.Count
        sessions        = $mergedSessions.ToArray()
    }
    Write-JsonFileNoBom -FilePath $profilePath -DataObj $profileObj -Depth 7

    $latestSummary = [ordered]@{
        rpm           = 0
        spd           = 0
        coolant       = 0
        volt          = 0
        fuel          = 0
        dtcCount      = 0
        engineRunning = $false
    }
    if ($LatestMetrics) {
        $latestSummary.rpm           = $LatestMetrics['rpm']
        $latestSummary.spd           = $LatestMetrics['spd']
        $latestSummary.coolant       = $LatestMetrics['coolant']
        $latestSummary.volt          = $LatestMetrics['volt']
        $latestSummary.fuel          = $LatestMetrics['fuel']
        $latestSummary.dtcCount      = $LatestMetrics['dtcCount']
        $latestSummary.engineRunning = $LatestMetrics['engineRunning']

        $latestDoc = [ordered]@{
            v             = 3
            ts            = $nowIso
            vin           = $safeVin
            vehicleLabel  = $profileObj.label
            sessionId     = $SessionId
            src           = $SourceTag
            variableCount = 124
            metrics       = $LatestMetrics
        }
        Write-JsonFileNoBom -FilePath $latestPath -DataObj $latestDoc -Depth 7
    }

    $existingIndex = $null
    if (Test-Path $indexPath) {
        try { $existingIndex = ConvertTo-PlainOrdered (Get-Content $indexPath -Raw | ConvertFrom-Json) } catch {}
    }
    $mergedVehicles = New-Object System.Collections.ArrayList
    if ($existingIndex -and $existingIndex['vehicles']) {
        foreach ($ev in @($existingIndex['vehicles'])) {
            $evVin = if ($ev -is [System.Collections.IDictionary]) { $ev['vin'] } else { $ev.vin }
            if ($evVin -and $evVin -ne $safeVin) {
                $null = $mergedVehicles.Add($ev)
            }
        }
    }
    $null = $mergedVehicles.Add([ordered]@{
        vin             = $safeVin
        label           = $profileObj.label
        engine          = $profileObj.engine
        ecuName         = $profileObj.ecuName
        partNumber      = $profileObj.partNumber
        softwareVersion = $profileObj.softwareVersion
        hardwarePart    = $profileObj.hardwarePart
        hardwareVersion = $profileObj.hardwareVersion
        calid           = $profileObj.calid
        cvn             = $profileObj.cvn
        firstSeenAt     = $profileObj.firstSeenAt
        lastSeenAt      = $profileObj.lastSeenAt
        sessionCount    = $profileObj.sessionCount
        latestSummary   = $latestSummary
        profilePath     = "vehicle_history/$safeVin/vehicle_profile.json"
        latestPath      = "vehicle_history/$safeVin/latest.json"
        sessionsDir     = "vehicle_history/$safeVin/sessions"
        serviceLogPath  = "vehicle_history/$safeVin/service_log.json"
    })
    $indexDoc = [ordered]@{
        version   = 1
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        note      = 'Per-vehicle telemetry archive inside the PulseOBD project folder. Each new vehicle gets its own <VIN>/ subfolder and individual session records.'
        vehicles  = $mergedVehicles.ToArray()
    }
    Write-JsonFileNoBom -FilePath $indexPath -DataObj $indexDoc -Depth 8
    return [ordered]@{
        vin         = $safeVin
        profilePath = $profilePath
        indexPath   = $indexPath
        sessionCount = $profileObj.sessionCount
    }
}

function Save-BridgeFrameToProjectFolder {
    param(
        [string]$HistoryRoot,
        $VehicleInfo,
        [string]$SessionId,
        [string]$SessionStartedAt,
        $Payload,
        [switch]$ForceJsonFlush
    )
    if (-not $HistoryRoot -or -not $Payload) { return }
    $safeVin = Get-SafeVinName -RawVin ([string]$VehicleInfo.vin) -FallbackPart ([string]$VehicleInfo.partNumber)
    $sessDir = Join-Path (Join-Path $HistoryRoot $safeVin) 'sessions'
    if (-not (Test-Path $sessDir)) {
        $null = New-Item -ItemType Directory -Path $sessDir -Force
    }
    $frameObj = [ordered]@{
        ts            = $Payload.timestamp
        src           = 'com3_bridge'
        rpm           = $Payload.rpm
        spd           = $Payload.spd
        load          = $Payload.load
        absLoad       = $Payload.absLoad
        coolant       = $Payload.coolant
        iat           = $Payload.iat
        amb           = $Payload.amb
        cat           = $Payload.cat
        stft          = $Payload.stft
        ltft          = $Payload.ltft
        secO2Trim     = $Payload.secO2Trim
        map           = $Payload.map
        baro          = $Payload.baro
        rail          = $Payload.rail
        timing        = $Payload.timing
        thr           = $Payload.thr
        thrB          = $Payload.thrB
        relThr        = $Payload.relThr
        actThr        = $Payload.actThr
        pedalD        = $Payload.pedalD
        pedalE        = $Payload.pedalE
        o2s1          = $Payload.o2s1
        o2s2          = $Payload.o2s2
        lambda        = $Payload.lambda
        fuel          = $Payload.fuel
        evap          = $Payload.evap
        volt          = $Payload.volt
        runtime       = $Payload.runtime
        milOn         = $Payload.milOn
        dtcCount      = $Payload.dtcCount
        engineRunning = $Payload.engineRunning
    }
    $null = $script:SessionFrames.Add($frameObj)

    $csvPath = Join-Path $sessDir "$SessionId.csv"
    if (-not $script:SessionCsvWrittenHeader -and -not (Test-Path $csvPath)) {
        $hdr = "timestamp,vin,rpm,spd,load,coolant,iat,amb,cat,stft,ltft,map,baro,rail,timing,thr,pedalD,o2s1,o2s2,lambda,fuel,evap,volt,runtime,dtcCount`r`n"
        [System.IO.File]::WriteAllText($csvPath, $hdr, $script:Utf8NoBom)
        $script:SessionCsvWrittenHeader = $true
    }
    $csvRow = "$($frameObj.ts),$safeVin,$($frameObj.rpm),$($frameObj.spd),$($frameObj.load),$($frameObj.coolant),$($frameObj.iat),$($frameObj.amb),$($frameObj.cat),$($frameObj.stft),$($frameObj.ltft),$($frameObj.map),$($frameObj.baro),$($frameObj.rail),$($frameObj.timing),$($frameObj.thr),$($frameObj.pedalD),$($frameObj.o2s1),$($frameObj.o2s2),$($frameObj.lambda),$($frameObj.fuel),$($frameObj.evap),$($frameObj.volt),$($frameObj.runtime),$($frameObj.dtcCount)`r`n"
    [System.IO.File]::AppendAllText($csvPath, $csvRow, $script:Utf8NoBom)

    if ($ForceJsonFlush -or $script:SessionFrames.Count -eq 1 -or ($script:SessionFrames.Count % 5 -eq 0)) {
        $staticArg = if ($script:SessionFrames.Count -le 1) { $Payload.staticDump } else { $null }
        $null = Upsert-ProjectVehicleFiles -HistoryRoot $HistoryRoot -VehicleInfo $VehicleInfo -SessionId $SessionId -SessionStartedAt $SessionStartedAt -TransportLabel 'COM3 · ELM327 v2.1 (38400 8N1)' -FramesArray $script:SessionFrames.ToArray() -LatestMetrics $frameObj -StaticDump $staticArg -SourceTag 'com3_bridge'
    }
}

$script:CachedRawMap = [ordered]@{}
$script:CachedBytesMap = @{}
$script:CachedAtrv = ''
$script:CachedM03 = ''
$script:CachedM07 = ''
$script:PollCycleIndex = 0
$script:FastMode01Pids = @('010C','010D','0104','010B','0123','0111','0149','0142')
$script:ExtMode01Pids  = @(
    '0101','0103','0105','0106','0107','010E','010F','0113','0114','0115','011C','011F',
    '0121','012E','012F','0130','0131','0133','013C','0141','0143','0144','0145','0146',
    '0147','014A','014C','0151','0156'
)

$script:BtYieldUntilUtc = [DateTime]::MinValue
$script:BtYieldReleasePort = $false
$script:BtManualUnlocked = $false

function Get-BtCoexistStatus {
    param([System.IO.Ports.SerialPort]$Port, [string]$PortName = 'COM3')
    if (-not $PortName) { $PortName = if ($script:ComPort) { $script:ComPort } else { 'COM3' } }
    $nowUtc = [DateTime]::UtcNow
    $remMs = 0
    if ($script:BtYieldUntilUtc -gt $nowUtc) {
        $remMs = [int][Math]::Ceiling(($script:BtYieldUntilUtc - $nowUtc).TotalMilliseconds)
    }
    $isOpen = ($null -ne $Port -and $Port.IsOpen)
    $stateStr = if ($script:BtManualUnlocked) {
        'unlocked'
    } elseif ($remMs -gt 0) {
        'yielding'
    } elseif ($script:ReleaseBetweenPolls -and -not $isOpen) {
        'shared_idle'
    } elseif ($isOpen) {
        'connected'
    } else {
        'standby'
    }
    return [ordered]@{
        mode             = $script:BtCoexistMode
        state            = $stateStr
        port             = $PortName
        portOpen         = $isOpen
        yielding         = ($remMs -gt 0)
        yieldRemainingMs = $remMs
        manualUnlocked   = [bool]$script:BtManualUnlocked
        releaseBetween   = [bool]$script:ReleaseBetweenPolls
        pollRestMs       = $script:PollIntervalMs
        gapMs            = $script:CoexistGapMs
    }
}

function Read-AllLiveTelemetry {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [string[]]$PidList,
        [hashtable]$StaticSession,
        $VehicleInfo,
        [int]$GapMs = 28,
        [switch]$FullSweep
    )
    $script:PollCycleIndex++
    if ($FullSweep -or $script:CachedBytesMap.Count -eq 0) {
        $pidsToQuery = $PidList
        $queryAtrv = $true
        $queryDtc = $true
    } else {
        $extCount = $script:ExtMode01Pids.Count
        $extSlice = @(
            $script:ExtMode01Pids[(($script:PollCycleIndex * 2) % $extCount)],
            $script:ExtMode01Pids[(($script:PollCycleIndex * 2 + 1) % $extCount)]
        )
        $pidsToQuery = $script:FastMode01Pids + $extSlice
        $queryAtrv = (($script:PollCycleIndex % 3) -eq 0)
        $queryDtc  = (($script:PollCycleIndex % 6) -eq 0)
    }

    foreach ($p in $pidsToQuery) {
        if ($script:BtManualUnlocked -or ([DateTime]::UtcNow -lt $script:BtYieldUntilUtc)) { break }
        $r = Send-ElmReadOnly $Port $p 1500
        $script:CachedRawMap[$p] = $r
        $script:CachedBytesMap[$p] = Parse-CanDataBytes $r
        if ($GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
    }
    if (-not $script:BtManualUnlocked -and ([DateTime]::UtcNow -ge $script:BtYieldUntilUtc)) {
        if ($queryAtrv -or -not $script:CachedAtrv) {
            $script:CachedAtrv = Send-ElmReadOnly $Port 'ATRV' 1500
            if ($GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
        }
        if ($queryDtc -or -not $script:CachedM03) {
            $script:CachedM03 = Send-ElmReadOnly $Port '03' 1500
            $script:CachedM07 = Send-ElmReadOnly $Port '07' 1500
        }
    }

    $rawMap = $script:CachedRawMap
    $bytesMap = $script:CachedBytesMap
    $atrv = $script:CachedAtrv
    $m03  = $script:CachedM03
    $m07  = $script:CachedM07

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

    $rpmVal = if ($b0C -and $b0C.Count -ge 2) { [Math]::Round((256 * $b0C[0] + $b0C[1]) / 4.0, 1) } else { 0 }
    $ecuAwake = (($b0C -and $b0C.Count -ge 2) -or ($b42 -and $b42.Count -ge 2) -or ($b05 -and $b05.Count -ge 1))
    $engineRunning = ($rpmVal -ge 50)
    $atrvVolt = 0.0
    if ($atrv -match '(\d+(?:\.\d+)?)\s*V') {
        try { $atrvVolt = [double]$Matches[1] } catch { $atrvVolt = 0.0 }
    }
    $voltVal = if ($b42 -and $b42.Count -ge 2) { [Math]::Round((256 * $b42[0] + $b42[1]) / 1000.0, 3) } else { [Math]::Round($atrvVolt, 3) }
    $fuelSysLabel = if ($engineRunning) { 'Closed loop (using O2 sensor)' } elseif ($ecuAwake) { 'Open loop — Engine Off' } else { 'Open loop — Engine/ECU Off' }

    $vinVal = if ($VehicleInfo -and $VehicleInfo.vin) { [string]$VehicleInfo.vin } else { 'AAVZZZ6RZHU112564' }
    $payload = [ordered]@{
        timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        vin           = $vinVal
        vehicle       = $VehicleInfo
        readOnly      = $true
        ecuAwake      = $ecuAwake
        engineRunning = $engineRunning
        fuelSys1      = $fuelSysLabel
        atrv          = $atrv
        milOn      = if ($b01 -and $b01.Count -ge 1) { ($b01[0] -band 0x80) -ne 0 } else { $false }
        dtcCount   = if ($b01 -and $b01.Count -ge 1) { ($b01[0] -band 0x7F) } else { 0 }
        load       = if ($b04 -and $b04.Count -ge 1) { [Math]::Round($b04[0] * 100.0 / 255.0, 1) } else { 0 }
        coolant    = if ($b05 -and $b05.Count -ge 1) { $b05[0] - 40 } else { 0 }
        stft       = if ($b06 -and $b06.Count -ge 1) { [Math]::Round(($b06[0] - 128) * 100.0 / 128.0, 2) } else { 0 }
        ltft       = if ($b07 -and $b07.Count -ge 1) { [Math]::Round(($b07[0] - 128) * 100.0 / 128.0, 2) } else { 0 }
        map        = if ($b0B -and $b0B.Count -ge 1) { $b0B[0] } else { 0 }
        rpm        = $rpmVal
        spd        = if ($b0D -and $b0D.Count -ge 1) { $b0D[0] } else { 0 }
        timing     = if ($b0E -and $b0E.Count -ge 1) { [Math]::Round($b0E[0] / 2.0 - 64.0, 1) } else { 0 }
        iat        = if ($b0F -and $b0F.Count -ge 1) { $b0F[0] - 40 } else { 0 }
        thr        = if ($b11 -and $b11.Count -ge 1) { [Math]::Round($b11[0] * 100.0 / 255.0, 1) } else { 0 }
        o2s1       = if ($b14 -and $b14.Count -ge 1) { [Math]::Round($b14[0] / 200.0, 3) } else { 0 }
        o2s1Trim   = if ($b14 -and $b14.Count -ge 2 -and $b14[1] -ne 255) { [Math]::Round(($b14[1] - 128) * 100.0 / 128.0, 2) } else { 0 }
        o2s2       = if ($b15 -and $b15.Count -ge 1) { [Math]::Round($b15[0] / 200.0, 3) } else { 0 }
        runtime    = if ($b1F -and $b1F.Count -ge 2) { 256 * $b1F[0] + $b1F[1] } else { 0 }
        distMilOn  = if ($b21 -and $b21.Count -ge 2) { 256 * $b21[0] + $b21[1] } else { 0 }
        rail       = if ($b23 -and $b23.Count -ge 2) { [Math]::Round((10.0 * (256 * $b23[0] + $b23[1])) / 1000.0, 2) } else { 0 }
        evap       = if ($b2E -and $b2E.Count -ge 1) { [Math]::Round($b2E[0] * 100.0 / 255.0, 1) } else { 0 }
        fuel       = if ($b2F -and $b2F.Count -ge 1) { [Math]::Round($b2F[0] * 100.0 / 255.0, 1) } else { 0 }
        warmups    = if ($b30 -and $b30.Count -ge 1) { $b30[0] } else { 0 }
        distClear  = if ($b31 -and $b31.Count -ge 2) { 256 * $b31[0] + $b31[1] } else { 0 }
        baro       = if ($b33 -and $b33.Count -ge 1) { $b33[0] } else { 83 }
        cat        = if ($b3C -and $b3C.Count -ge 2) { [Math]::Round((256 * $b3C[0] + $b3C[1]) / 10.0 - 40.0, 1) } else { 0 }
        volt       = $voltVal
        absLoad    = if ($b43 -and $b43.Count -ge 2) { [Math]::Round((256 * $b43[0] + $b43[1]) * 100.0 / 255.0, 1) } else { 0 }
        lambda     = if ($b44 -and $b44.Count -ge 2) { [Math]::Round(2.0 / 65536.0 * (256 * $b44[0] + $b44[1]), 4) } else { 1.0 }
        relThr     = if ($b45 -and $b45.Count -ge 1) { [Math]::Round($b45[0] * 100.0 / 255.0, 1) } else { 0 }
        amb        = if ($b46 -and $b46.Count -ge 1) { $b46[0] - 40 } else { 0 }
        thrB       = if ($b47 -and $b47.Count -ge 1) { [Math]::Round($b47[0] * 100.0 / 255.0, 1) } else { 0 }
        pedalD     = if ($b49 -and $b49.Count -ge 1) { [Math]::Round($b49[0] * 100.0 / 255.0, 1) } else { 0 }
        pedalE     = if ($b4A -and $b4A.Count -ge 1) { [Math]::Round($b4A[0] * 100.0 / 255.0, 1) } else { 0 }
        actThr     = if ($b4C -and $b4C.Count -ge 1) { [Math]::Round($b4C[0] * 100.0 / 255.0, 1) } else { 0 }
        secO2Trim  = if ($b56 -and $b56.Count -ge 1) { [Math]::Round(($b56[0] - 128) * 100.0 / 128.0, 2) } else { 0 }
        mode03Raw  = $m03
        mode07Raw  = $m07
        mode01Raw  = $rawMap
        staticDump = $StaticSession
        btCoexist  = (Get-BtCoexistStatus -Port $Port -PortName $script:ComPort)
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
    Write-Host "Opening $ComPort @ $BaudRate baud (Strictly Read-Only + BT Coexistence [$BtCoexistMode] Gap ${CoexistGapMs}ms / Rest ${PollIntervalMs}ms)..." -ForegroundColor Cyan
    $null = Open-ObdComPort -Port $port

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
    $initGapMs = [Math]::Min(20, [Math]::Max(8, $CoexistGapMs))
    foreach ($m6 in @('0600','0620','0640','0660','0680','06A0','0601','0602','0621','0635','063D','0641','0642','06A2','06A3','06A4','06A5')) {
        $staticSession.Mode06[$m6] = Send-ElmReadOnly $port $m6 2500
        if ($initGapMs -gt 0) { Start-Sleep -Milliseconds $initGapMs }
    }
    foreach ($m9 in @('0900','0902','0904','0906','0908','090A')) {
        $staticSession.Mode09[$m9] = Send-ElmReadOnly $port $m9 3000
        if ($initGapMs -gt 0) { Start-Sleep -Milliseconds $initGapMs }
    }
    $null = Send-ElmReadOnly $port 'ATSH 7E0'
    $null = Send-ElmReadOnly $port 'ATCRA 7E8'
    $null = Send-ElmReadOnly $port 'ATFCSH 7E0'
    $null = Send-ElmReadOnly $port 'ATFCSD 30 00 00'
    $null = Send-ElmReadOnly $port 'ATFCSM 1'
    foreach ($did in @('F187','F189','F190','F191','F197','F19E','F1A2','F1A3','F400','1002','2001')) {
        $staticSession.Uds7E0[$did] = Send-ElmReadOnly $port ("22" + $did) 2000
        if ($initGapMs -gt 0) { Start-Sleep -Milliseconds $initGapMs }
    }
    $null = Send-ElmReadOnly $port 'ATFCSM 0'
    $null = Send-ElmReadOnly $port 'ATD'
    Invoke-FastElmInit -Port $port

    $ActiveVehicle = Resolve-VehicleIdentity -StaticSession $staticSession
    Initialize-CloudEndpointUrls -ActiveVin $ActiveVehicle.vin
    Write-Host "Identified Vehicle VIN: $($ActiveVehicle.vin) | $($ActiveVehicle.label) | Archive -> $VehicleHistoryRoot\$($ActiveVehicle.vin)" -ForegroundColor Cyan

    # Initial live full sweep + immediate project-folder record creation
    $latestPayload = Read-AllLiveTelemetry -Port $port -PidList $allMode01Pids -StaticSession $staticSession -VehicleInfo $ActiveVehicle -GapMs $CoexistGapMs -FullSweep
    if ($ReleaseBetweenPolls) {
        Close-ObdComPort -Port $port
        Write-Host "Shared Release Mode active: $ComPort unlocked between bursts so other Bluetooth devices connect freely." -ForegroundColor Yellow
    }
    $lastPollSw.Restart()

    try {
        Save-BridgeFrameToProjectFolder -HistoryRoot $VehicleHistoryRoot -VehicleInfo $ActiveVehicle -SessionId $TripSessionId -SessionStartedAt $sessionStartedAt -Payload $latestPayload -ForceJsonFlush
    } catch {
        Write-Warning "Project folder archive note: $($_.Exception.Message)"
    }

    $listener.Start()
    Write-Host "PulseOBD Bridge listening on http://localhost:$HttpPort/api/live" -ForegroundColor Green
    Write-Host "BT Coexistence API -> /api/bt-yield | /api/bt-unlock | /api/bt-resume | /api/bt-config" -ForegroundColor Green
    Write-Host "Project Folder Archive API -> http://localhost:$HttpPort/api/vehicles" -ForegroundColor Green
    Write-Host "Service Log API -> http://localhost:$HttpPort/api/service-log & /api/save-service" -ForegroundColor Green
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
            $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')

            $reqPath = $req.Url.AbsolutePath
            $queryMap = @{}
            if ($req.Url.Query) {
                $qTrim = $req.Url.Query.TrimStart('?')
                foreach ($pair in ($qTrim -split '&')) {
                    if (-not $pair) { continue }
                    $kv = $pair -split '=', 2
                    $qk = [Uri]::UnescapeDataString($kv[0])
                    $qv = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1]) } else { '' }
                    $queryMap[$qk] = $qv
                }
            }

            if ($req.HttpMethod -eq 'OPTIONS') {
                $res.StatusCode = 204
            } elseif ($reqPath -eq '/api/live' -or $reqPath -eq '/api/snapshot') {
                if (-not $latestPayload -and $port.IsOpen -and -not $script:BtManualUnlocked -and ([DateTime]::UtcNow -ge $script:BtYieldUntilUtc)) {
                    try {
                        $latestPayload = Read-AllLiveTelemetry -Port $port -PidList $allMode01Pids -StaticSession $staticSession -VehicleInfo $ActiveVehicle -GapMs $CoexistGapMs
                    } catch {}
                }
                $btStatusNow = (Get-BtCoexistStatus -Port $port -PortName $ComPort)
                $includeFullDump = ($queryMap['full'] -eq '1')
                if ($latestPayload) {
                    $liveObj = [ordered]@{}
                    foreach ($k in $latestPayload.Keys) {
                        if (-not $includeFullDump -and ($k -eq 'mode01Raw' -or $k -eq 'staticDump')) { continue }
                        $liveObj[$k] = $latestPayload[$k]
                    }
                    $liveObj['btCoexist'] = $btStatusNow
                } else {
                    $liveObj = [ordered]@{ btCoexist = $btStatusNow }
                }
                $jsonBytes = $Utf8NoBom.GetBytes(($liveObj | ConvertTo-Json -Depth 6 -Compress))
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($jsonBytes, 0, $jsonBytes.Length)
            } elseif ($reqPath -eq '/api/bt-yield') {
                $durMs = 20000
                $doRelease = $true
                if ($queryMap['ms']) { try { $durMs = [Math]::Max(2000, [Math]::Min(180000, [int]$queryMap['ms'])) } catch {} }
                if ($queryMap['release'] -eq '0' -or $queryMap['release'] -eq 'false') { $doRelease = $false }
                if ($req.HttpMethod -eq 'POST') {
                    try {
                        $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                        $rawB = $sr.ReadToEnd()
                        $sr.Close()
                        if ($rawB) {
                            $bObj = $rawB | ConvertFrom-Json
                            if ($bObj.durationMs) { $durMs = [Math]::Max(2000, [Math]::Min(180000, [int]$bObj.durationMs)) }
                            if ($null -ne $bObj.releasePort) { $doRelease = [bool]$bObj.releasePort }
                        }
                    } catch {}
                }
                $script:BtManualUnlocked = $false
                $script:BtYieldReleasePort = $doRelease
                $script:BtYieldUntilUtc = [DateTime]::UtcNow.AddMilliseconds($durMs)
                if ($doRelease -and $port.IsOpen) {
                    Close-ObdComPort -Port $port
                    Write-Host "[BT COEXIST] Yielding RF & released $ComPort for $([Math]::Round($durMs/1000,1))s — pair/connect other BT devices now." -ForegroundColor Yellow
                } else {
                    Write-Host "[BT COEXIST] Paused $ComPort polling for $([Math]::Round($durMs/1000,1))s for BT coexistence." -ForegroundColor Yellow
                }
                $btStatus = (Get-BtCoexistStatus -Port $port -PortName $ComPort) | ConvertTo-Json
                $bBytes = $Utf8NoBom.GetBytes($btStatus)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($bBytes, 0, $bBytes.Length)
            } elseif ($reqPath -eq '/api/bt-unlock') {
                $script:BtManualUnlocked = $true
                $script:BtYieldUntilUtc = [DateTime]::MinValue
                Close-ObdComPort -Port $port
                Write-Host "[BT COEXIST] $ComPort manually unlocked/released for external Bluetooth devices. Call /api/bt-resume when ready." -ForegroundColor Yellow
                $btStatus = (Get-BtCoexistStatus -Port $port -PortName $ComPort) | ConvertTo-Json
                $bBytes = $Utf8NoBom.GetBytes($btStatus)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($bBytes, 0, $bBytes.Length)
            } elseif ($reqPath -eq '/api/bt-resume') {
                $script:BtManualUnlocked = $false
                $script:BtYieldUntilUtc = [DateTime]::MinValue
                $script:BtYieldReleasePort = $false
                if (-not $ReleaseBetweenPolls -and -not $port.IsOpen) {
                    try {
                        $null = Open-ObdComPort -Port $port -FastReopen
                        Invoke-FastElmInit -Port $port
                        Write-Host "[BT COEXIST] Reopened $ComPort cleanly — OBD polling resumed." -ForegroundColor Green
                    } catch {
                        Write-Warning "Resume $ComPort note: $($_.Exception.Message)"
                    }
                } else {
                    Write-Host "[BT COEXIST] OBD polling resumed immediately." -ForegroundColor Green
                }
                $lastPollSw.Restart()
                $btStatus = (Get-BtCoexistStatus -Port $port -PortName $ComPort) | ConvertTo-Json
                $bBytes = $Utf8NoBom.GetBytes($btStatus)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($bBytes, 0, $bBytes.Length)
            } elseif ($reqPath -eq '/api/bt-config') {
                if ($req.HttpMethod -eq 'POST') {
                    try {
                        $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                        $rawB = $sr.ReadToEnd()
                        $sr.Close()
                        if ($rawB) {
                            $cfgObj = $rawB | ConvertFrom-Json
                            if ($cfgObj.mode -and $cfgObj.mode -in @('coexist','audio_priority','shared_release','performance')) {
                                $script:BtCoexistMode = [string]$cfgObj.mode
                                switch ($script:BtCoexistMode) {
                                    'shared_release' {
                                        $script:ReleaseBetweenPolls = $true
                                        $script:CoexistGapMs = 30
                                        $script:PollIntervalMs = 2200
                                    }
                                    'audio_priority' {
                                        $script:ReleaseBetweenPolls = $false
                                        $script:CoexistGapMs = 48
                                        $script:PollIntervalMs = 1100
                                    }
                                    'performance' {
                                        $script:ReleaseBetweenPolls = $false
                                        $script:CoexistGapMs = 8
                                        $script:PollIntervalMs = 180
                                    }
                                    default {
                                        $script:ReleaseBetweenPolls = $false
                                        $script:CoexistGapMs = 28
                                        $script:PollIntervalMs = 750
                                    }
                                }
                                if ($script:ReleaseBetweenPolls -and $port.IsOpen) {
                                    Close-ObdComPort -Port $port
                                } elseif (-not $script:ReleaseBetweenPolls -and -not $script:BtManualUnlocked -and -not $port.IsOpen) {
                                    try { $null = Open-ObdComPort -Port $port -FastReopen; Invoke-FastElmInit -Port $port } catch {}
                                }
                                Write-Host "[BT COEXIST] Profile switched to $BtCoexistMode (Gap ${CoexistGapMs}ms / Rest ${PollIntervalMs}ms / ReleaseBetween=$ReleaseBetweenPolls)" -ForegroundColor Cyan
                            }
                        }
                    } catch {}
                }
                $btStatus = (Get-BtCoexistStatus -Port $port -PortName $ComPort) | ConvertTo-Json
                $bBytes = $Utf8NoBom.GetBytes($btStatus)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($bBytes, 0, $bBytes.Length)
            } elseif ($reqPath -eq '/api/vehicles') {
                $idxFile = Join-Path $VehicleHistoryRoot 'vehicles_index.json'
                $outTxt = if (Test-Path $idxFile) { [System.IO.File]::ReadAllText($idxFile, $Utf8NoBom) } else { '{"version":1,"vehicles":[]}' }
                $vBytes = $Utf8NoBom.GetBytes($outTxt)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($vBytes, 0, $vBytes.Length)
            } elseif ($reqPath -eq '/api/vehicle-history') {
                $reqVin = if ($queryMap['vin']) { Get-SafeVinName -RawVin $queryMap['vin'] } elseif ($ActiveVehicle) { $ActiveVehicle.vin } else { 'AAVZZZ6RZHU112564' }
                $reqSess = $queryMap['session']
                $targetFile = if ($reqSess) {
                    $safeSess = ($reqSess -replace '[^A-Za-z0-9_.-]', '')
                    Join-Path (Join-Path (Join-Path $VehicleHistoryRoot $reqVin) 'sessions') "$safeSess.json"
                } else {
                    Join-Path (Join-Path $VehicleHistoryRoot $reqVin) 'vehicle_profile.json'
                }
                if (Test-Path $targetFile) {
                    $outTxt = [System.IO.File]::ReadAllText($targetFile, $Utf8NoBom)
                    $hBytes = $Utf8NoBom.GetBytes($outTxt)
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.OutputStream.Write($hBytes, 0, $hBytes.Length)
                } else {
                    $res.StatusCode = 404
                    $errBytes = $Utf8NoBom.GetBytes('{"error":"Not found"}')
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.OutputStream.Write($errBytes, 0, $errBytes.Length)
                }
            } elseif ($reqPath -eq '/api/save-history' -and $req.HttpMethod -eq 'POST') {
                try {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $rawBody = $sr.ReadToEnd()
                    $sr.Close()
                    $bodyObj = ConvertTo-PlainOrdered ($rawBody | ConvertFrom-Json)
                    $vInfo = if ($bodyObj['vehicle']) { $bodyObj['vehicle'] } else { [ordered]@{ vin = 'AAVZZZ6RZHU112564' } }
                    $sMeta = if ($bodyObj['session']) { $bodyObj['session'] } else { [ordered]@{} }
                    $sSamples = if ($bodyObj['samples']) { @($bodyObj['samples']) } else { @() }
                    $sId = if ($sMeta['id']) { [string]$sMeta['id'] } else { 'drv_' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') }
                    $sStart = if ($sMeta['startedAt']) { [string]$sMeta['startedAt'] } else { (Get-Date).ToUniversalTime().ToString('o') }
                    $sTrans = if ($sMeta['transport']) { [string]$sMeta['transport'] } else { 'Browser Client' }
                    $lastSample = if ($sSamples.Count -gt 0) { $sSamples[$sSamples.Count - 1] } else { $null }
                    $savedInfo = Upsert-ProjectVehicleFiles -HistoryRoot $VehicleHistoryRoot -VehicleInfo $vInfo -SessionId $sId -SessionStartedAt $sStart -TransportLabel $sTrans -FramesArray $sSamples -LatestMetrics $lastSample -StaticDump $bodyObj['staticDump'] -SourceTag 'studio_web'
                    $respJson = ($savedInfo | ConvertTo-Json -Depth 4)
                    $rBytes = $Utf8NoBom.GetBytes($respJson)
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.OutputStream.Write($rBytes, 0, $rBytes.Length)
                } catch {
                    $res.StatusCode = 400
                    $errJson = ([ordered]@{ error = $_.Exception.Message } | ConvertTo-Json)
                    $eBytes = $Utf8NoBom.GetBytes($errJson)
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.OutputStream.Write($eBytes, 0, $eBytes.Length)
                }
            } elseif ($reqPath -eq '/api/service-log') {
                $reqVin = if ($queryMap['vin']) { Get-SafeVinName -RawVin $queryMap['vin'] } elseif ($ActiveVehicle) { $ActiveVehicle.vin } else { 'AAVZZZ6RZHU112564' }
                $svcFile = Join-Path (Join-Path $VehicleHistoryRoot $reqVin) 'service_log.json'
                if (Test-Path $svcFile) {
                    $outTxt = [System.IO.File]::ReadAllText($svcFile, $Utf8NoBom)
                    $svBytes = $Utf8NoBom.GetBytes($outTxt)
                } else {
                    $emptyDoc = ([ordered]@{
                        version          = 1
                        vin              = $reqVin
                        vehicleLabel     = if ($ActiveVehicle -and $ActiveVehicle.vin -eq $reqVin) { $ActiveVehicle.label } else { "Vehicle $reqVin" }
                        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
                        latestOdometerKm = $null
                        records          = @()
                    } | ConvertTo-Json -Depth 4)
                    $svBytes = $Utf8NoBom.GetBytes($emptyDoc)
                }
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($svBytes, 0, $svBytes.Length)
            } elseif ($reqPath -eq '/api/save-service' -and $req.HttpMethod -eq 'POST') {
                try {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $rawBody = $sr.ReadToEnd()
                    $sr.Close()
                    $bodyObj = ConvertTo-PlainOrdered ($rawBody | ConvertFrom-Json)
                    $reqVin = Get-SafeVinName -RawVin ([string]$bodyObj['vin']) -FallbackPart ([string]$bodyObj['partNumber'])
                    $vinDir = Join-Path $VehicleHistoryRoot $reqVin
                    if (-not (Test-Path $vinDir)) {
                        $null = New-Item -ItemType Directory -Path $vinDir -Force
                    }
                    $svcFile = Join-Path $vinDir 'service_log.json'
                    $recordsArr = if ($bodyObj['records']) { @($bodyObj['records']) } else { @() }
                    $svcDoc = [ordered]@{
                        version          = 1
                        vin              = $reqVin
                        vehicleLabel     = if ($bodyObj['vehicleLabel']) { [string]$bodyObj['vehicleLabel'] } else { "Vehicle $reqVin" }
                        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
                        latestOdometerKm = $bodyObj['latestOdometerKm']
                        records          = $recordsArr
                    }
                    Write-JsonFileNoBom -FilePath $svcFile -DataObj $svcDoc -Depth 8
                    $respJson = ([ordered]@{
                        saved       = $true
                        vin         = $reqVin
                        path        = "vehicle_history/$reqVin/service_log.json"
                        recordCount = $recordsArr.Count
                    } | ConvertTo-Json -Depth 4)
                    $rBytes = $Utf8NoBom.GetBytes($respJson)
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.OutputStream.Write($rBytes, 0, $rBytes.Length)
                } catch {
                    $res.StatusCode = 400
                    $errJson = ([ordered]@{ error = $_.Exception.Message } | ConvertTo-Json)
                    $eBytes = $Utf8NoBom.GetBytes($errJson)
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.OutputStream.Write($eBytes, 0, $eBytes.Length)
                }
            } elseif ($reqPath.StartsWith('/vehicle_history/')) {
                $relPath = $reqPath.Substring('/vehicle_history/'.Length).TrimStart('/')
                $candidate = [System.IO.Path]::GetFullPath((Join-Path $VehicleHistoryRoot ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
                $rootFull = [System.IO.Path]::GetFullPath($VehicleHistoryRoot)
                if ($candidate.StartsWith($rootFull) -and (Test-Path $candidate) -and -not (Get-Item $candidate).PSIsContainer) {
                    $bytes = [System.IO.File]::ReadAllBytes($candidate)
                    $res.ContentType = if ($candidate.EndsWith('.csv')) { 'text/csv; charset=utf-8' } else { 'application/json; charset=utf-8' }
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $res.StatusCode = 404
                    $errBytes = $Utf8NoBom.GetBytes('{"error":"Not found"}')
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.OutputStream.Write($errBytes, 0, $errBytes.Length)
                }
            } elseif ($reqPath -eq '/api/cloud-status') {
                $statusJson = [ordered]@{
                    provider     = $CloudProvider
                    channel      = $CloudChannel
                    vin          = $ActiveVehicle.vin
                    vehicleLabel = $ActiveVehicle.label
                    sessionId    = $TripSessionId
                    txCount      = $cloudTxCount
                    queuedCount  = $cloudOfflineQueue.Count
                    saveHistory  = $SaveCloudHistory
                    configured   = [bool]$ResolvedCloudUrl
                    archiveRoot  = $VehicleHistoryRoot
                    btCoexist    = (Get-BtCoexistStatus -Port $port -PortName $ComPort)
                } | ConvertTo-Json
                $sBytes = $Utf8NoBom.GetBytes($statusJson)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.OutputStream.Write($sBytes, 0, $sBytes.Length)
            } else {
                $candidates = @(
                    (Join-Path $PSScriptRoot 'PulseOBD_Studio.html'),
                    (Join-Path $PSScriptRoot 'index.html'),
                    (Join-Path $ProjectRoot 'PulseOBD_Studio.html'),
                    (Join-Path $ProjectRoot 'index.html')
                )
                $htmlPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($htmlPath) {
                    $bytes = [System.IO.File]::ReadAllBytes($htmlPath)
                    $res.ContentType = 'text/html; charset=utf-8'
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $msg = $Utf8NoBom.GetBytes('PulseOBD Read-Only All-Variable COM3 + Project Folder Archive Bridge Running.')
                    $res.OutputStream.Write($msg, 0, $msg.Length)
                }
            }
            $res.Close()
        }

        # 2. Periodic autonomous COM3 poll + guaranteed RF idle rest + per-VIN Project Folder Archive + Auto Cloud TX
        $nowUtc = [DateTime]::UtcNow
        $inYield = ($nowUtc -lt $script:BtYieldUntilUtc)
        if (-not $inYield -and $script:BtYieldUntilUtc -ne [DateTime]::MinValue) {
            $script:BtYieldUntilUtc = [DateTime]::MinValue
            $script:BtYieldReleasePort = $false
            Write-Host "[BT COEXIST] Yield window ended — resuming $ComPort telemetry seamlessly." -ForegroundColor Green
        }
        $effectiveRestMs = if ($ReleaseBetweenPolls) { [Math]::Max(800, $ReleaseRestMs) } else { $PollIntervalMs }

        if (-not $script:BtManualUnlocked -and -not $inYield -and ($lastPollSw.ElapsedMilliseconds -ge $effectiveRestMs)) {
            $polledOk = $false
            try {
                if (-not $port.IsOpen) {
                    $null = Open-ObdComPort -Port $port -FastReopen
                    Invoke-FastElmInit -Port $port
                }
                $latestPayload = Read-AllLiveTelemetry -Port $port -PidList $allMode01Pids -StaticSession $staticSession -VehicleInfo $ActiveVehicle -GapMs $CoexistGapMs
                $polledOk = $true
            } catch {
                Write-Warning "COM3 transient BT coexistence note: $($_.Exception.Message)"
                Close-ObdComPort -Port $port
            } finally {
                if ($ReleaseBetweenPolls -and $port.IsOpen) {
                    Close-ObdComPort -Port $port
                }
                # Restart rest timer AFTER poll completes so Windows Bluetooth always gets true idle airtime!
                $lastPollSw.Restart()
            }

            if ($polledOk -and $SaveLocalJson -and $latestPayload) {
                try {
                    $diagDir = Join-Path $ProjectRoot 'diagnostics'
                    if (-not (Test-Path $diagDir)) { $diagDir = $PSScriptRoot }
                    $outJsonPath = Join-Path $diagDir 'live_telemetry_latest.json'
                    [System.IO.File]::WriteAllText($outJsonPath, ($latestPayload | ConvertTo-Json -Depth 6), $Utf8NoBom)
                } catch {}
                try {
                    Save-BridgeFrameToProjectFolder -HistoryRoot $VehicleHistoryRoot -VehicleInfo $ActiveVehicle -SessionId $TripSessionId -SessionStartedAt $sessionStartedAt -Payload $latestPayload
                } catch {}
            }

            if ($polledOk -and $latestPayload -and $EnableCloudStream -and $ResolvedCloudUrl -and $lastCloudSw.ElapsedMilliseconds -ge $CloudIntervalMs) {
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
                    vin           = $ActiveVehicle.vin
                    vehicle       = $ActiveVehicle
                    src           = 'com3_bridge'
                    variableCount = 124
                    metrics       = $metricsObj
                }
                if ($CloudProvider -ne 'ntfy') {
                    if (($cloudTxCount % 10) -eq 0) {
                        $packetObj['mode01Raw'] = $latestPayload.mode01Raw
                    }
                    if (($cloudTxCount % 60) -eq 0) {
                        $packetObj['staticDump'] = $latestPayload.staticDump
                    }
                }

                $wireObj = if ($CloudProvider -eq 'supabase') {
                    [ordered]@{
                        channel_id = $CloudChannel
                        vin        = $ActiveVehicle.vin
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
                                    vin         = $ActiveVehicle.vin
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
    if ($SaveLocalJson -and $ActiveVehicle -and $script:SessionFrames.Count -gt 0) {
        try {
            $lastFr = $script:SessionFrames[$script:SessionFrames.Count - 1]
            $null = Upsert-ProjectVehicleFiles -HistoryRoot $VehicleHistoryRoot -VehicleInfo $ActiveVehicle -SessionId $TripSessionId -SessionStartedAt $sessionStartedAt -TransportLabel 'COM3 · ELM327 v2.1 (38400 8N1)' -FramesArray $script:SessionFrames.ToArray() -LatestMetrics $lastFr -StaticDump $staticSession -SourceTag 'com3_bridge'
            Write-Host "Saved $($script:SessionFrames.Count) frame(s) to $VehicleHistoryRoot\$($ActiveVehicle.vin)\sessions\$TripSessionId.json" -ForegroundColor Green
        } catch {}
    }
    if ($null -ne $httpClient) { $httpClient.Dispose() }
    if ($listener.IsListening) { $listener.Stop() }
    if ($port.IsOpen) {
        try { $null = Send-ElmReadOnly $port 'ATD' 1000 } catch {}
        $port.Close()
        Write-Host "Closed $ComPort cleanly." -ForegroundColor Green
    }
    $port.Dispose()
}
