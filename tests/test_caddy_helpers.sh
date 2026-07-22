#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OMBRE_INSTALLER_LIBRARY=1 source "$ROOT_DIR/install.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_normalizes() {
  local input=$1 expected=$2 actual
  actual="$(normalize_public_domain "$input")" \
    || fail "expected valid public domain: $input"
  [[ "$actual" == "$expected" ]] \
    || fail "$input normalized to $actual, expected $expected"
}

assert_rejected() {
  local input=$1
  if normalize_public_domain "$input" >/dev/null 2>&1; then
    fail "expected invalid public domain: $input"
  fi
}

assert_contains() {
  local value=$1 expected=$2
  [[ "$value" == *"$expected"* ]] || fail "rendered output is missing: $expected"
}

assert_cloudflare_proxy() {
  local address=$1
  is_cloudflare_proxy_ipv4 "$address" || fail "expected Cloudflare proxy IPv4: $address"
}

assert_not_cloudflare_proxy() {
  local address=$1
  if is_cloudflare_proxy_ipv4 "$address"; then
    fail "unexpected Cloudflare proxy IPv4: $address"
  fi
}

run_caddy_preflight_with_addresses() (
  local resolved_addresses=$1 detected_public_ipv4=$2
  ACCESS_MODE='public_caddy'
  BIND_ADDRESS='127.0.0.1'
  DRY_RUN=0
  DOCKER=()
  caddy_asset_is_managed_or_absent() { return 0; }
  resolve_domain_ipv4s() { printf '%s\n' "$resolved_addresses"; }
  detect_public_ipv4() { printf '%s\n' "$detected_public_ipv4"; }
  set_docker_command() { return 1; }
  port_in_use() { return 1; }
  docker_published_tcp_port_in_use() { return 1; }
  info() { :; }
  warn() { :; }
  success() { :; }
  validate_caddy_preflight
)

assert_normalizes 'brain.example.com' 'brain.example.com'
assert_normalizes 'Brain.Example.COM' 'brain.example.com'
assert_normalizes 'https://brain.example.com' 'brain.example.com'
assert_normalizes 'https://brain.example.com/' 'brain.example.com'
assert_normalizes 'https://brain.example.com/mcp' 'brain.example.com'
assert_normalizes 'https://brain.example.com/mcp/' 'brain.example.com'
assert_normalizes 'xn--fsqu00a.xn--0zwm56d' 'xn--fsqu00a.xn--0zwm56d'

assert_rejected ''
assert_rejected 'localhost'
assert_rejected '127.0.0.1'
assert_rejected '999.999.999.999'
assert_rejected 'http://brain.example.com'
assert_rejected 'https://brain.example.com:8443'
assert_rejected 'https://user@brain.example.com'
assert_rejected 'https://brain.example.com/admin'
assert_rejected 'https://brain.example.com//mcp'
assert_rejected 'https://brain.example.com?x=1'
assert_rejected 'brain..example.com'
assert_rejected '-brain.example.com'
assert_rejected 'brain_example.com'
assert_rejected $'brain.example.com\nattacker.example'

assert_cloudflare_proxy '173.245.48.0'
assert_cloudflare_proxy '104.27.255.255'
assert_cloudflare_proxy '172.71.255.255'
assert_cloudflare_proxy '131.0.75.255'
assert_not_cloudflare_proxy '104.32.0.1'
assert_not_cloudflare_proxy '203.0.113.10'
assert_not_cloudflare_proxy 'not-an-ip'
all_ipv4s_are_cloudflare_proxies $'104.16.0.1\n172.64.0.1' \
  || fail 'multiple Cloudflare proxy IPv4s were rejected'
if all_ipv4s_are_cloudflare_proxies $'104.16.0.1\n203.0.113.10'; then
  fail 'mixed Cloudflare and non-Cloudflare IPv4s were accepted'
fi

