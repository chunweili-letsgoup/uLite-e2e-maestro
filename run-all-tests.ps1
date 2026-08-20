[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DeviceId,

    [ValidateSet('phone', 'tablet')]
    [string]$DeviceType = 'phone',

    [string]$ConfigPath,

    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
$env:MAESTRO_CLI_NO_ANALYTICS = 'true'
$env:JAVA_TOOL_OPTIONS = "-Duser.home=$PSScriptRoot"

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
    'AppId', 'StoreEmail', 'StorePassword', 'StoreOwner',
    'StaffA', 'StaffAPin', 'StaffB', 'StaffBPin', 'StaffBMarker',
    'InactiveStaff', 'InvalidPin',
    'MerchantName', 'MerchantEmail', 'MerchantPassword', 'MerchantPin',
    'SwitchStoreA', 'SwitchStoreB', 'InactiveStore'
)
foreach ($key in $requiredKeys) {
    if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$config[$key])) {
        throw "Missing required config value: $key"
    }
}
foreach ($pinKey in @('StaffAPin', 'StaffBPin', 'InvalidPin', 'MerchantPin')) {
    if ([string]$config[$pinKey] -notmatch '^\d{4}$') {
        throw "$pinKey must contain exactly four digits."
    }
}

$flowPaths = @(
    (Join-Path $PSScriptRoot 'helpers\login-to-staff-selection.yaml'),
    (Join-Path $PSScriptRoot 'switch-staff\invalid-pin.yaml'),
    (Join-Path $PSScriptRoot 'switch-staff\cross-staff-pin.yaml'),
    (Join-Path $PSScriptRoot 'switch-staff\inactive-staff.yaml'),
    (Join-Path $PSScriptRoot 'switch-staff\back-from-passcode.yaml'),
    (Join-Path $PSScriptRoot 'switch-staff\relaunch-during-switch.yaml'),
    (Join-Path $PSScriptRoot 'switch-staff\happy-path.yaml'),
    (Join-Path $PSScriptRoot 'switch-store\happy-path.yaml'),
    (Join-Path $PSScriptRoot 'switch-store\account-selection-pin-gate.yaml')
)
foreach ($flowPath in $flowPaths) {
    if (-not (Test-Path -LiteralPath $flowPath -PathType Leaf)) {
        throw "Testcase file not found: $flowPath"
    }
}

$adbCommand = Get-Command adb -ErrorAction SilentlyContinue
$adbPath = if ($adbCommand) { $adbCommand.Source } else { 'C:\platform-tools\adb.exe' }

function Get-AndroidProperty {
    param([Parameter(Mandatory)][string]$PropertyName)

    if (-not (Test-Path -LiteralPath $adbPath -PathType Leaf)) {
        return 'Unknown'
    }

    try {
        $value = (& $adbPath -s $DeviceId shell getprop $PropertyName 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return 'Unknown' }
        return $value
    }
    catch {
        return 'Unknown'
    }
}

$deviceManufacturer = Get-AndroidProperty -PropertyName 'ro.product.manufacturer'
$deviceModel = Get-AndroidProperty -PropertyName 'ro.product.model'
$androidVersion = Get-AndroidProperty -PropertyName 'ro.build.version.release'
$appVersion = 'Unknown'
$appVersionCode = 'Unknown'
if (Test-Path -LiteralPath $adbPath -PathType Leaf) {
    try {
        $packageDetails = (& $adbPath -s $DeviceId shell dumpsys package $config.AppId 2>$null | Out-String)
        if ($packageDetails -match 'versionName=([^\s]+)') {
            $appVersion = $Matches[1]
        }
        if ($packageDetails -match 'versionCode=(\d+)') {
            $appVersionCode = $Matches[1]
        }
    }
    catch {
        # Report Unknown when the app is not installed or ADB cannot query it.
    }
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
    '-e', "STORE_EMAIL=$($config.StoreEmail)",
    '-e', "STORE_PASSWORD=$($config.StorePassword)",
    '-e', "STORE_OWNER=$($config.StoreOwner)",
    '-e', "STAFF_A=$($config.StaffA)",
    '-e', "STAFF_B=$($config.StaffB)",
    '-e', "INACTIVE_STAFF=$($config.InactiveStaff)",
    '-e', "STAFF_B_MARKER=$($config.StaffBMarker)",
    '-e', "MERCHANT_NAME=$($config.MerchantName)",
    '-e', "MERCHANT_EMAIL=$($config.MerchantEmail)",
    '-e', "MERCHANT_PASSWORD=$($config.MerchantPassword)",
    '-e', "STORE_A=$($config.SwitchStoreA)",
    '-e', "STORE_B=$($config.SwitchStoreB)",
    '-e', "INACTIVE_STORE=$($config.InactiveStore)"
)

