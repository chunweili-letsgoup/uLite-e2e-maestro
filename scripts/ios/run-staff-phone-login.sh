#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

usage() {
  echo "Usage: $0 --device <SIMULATOR_UDID> --platform <iphone|ipad> --test <name> [--config <path>]" >&2
  exit 2
}

device_id=""
platform=""
test_name=""
config_path="config/stg.psd1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device_id="${2:-}"; shift 2 ;;
    --platform) platform="${2:-}"; shift 2 ;;
    --test) test_name="${2:-}"; shift 2 ;;
    --config) config_path="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$device_id" && -n "$platform" && -n "$test_name" ]] || usage
[[ "$platform" == "iphone" || "$platform" == "ipad" ]] || usage
case "$test_name" in
  role-owner-can-login-with-phone-number|role-admin-can-login-with-phone-number|role-user-cannot-login-to-app) ;;
  *) echo "Unknown test: $test_name" >&2; usage ;;
esac

if command -v maestro >/dev/null 2>&1; then
  maestro_bin="$(command -v maestro)"
elif [[ -x /opt/homebrew/bin/maestro ]]; then
  maestro_bin="/opt/homebrew/bin/maestro"
else
  echo "Maestro was not found on PATH." >&2
  exit 1
fi

[[ -f "$config_path" ]] || { echo "Config file not found: $config_path" >&2; exit 1; }
config_value() {
  awk -F"'" -v key="$1" '$1 ~ "^[[:space:]]*" key "[[:space:]]*=" { print $2; exit }' "$config_path"
}

required_keys=(
  IosAppId StoreOwner StoreOwnerPin OwnerRolePhone OwnerRolePassword
  AdminRoleName AdminRolePhone AdminRolePassword AdminRolePin
  UserRolePhone UserRolePassword
)
for key in "${required_keys[@]}"; do
  [[ -n "$(config_value "$key")" ]] || { echo "Missing required config value: $key" >&2; exit 1; }
done

app_id="$(config_value IosAppId)"
store_owner_pin="$(config_value StoreOwnerPin)"
admin_role_pin="$(config_value AdminRolePin)"
for pin_name in store_owner_pin admin_role_pin; do
  pin_value="${!pin_name}"
  [[ "$pin_value" =~ ^[0-9]{4}$ ]] || { echo "$pin_name must contain exactly four digits." >&2; exit 1; }
done

xcrun simctl list devices booted | grep -Fq "$device_id" || { echo "Simulator is not booted: $device_id" >&2; exit 1; }
xcrun simctl get_app_container "$device_id" "$app_id" app >/dev/null 2>&1 || { echo "uLite is not installed on Simulator $device_id ($app_id)." >&2; exit 1; }

if [[ "$platform" == "ipad" ]]; then
  flow_path="ios/ipad/staff-phone-login/$test_name.yaml"
else
  flow_path="ios/staff-phone-login/$test_name.yaml"
fi
report_dir="reports/ios"
mkdir -p "$report_dir"
run_id="$(date '+%Y%m%d_%H%M%S')-$platform-staff-phone-login-$test_name"

env_args=(
  -e "APP_ID=$app_id"
  -e "STORE_OWNER=$(config_value StoreOwner)"
  -e "OWNER_ROLE_PHONE=$(config_value OwnerRolePhone)"
  -e "OWNER_ROLE_PASSWORD=$(config_value OwnerRolePassword)"
  -e "ADMIN_ROLE_NAME=$(config_value AdminRoleName)"
  -e "ADMIN_ROLE_PHONE=$(config_value AdminRolePhone)"
  -e "ADMIN_ROLE_PASSWORD=$(config_value AdminRolePassword)"
  -e "USER_ROLE_PHONE=$(config_value UserRolePhone)"
  -e "USER_ROLE_PASSWORD=$(config_value UserRolePassword)"
)

for index in 0 1 2 3; do
  digit=$((index + 1))
  env_args+=(
    -e "STORE_OWNER_PIN_${digit}=${store_owner_pin:index:1}"
    -e "ADMIN_ROLE_PIN_${digit}=${admin_role_pin:index:1}"
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
