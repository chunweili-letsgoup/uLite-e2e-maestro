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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\android\run-switch-staff.ps1" -DeviceId "<ADB_DEVICE_ID>" -DeviceType phone -Test all -OpenReport
```

Find the current device ID with:

```powershell
C:\platform-tools\adb.exe devices -l
```

## Run one test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\android\run-switch-staff.ps1" -DeviceId "<ADB_DEVICE_ID>" -DeviceType phone -Test invalid-pin -OpenReport
```

## Run on an Android tablet

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\android\run-switch-staff.ps1" -DeviceId "<TABLET_ADB_DEVICE_ID>" -DeviceType tablet -Test all -OpenReport
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
android/helpers/login-to-staff-selection.yaml
metadata/tickets.psd1            Linear ticket references
android/switch-staff/*.yaml      Android Switch Staff testcase flows
android/switch-store/*.yaml      Android Merchant Switch Store flows
ios/switch-store/*.yaml          iPhone Merchant Switch Store flows
scripts/android/run-switch-staff.ps1
scripts/android/run-switch-store.ps1
scripts/android/run-all.ps1      Run every Android suite in one HTML report
scripts/ios/run-switch-store.sh  Local iPhone Switch Store runner
```

## Run every Android suite in one report

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\android\run-all.ps1" -DeviceId "<ADB_DEVICE_ID>" -DeviceType phone -OpenReport
```

## Run the Merchant Switch Store tests

Run all three Android Switch Store cases in one report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\android\run-switch-store.ps1" -DeviceId "<ADB_DEVICE_ID>" -DeviceType phone -OpenReport
```

Run one case with `-Test happy-path`, `-Test switch-store-after-login-requires-merchant-pin`, or `-Test store-staff-cannot-access-switch-store`.

## Run Merchant Switch Store tests on iPhone Simulator

Install the staging Simulator `.app`, boot the target iPhone Simulator, and find its UDID:

```bash
xcrun simctl list devices booted
```

Run one independent iPhone case:

```bash
./scripts/ios/run-switch-store.sh --device "<SIMULATOR_UDID>" --test happy-path
```

Available iPhone cases:

- `happy-path`
- `switch-store-after-login-requires-merchant-pin`
- `store-staff-cannot-access-switch-store`

These match QA-2959, QA-2967, and the role-authorization coverage in QA-2941 under PRO-51.

The iOS runner intentionally executes one case at a time. uLite stores authentication in Keychain, which Maestro `clearState` and app reinstallation do not clear. Independent repeat runs currently require a clean Simulator fixture until the staging app exposes a safe E2E reset mechanism.