$pinDefinitions = @(
    @{ Name = 'STAFF_A_PIN'; Value = [string]$config.StaffAPin },
    @{ Name = 'STAFF_B_PIN'; Value = [string]$config.StaffBPin },
    @{ Name = 'INVALID_PIN'; Value = [string]$config.InvalidPin },
    @{ Name = 'MERCHANT_PIN'; Value = [string]$config.MerchantPin }
)
foreach ($pinDefinition in $pinDefinitions) {
    for ($index = 0; $index -lt 4; $index++) {
        $maestroEnvironment += @(
            '-e',
            "$($pinDefinition.Name)_$($index + 1)=$($pinDefinition.Value.Substring($index, 1))"
        )
    }
}

Write-Host "[RUN ] All Android $DeviceType suites in one report" -ForegroundColor Cyan
Write-Host "       Device: $deviceManufacturer $deviceModel (Android $androidVersion)"
Write-Host "       ADB ID: $DeviceId"
Write-Host "       App: $($config.AppId) $appVersion (build $appVersionCode)"
Write-Host '       Switch Staff: 6 testcases plus login setup'
Write-Host '       Switch Store: 2 testcases'

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

if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    $encodedDeviceType = [System.Net.WebUtility]::HtmlEncode($DeviceType)
    $encodedManufacturer = [System.Net.WebUtility]::HtmlEncode($deviceManufacturer)
    $encodedModel = [System.Net.WebUtility]::HtmlEncode($deviceModel)
    $encodedAndroidVersion = [System.Net.WebUtility]::HtmlEncode($androidVersion)
    $encodedDeviceId = [System.Net.WebUtility]::HtmlEncode($DeviceId)
    $encodedPackageName = [System.Net.WebUtility]::HtmlEncode([string]$config.AppId)
    $encodedAppVersion = [System.Net.WebUtility]::HtmlEncode($appVersion)
    $encodedAppVersionCode = [System.Net.WebUtility]::HtmlEncode($appVersionCode)
    $deviceCard = @"
        <div id="device-under-test" class="card mb-4 border-secondary">
          <div class="card-body">
            <h3 class="card-title">Device Under Test</h3>
            <div class="row g-3">
              <div class="col-md"><strong>Type</strong><br>$encodedDeviceType</div>
              <div class="col-md"><strong>Manufacturer</strong><br>$encodedManufacturer</div>
              <div class="col-md"><strong>Model</strong><br>$encodedModel</div>
              <div class="col-md"><strong>Android</strong><br>$encodedAndroidVersion</div>
              <div class="col-md"><strong>ADB ID</strong><br>$encodedDeviceId</div>
            </div>
          </div>
        </div>