asset_test_file="$(mktemp)"
TEMP_PATHS+=("$asset_test_file")
printf '# managed-by=ombrectl\n' >"$asset_test_file"
caddy_asset_is_managed_or_absent "$asset_test_file" || fail 'managed Caddy asset was rejected'
printf '# user-managed\n' >"$asset_test_file"
if caddy_asset_is_managed_or_absent "$asset_test_file"; then
  fail 'unmanaged Caddy asset was accepted'
fi
rm -f -- "$asset_test_file"
caddy_asset_is_managed_or_absent "$asset_test_file" || fail 'absent Caddy asset was rejected'

APP_DIR='/opt/ombre brain'
CONFIG_DIR='/etc/ombre brain'
PORT='18001'
PUBLIC_DOMAIN='brain.example.com'

compose_output="$(render_caddy_compose)"
assert_contains "$compose_output" '# managed-by=ombrectl'
assert_contains "$compose_output" 'image: caddy:2-alpine'
assert_contains "$compose_output" 'container_name: ombre-brain-caddy'
assert_contains "$compose_output" 'com.ombre-brain.installer-managed: "true"'
assert_contains "$compose_output" '- "80:80"'
assert_contains "$compose_output" '- "443:443"'
assert_contains "$compose_output" 'name: ombre-brain-caddy-managed-proxy'
assert_contains "$compose_output" 'source: "/etc/ombre brain/caddy/Caddyfile"'
assert_contains "$compose_output" 'target: /etc/caddy/Caddyfile'
assert_contains "$compose_output" 'caddy-data:/data'
assert_contains "$compose_output" 'caddy-config:/config'

caddyfile_output="$(render_caddyfile)"
assert_contains "$caddyfile_output" '# managed-by=ombrectl'
assert_contains "$caddyfile_output" 'brain.example.com {'
assert_contains "$caddyfile_output" 'issuer acme {'
assert_contains "$caddyfile_output" 'disable_tlsalpn_challenge'
assert_contains "$caddyfile_output" 'reverse_proxy ombre-brain:8000 {'
assert_contains "$caddyfile_output" 'flush_interval -1'

if ! run_caddy_preflight_with_addresses $'104.16.0.1\n172.64.0.1' '198.51.100.10'; then
  fail 'Cloudflare proxy addresses did not pass Caddy preflight'
fi

run_caddy_preflight_with_addresses '198.51.100.10' '198.51.100.10' \
  || fail 'direct origin IPv4 did not pass Caddy preflight'

if run_caddy_preflight_with_addresses '203.0.113.10' '198.51.100.10' >/dev/null 2>&1; then
  fail 'unrelated mismatched IPv4 passed Caddy preflight'
fi

app_override_output="$(render_caddy_app_override)"
assert_contains "$app_override_output" '# managed-by=ombrectl'
assert_contains "$app_override_output" 'ombre-brain:'
assert_contains "$app_override_output" '- default'
assert_contains "$app_override_output" '- caddy-proxy'
assert_contains "$app_override_output" 'name: ombre-brain-caddy-managed-proxy'

MOCK_ACCESS_CHOICE=3
menu_choice() {
  printf -v "$1" '%s' "$MOCK_ACCESS_CHOICE"
}
prompt_line() {
  printf -v "$1" '%s' 'https://Brain.Example.COM/mcp'
}
confirm() {
  return 0
}
warn() {
  :
}
PUBLIC_DOMAIN=''
collect_access_mode 1
[[ "$ACCESS_MODE" == 'public_caddy' ]] || fail 'menu choice 3 did not select public_caddy'
[[ "$BIND_ADDRESS" == '127.0.0.1' ]] || fail 'Caddy mode did not retain loopback binding'
[[ "$PUBLIC_DOMAIN" == 'brain.example.com' ]] || fail 'Caddy menu did not normalize the domain'

MOCK_ACCESS_CHOICE=4
collect_access_mode 3
[[ "$ACCESS_MODE" == 'public_secure' ]] || fail 'menu choice 4 did not retain Cloudflare mode'
[[ -z "$PUBLIC_DOMAIN" ]] || fail 'leaving Caddy mode did not clear the public domain'

printf 'PASS: Cloudflare proxy, Caddy domain, and render helpers\n'
