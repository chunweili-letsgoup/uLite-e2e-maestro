#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

usage() {
  echo "Usage: $0 --device <SIMULATOR_UDID> --test <name> [--platform <iphone|ipad>] [--config <path>]" >&2
  exit 2
}

device_id=""
test_name=""
config_path="config/stg.psd1"
platform="iphone"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device_id="${2:-}"; shift 2 ;;
    --test) test_name="${2:-}"; shift 2 ;;
    --platform) platform="${2:-}"; shift 2 ;;
    --config) config_path="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$device_id" && -n "$test_name" ]] || usage
[[ "$platform" == "iphone" || "$platform" == "ipad" ]] || usage

case "$test_name" in
  happy-path|switch-store-after-login-requires-merchant-pin|store-staff-cannot-access-switch-store) ;;
  *)
    echo "Unknown test: $test_name" >&2
    usage
    ;;
esac

if command -v maestro >/dev/null 2>&1; then
  maestro_bin="$(command -v maestro)"
elif [[ -x /opt/homebrew/bin/maestro ]]; then
  maestro_bin="/opt/homebrew/bin/maestro"
else
  echo "Maestro was not found on PATH." >&2
  exit 1
fi
[[ -f "$config_path" ]] || {
  echo "Config file not found: $config_path" >&2
  exit 1
}

config_value() {
  awk -F"'" -v key="$1" '$1 ~ "^[[:space:]]*" key "[[:space:]]*=" { print $2; exit }' "$config_path"
}

required_keys=(
  IosAppId MerchantName MerchantEmail MerchantPassword MerchantPin InvalidPin
  SwitchStoreA SwitchStoreB InactiveStore StoreEmail StorePassword StaffA StaffAPin
)
for key in "${required_keys[@]}"; do
  [[ -n "$(config_value "$key")" ]] || {
    echo "Missing required config value: $key" >&2
    exit 1
  }
done

app_id="$(config_value IosAppId)"
merchant_pin="$(config_value MerchantPin)"
invalid_pin="$(config_value InvalidPin)"
staff_a_pin="$(config_value StaffAPin)"

for pin_name in merchant_pin invalid_pin staff_a_pin; do
  pin_value="${!pin_name}"
  [[ "$pin_value" =~ ^[0-9]{4}$ ]] || {
    echo "$pin_name must contain exactly four digits." >&2
    exit 1
  }
done

xcrun simctl list devices booted | grep -Fq "$device_id" || {
  echo "Simulator is not booted: $device_id" >&2
  exit 1
}
xcrun simctl get_app_container "$device_id" "$app_id" app >/dev/null 2>&1 || {
  echo "uLite is not installed on Simulator $device_id ($app_id)." >&2
  exit 1
}

if [[ "$platform" == "ipad" ]]; then
  flow_path="ios/ipad/switch-store/$test_name.yaml"
else
  flow_path="ios/switch-store/$test_name.yaml"
fi
report_dir="reports/ios"
mkdir -p "$report_dir"
run_id="$(date '+%Y%m%d_%H%M%S')-$platform-switch-store-$test_name"

env_args=(
  -e "APP_ID=$app_id"
  -e "MERCHANT_NAME=$(config_value MerchantName)"
  -e "MERCHANT_EMAIL=$(config_value MerchantEmail)"
  -e "MERCHANT_PASSWORD=$(config_value MerchantPassword)"
  -e "STORE_A=$(config_value SwitchStoreA)"
  -e "STORE_B=$(config_value SwitchStoreB)"
  -e "INACTIVE_STORE=$(config_value InactiveStore)"
  -e "STORE_EMAIL=$(config_value StoreEmail)"
  -e "STORE_PASSWORD=$(config_value StorePassword)"
  -e "STAFF_A=$(config_value StaffA)"
)

for index in 0 1 2 3; do
  digit=$((index + 1))
  env_args+=(
    -e "MERCHANT_PIN_${digit}=${merchant_pin:index:1}"
    -e "INVALID_PIN_${digit}=${invalid_pin:index:1}"
    -e "STAFF_A_PIN_${digit}=${staff_a_pin:index:1}"
  )
done

"$maestro_bin" --device "$device_id" test \
  --no-ansi \
  --format HTML-DETAILED \
  --output "$report_dir/$run_id.html" \
  --test-output-dir "$report_dir/$run_id-artifacts" \
  "${env_args[@]}" \
  "$flow_path"

echo "Report: $report_dir/$run_id.html"
echo "Artifacts: $report_dir/$run_id-artifacts"