"@
    $appSummaryDetails = "<span id=`"app-summary-details`">Package: $encodedPackageName<br>Version: $encodedAppVersion<br>Build: $encodedAppVersionCode<br></span>"
    $suiteGrouping = @'
<style>
  .suite-card { border: 2px solid #0d6efd; }
  .suite-card > .card-header { background: #eaf2ff; }
  .suite-card > .card-body > .card:last-child { margin-bottom: 0 !important; }
</style>
<script data-codex-suite-grouping="true">
document.addEventListener('DOMContentLoaded', () => {
  document.title = 'uLite App Validation Report';
  const summaryHeading = Array.from(document.querySelectorAll('h1, h2, h3, h4, h5'))
    .find((heading) => ['summary', 'flow execution summary'].includes(heading.textContent.trim().toLowerCase()));
  if (summaryHeading) summaryHeading.textContent = 'uLite App Validation Report';

  const reportBody = document.querySelector('body > .card.mb-4 > .card-body');
  if (!reportBody || document.querySelector('.suite-card')) return;

  const flowCards = Array.from(reportBody.children).filter((element) =>
    element.classList.contains('card') &&
    element.classList.contains('mb-4') &&
    element.querySelector(':scope > .card-header')
  );

  const suites = [
    { name: 'Switch Staff', tag: '>staff<' },
    { name: 'Switch Store', tag: '>switch-store<' }
  ];

  for (const suite of suites) {
    const cases = flowCards.filter((card) => card.innerHTML.includes(suite.tag));
    if (!cases.length) continue;

    const suiteCard = document.createElement('section');
    suiteCard.className = 'card mb-4 suite-card';
    suiteCard.innerHTML = `
      <div class="card-header d-flex justify-content-between align-items-center">
        <h3 class="mb-0">${suite.name}</h3>
        <span class="badge bg-primary">${cases.length} testcase(s)</span>
      </div>
      <div class="card-body suite-cases"></div>`;

    reportBody.insertBefore(suiteCard, cases[0]);
    const suiteBody = suiteCard.querySelector('.suite-cases');
    cases.forEach((card) => suiteBody.appendChild(card));
  }
});
</script>
'@
    $reportHtml = [System.IO.File]::ReadAllText($reportPath)
    $reportChanged = $false
    if ($reportHtml.Contains('Flow Execution Summary')) {
        $reportHtml = $reportHtml.Replace('Flow Execution Summary', 'uLite App Validation Report')
        $reportChanged = $true
    }
    $updatedTitleHtml = [System.Text.RegularExpressions.Regex]::Replace(
        $reportHtml,
        '<title>.*?</title>',
        '<title>uLite App Validation Report</title>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($updatedTitleHtml -ne $reportHtml) {
        $reportHtml = $updatedTitleHtml
        $reportChanged = $true
    }
    if ($reportHtml -notmatch 'id="device-under-test"') {
        $summaryMarker = '        <div class="card-group mb-4">'
        if ($reportHtml.Contains($summaryMarker)) {
            $reportHtml = $reportHtml.Replace($summaryMarker, "$deviceCard`r`n$summaryMarker")
        }
        else {
            $reportHtml = $reportHtml.Replace('<body>', "<body>`r`n$deviceCard")
        }
        $reportChanged = $true
    }
    if ($reportHtml -notmatch 'id="app-summary-details"') {
        $doubleBreakPattern = [regex]::new('<br><br>')
        $reportHtml = $doubleBreakPattern.Replace($reportHtml, "<br>$appSummaryDetails<br>", 1)
        $reportChanged = $true
    }
    if ($reportHtml -notmatch 'data-codex-suite-grouping') {
        $reportHtml = $reportHtml.Replace('</body>', "$suiteGrouping`r`n</body>")
        $reportChanged = $true
    }
    if ($reportChanged) {
        [System.IO.File]::WriteAllText(
            $reportPath,
            $reportHtml,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

Write-Host ''
if ($exitCode -eq 0) {
    Write-Host "[PASS] All Android $DeviceType suites completed." -ForegroundColor Green
}
else {
    Write-Host "[FAIL] One or more Android $DeviceType testcases failed." -ForegroundColor Red
}
Write-Host "Total execution time: $($stopwatch.Elapsed.ToString('hh\:mm\:ss\.fff'))"
Write-Host "Report: $reportPath"
Write-Host "Artifacts: $artifactPath"

if ($OpenReport -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    Start-Process -FilePath $reportPath
}

exit $exitCode
