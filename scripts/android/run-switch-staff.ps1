[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DeviceId,

    [ValidateSet('phone', 'tablet')]
    [string]$DeviceType = 'phone',

    [ValidateSet(
        'all',
        'invalid-pin',
        'cross-staff-pin',
        'inactive-staff',
        'back-from-passcode',
        'relaunch-during-switch',
        'login-and-switch-between-active-staff'
    )]
    [string]$Test = 'all',

    [string]$ConfigPath,

    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$env:MAESTRO_CLI_NO_ANALYTICS = 'true'
$env:JAVA_TOOL_OPTIONS = "-Duser.home=$RepoRoot"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $RepoRoot 'config\stg.psd1'
}
if (-not (Get-Command maestro -ErrorAction SilentlyContinue)) {
    throw 'Maestro was not found on PATH.'
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config file not found: $ConfigPath"
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$requiredKeys = @(
    'AppId', 'StoreEmail', 'StorePassword', 'StoreOwner',
    'StaffA', 'StaffAPin', 'StaffB', 'StaffBPin',
    'InactiveStaff', 'InvalidPin', 'StaffBMarker'
)
foreach ($key in $requiredKeys) {
    if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$config[$key])) {
        throw "Missing required config value: $key"
    }
}
foreach ($pinKey in @('StaffAPin', 'StaffBPin', 'InvalidPin')) {
    if ([string]$config[$pinKey] -notmatch '^\d{4}$') {
        throw "$pinKey must contain exactly four digits."
    }
}

$testOrder = @(
    'invalid-pin',
    'cross-staff-pin',
    'inactive-staff',
    'back-from-passcode',
    'relaunch-during-switch',
    'login-and-switch-between-active-staff'
)
$selectedTests = if ($Test -eq 'all') { $testOrder } else { @($Test) }
$flowRoot = Join-Path $RepoRoot 'android\switch-staff'
$setupFlow = Join-Path $RepoRoot 'android\helpers\login-to-staff-selection.yaml'
$flowPaths = @($setupFlow)
foreach ($testName in $selectedTests) {
    $flowPath = Join-Path $flowRoot "$testName.yaml"
    if (-not (Test-Path -LiteralPath $flowPath -PathType Leaf)) {
        throw "Testcase file not found: $flowPath"
    }
    $flowPaths += $flowPath
}

$ticketPath = Join-Path $RepoRoot 'metadata\tickets.psd1'
$tickets = Import-PowerShellDataFile -LiteralPath $ticketPath
$deviceTickets = $tickets[$DeviceType]
$reportRoot = Join-Path $RepoRoot 'reports'
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
    '-e', "STORE_EMAIL=$($config.StoreEmail)",
    '-e', "STORE_PASSWORD=$($config.StorePassword)",
    '-e', "STORE_OWNER=$($config.StoreOwner)",
    '-e', "STAFF_A=$($config.StaffA)",
    '-e', "STAFF_B=$($config.StaffB)",
    '-e', "INACTIVE_STAFF=$($config.InactiveStaff)",
    '-e', "STAFF_B_MARKER=$($config.StaffBMarker)"
)

foreach ($pinName in @('StaffAPin', 'StaffBPin', 'InvalidPin')) {
    $prefix = switch ($pinName) {
        'StaffAPin' { 'STAFF_A_PIN' }
        'StaffBPin' { 'STAFF_B_PIN' }
        'InvalidPin' { 'INVALID_PIN' }
    }
    $pin = [string]$config[$pinName]
    for ($index = 0; $index -lt 4; $index++) {
        $maestroEnvironment += @('-e', "${prefix}_$($index + 1)=$($pin.Substring($index, 1))")
    }
}

Write-Host "[RUN ] $($selectedTests.Count) Switch Staff testcase(s) on Android $DeviceType after one login" -ForegroundColor Cyan
foreach ($testName in $selectedTests) {
    $ticket = $deviceTickets[$testName]
    Write-Host "       $($ticket.Id) - $testName"
    Write-Host "       $($ticket.Url)"
}

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
    Write-Host "[PASS] Switch Staff test run completed on Android $DeviceType." -ForegroundColor Green
}
else {
    Write-Host "[FAIL] One or more Switch Staff testcases failed on Android $DeviceType." -ForegroundColor Red
}
Write-Host "Total execution time: $($stopwatch.Elapsed.ToString('hh\:mm\:ss\.fff'))"
Write-Host "Report: $reportPath"
Write-Host "Artifacts: $artifactPath"

if ($OpenReport -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    Start-Process -FilePath $reportPath
}

exit $exitCode
