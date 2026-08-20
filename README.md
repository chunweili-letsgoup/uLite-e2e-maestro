# uLite E2E Maestro

Local Maestro end-to-end UI automation for the uLite Android app. The Switch Staff suite runs on Android phones and tablets using the same behavior-focused flows.

## Requirements

- Windows PowerShell
- Maestro CLI on `PATH`
- Android platform tools (`adb`)
- An authorized Android device with USB debugging enabled
- uLite staging app installed

## Run all Switch Staff tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\run-tests.ps1" -DeviceId "<ADB_DEVICE_ID>" -DeviceType phone -Test all -OpenReport
```

Find the current device ID with:

```powershell
C:\platform-tools\adb.exe devices -l
```

## Run one test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\run-tests.ps1" -DeviceId "<ADB_DEVICE_ID>" -DeviceType phone -Test invalid-pin -OpenReport
```

## Run on an Android tablet

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\run-tests.ps1" -DeviceId "<TABLET_ADB_DEVICE_ID>" -DeviceType tablet -Test all -OpenReport
```

`DeviceType` labels the execution output. The same testcase files are reused because the current flows rely on shared visible text rather than phone-specific coordinates.

Available test names:

- `invalid-pin`
- `cross-staff-pin`
- `inactive-staff`
- `back-from-passcode`
- `relaunch-during-switch`
- `happy-path`
- `all`

## Reports

Reports are generated locally in `reports/` using the format `YYYYMMDD_NNN.html`. Generated reports and artifacts are not committed.

## Structure

```text
config/stg.psd1                   Staging test data
helpers/login-to-staff-selection.yaml
metadata/tickets.psd1            Linear ticket references
switch-staff/*.yaml              One YAML file per testcase
switch-store/*.yaml             Merchant Switch Store testcase flows
run-tests.ps1                    Local PowerShell runner
run-switch-store.ps1             Local Switch Store runner
run-all-tests.ps1                Run every suite in one HTML report
```

## Run every Android suite in one report

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\run-all-tests.ps1" -DeviceId "<ADB_DEVICE_ID>" -DeviceType phone -OpenReport
```

## Run the Merchant Switch Store tests

Run both Android Switch Store cases in one report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\run-switch-store.ps1" -DeviceId "<ADB_DEVICE_ID>" -DeviceType phone -OpenReport
```

Run only one case with `-Test happy-path` or `-Test account-selection-pin-gate`.
