[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DeviceId,

    [ValidateSet('phone', 'tablet')]
    [string]$DeviceType = 'phone',

    [ValidateSet('all', 'happy-path', 'account-selection-pin-gate')]
    [string]$Test = 'all',

    [string]$ConfigPath,

    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
$env:MAESTRO_CLI_NO_ANALYTICS = 'true'
$env:JAVA_TOOL_OPTIONS = "-Duser.home=$PSScriptRoot"

$adbCommand = Get-Command adb -ErrorAction SilentlyContinue
if (-not $adbCommand) {
    $platformToolsPath = 'C:\platform-tools'
    $fallbackAdbPath = Join-Path $platformToolsPath 'adb.exe'
    if (-not (Test-Path -LiteralPath $fallbackAdbPath -PathType Leaf)) {
        throw 'ADB was not found on PATH or at C:\platform-tools\adb.exe.'
    }
    $env:Path = "$platformToolsPath;$env:Path"
    $adbPath = $fallbackAdbPath
}
else {
    $adbPath = $adbCommand.Source
}

$connectedDeviceIds = @(
    & $adbPath devices 2>$null |
        Select-Object -Skip 1 |
        ForEach-Object {
            if ($_ -match '^([^\s]+)\s+device(?:\s|$)') { $Matches[1] }
        }
)
if ($DeviceId -notin $connectedDeviceIds) {
    $detected = if ($connectedDeviceIds.Count) { $connectedDeviceIds -join ', ' } else { 'none' }
    throw "Android device '$DeviceId' is not connected and authorized. Detected devices: $detected"
}

# Keep the connected test device awake and dismiss a non-secure keyguard.
& $adbPath -s $DeviceId shell input keyevent KEYCODE_WAKEUP 2>$null | Out-Null
& $adbPath -s $DeviceId shell wm dismiss-keyguard 2>$null | Out-Null
& $adbPath -s $DeviceId shell input keyevent 82 2>$null | Out-Null
& $adbPath -s $DeviceId shell svc power stayon usb 2>$null | Out-Null

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\stg.psd1'
}
if (-not (Get-Command maestro -ErrorAction SilentlyContinue)) {
    throw 'Maestro was not found on PATH.'
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config file not found: $ConfigPath"
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$requiredKeys = @(
    'AppId', 'MerchantName', 'MerchantEmail', 'MerchantPassword',
    'MerchantPin', 'InvalidPin', 'SwitchStoreA', 'SwitchStoreB', 'InactiveStore'
)
foreach ($key in $requiredKeys) {
    if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$config[$key])) {
        throw "Missing required Switch Store config value: $key"
    }
}
if ([string]$config.MerchantPin -notmatch '^\d{4}$') {
    throw 'MerchantPin must contain exactly four digits.'
}
if ([string]$config.InvalidPin -notmatch '^\d{4}$') {
    throw 'InvalidPin must contain exactly four digits.'
}

$testOrder = @('happy-path', 'account-selection-pin-gate')
$selectedTests = if ($Test -eq 'all') { $testOrder } else { @($Test) }
$flowRoot = Join-Path $PSScriptRoot 'switch-store'
$flowPaths = foreach ($testName in $selectedTests) {
    $path = Join-Path $flowRoot "$testName.yaml"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Testcase file not found: $path"
    }
    $path
}
$ticketPath = Join-Path $PSScriptRoot 'metadata\tickets.psd1'
$tickets = Import-PowerShellDataFile -LiteralPath $ticketPath
$ticketGroupName = if ($DeviceType -eq 'tablet') { 'switchStoreTablet' } else { 'switchStorePhone' }
$deviceTickets = $tickets[$ticketGroupName]
if (-not $deviceTickets) {
    throw "Switch Store ticket mapping not found for Android $DeviceType."
}
$reportRoot = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null

$datePrefix = Get-Date -Format 'yyyyMMdd'
$highestCounter = 0
Get-ChildItem -LiteralPath $reportRoot -Filter "$datePrefix`_*.html" -File | ForEach-Object {
    if ($_.BaseName -match "^$datePrefix`_(\d{3})$") {
        $counter = [int]$Matches[1]
        if ($counter -gt $highestCounter) {
            $highestCounter = $counter
        }
    }
}
$runId = '{0}_{1:D3}' -f $datePrefix, ($highestCounter + 1)
$reportPath = Join-Path $reportRoot "$runId.html"
$artifactPath = Join-Path $reportRoot "$runId-artifacts"

$maestroEnvironment = @(
    '-e', "APP_ID=$($config.AppId)",
    '-e', "MERCHANT_NAME=$($config.MerchantName)",
    '-e', "MERCHANT_EMAIL=$($config.MerchantEmail)",
    '-e', "MERCHANT_PASSWORD=$($config.MerchantPassword)",
    '-e', "STORE_A=$($config.SwitchStoreA)",
    '-e', "STORE_B=$($config.SwitchStoreB)",
    '-e', "INACTIVE_STORE=$($config.InactiveStore)"
)
$merchantPin = [string]$config.MerchantPin
for ($index = 0; $index -lt 4; $index++) {
    $maestroEnvironment += @('-e', "MERCHANT_PIN_$($index + 1)=$($merchantPin.Substring($index, 1))")
}
$invalidPin = [string]$config.InvalidPin
for ($index = 0; $index -lt 4; $index++) {
    $maestroEnvironment += @('-e', "INVALID_PIN_$($index + 1)=$($invalidPin.Substring($index, 1))")
}

Write-Host "[RUN ] $($selectedTests.Count) Merchant Switch Store testcase(s) on Android $DeviceType" -ForegroundColor Cyan
foreach ($testName in $selectedTests) {
    $ticket = $deviceTickets[$testName]
    Write-Host "       $($ticket.Id) - $testName"
    Write-Host "       $($ticket.Url)"
}
Write-Host "       $($config.SwitchStoreA) -> $($config.SwitchStoreB)"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& maestro --device $DeviceId test `
    --no-ansi `
    --no-reinstall-driver `
    --format HTML-DETAILED `
    --output $reportPath `
    --test-output-dir $artifactPath `
    @maestroEnvironment `
    @flowPaths
$exitCode = $LASTEXITCODE
$stopwatch.Stop()

Write-Host ''
if ($exitCode -eq 0) {
    Write-Host "[PASS] Merchant Switch Store test run completed on Android $DeviceType." -ForegroundColor Green
}
else {
    Write-Host "[FAIL] One or more Merchant Switch Store testcases failed on Android $DeviceType." -ForegroundColor Red
}
Write-Host "Total execution time: $($stopwatch.Elapsed.ToString('hh\:mm\:ss\.fff'))"
Write-Host "Report: $reportPath"
Write-Host "Artifacts: $artifactPath"

if ($OpenReport -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    Start-Process -FilePath $reportPath
}

exit $exitCode
