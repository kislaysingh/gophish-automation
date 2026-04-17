#!/usr/bin/env bash
set -Eeuo pipefail

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[!] Missing required command: $1" >&2
    exit 1
  }
}

prompt_nonempty() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -r -p "$prompt_text" value
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -r -s -p "$prompt_text" value
    echo
  done
  printf -v "$var_name" '%s' "$value"
}

split_domain() {
  local domain="$1"
  SLD="${domain%.*}"
  TLD="${domain##*.}"
  if [[ -z "$SLD" || -z "$TLD" || "$SLD" == "$domain" ]]; then
    echo "[!] Could not split domain into SLD/TLD: $domain" >&2
    exit 1
  fi
}

urlencode() {
  python3 - <<'PY' "$1"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

namecheap_api() {
  local command="$1"
  shift
  local url="https://api.namecheap.com/xml.response"
  local args=(
    "ApiUser=$NC_API_USER"
    "ApiKey=$NC_API_KEY"
    "UserName=$NC_USERNAME"
    "ClientIp=$NC_CLIENT_IP"
    "Command=$command"
    "SLD=$SLD"
    "TLD=$TLD"
  )
  while (($#)); do
    args+=("$1")
    shift
  done

  local query=""
  local kv key val enc_key enc_val
  for kv in "${args[@]}"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    enc_key="$(urlencode "$key")"
    enc_val="$(urlencode "$val")"
    if [[ -n "$query" ]]; then
      query+="&"
    fi
    query+="${enc_key}=${enc_val}"
  done

  curl -fsS "$url?$query"
}

xml_error_check() {
  local xml="$1"
  if grep -q 'Status="ERROR"' <<<"$xml"; then
    echo "[!] Namecheap API returned an error:" >&2
    echo "$xml" | sed -n '1,120p' >&2
    exit 1
  fi
}

extract_hosts_to_file() {
  local xml="$1"
  local outfile="$2"
  python3 - <<'PY' "$outfile" <<EOF
$xml
EOF
import sys, xml.etree.ElementTree as ET
outfile = sys.argv[1]
xml_data = sys.stdin.read()
root = ET.fromstring(xml_data)
hosts = []
for host in root.findall('.//{*}Host'):
    hosts.append({
        'Name': host.attrib.get('Name', ''),
        'Type': host.attrib.get('Type', ''),
        'Address': host.attrib.get('Address', ''),
        'MXPref': host.attrib.get('MXPref', '10'),
        'TTL': host.attrib.get('TTL', '1800'),
    })
with open(outfile, 'w', encoding='utf-8') as f:
    for h in hosts:
        f.write('\t'.join([h['Name'], h['Type'], h['Address'], h['MXPref'], h['TTL']]) + '\n')
PY
}

build_sethosts_args() {
  local hosts_file="$1"
  local out_file="$2"
  local idx=1
  : > "$out_file"
  while IFS=$'\t' read -r name type address mxpref ttl; do
    [[ -z "$name" && -z "$type" ]] && continue
    printf 'HostName%d=%s\n' "$idx" "$name" >> "$out_file"
    printf 'RecordType%d=%s\n' "$idx" "$type" >> "$out_file"
    printf 'Address%d=%s\n' "$idx" "$address" >> "$out_file"
    printf 'MXPref%d=%s\n' "$idx" "$mxpref" >> "$out_file"
    printf 'TTL%d=%s\n' "$idx" "$ttl" >> "$out_file"
    idx=$((idx+1))
  done < "$hosts_file"
}

upsert_record() {
  local hosts_file="$1"
  local record_name="$2"
  local record_type="$3"
  local record_value="$4"
  local record_ttl="$5"
  local tmp_hosts
  tmp_hosts="$(mktemp)"

  awk -F '\t' -v n="$record_name" -v t="$record_type" '!(tolower($1)==tolower(n) && toupper($2)==toupper(t))' "$hosts_file" > "$tmp_hosts"
  printf '%s\t%s\t%s\t10\t%s\n' "$record_name" "$record_type" "$record_value" "$record_ttl" >> "$tmp_hosts"
  mv "$tmp_hosts" "$hosts_file"
}

ensure_namecheap_default_dns() {
  echo "[+] Ensuring the domain uses Namecheap BasicDNS..."
  local resp
  resp="$(namecheap_api 'namecheap.domains.dns.setDefault')"
  xml_error_check "$resp"
}

get_existing_hosts() {
  local outfile="$1"
  echo "[+] Fetching current Namecheap host records..."
  local resp
  resp="$(namecheap_api 'namecheap.domains.dns.getHosts')"
  xml_error_check "$resp"
  extract_hosts_to_file "$resp" "$outfile"
}

set_all_hosts() {
  local kv_file="$1"
  mapfile -t kv_lines < "$kv_file"
  echo "[+] Updating Namecheap DNS host records..."
  local resp
  resp="$(namecheap_api 'namecheap.domains.dns.setHosts' "${kv_lines[@]}")"
  xml_error_check "$resp"
}

create_auth_hook() {
  local hook_path="$1"
  cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${NC_API_USER:?Missing NC_API_USER}"
: "${NC_API_KEY:?Missing NC_API_KEY}"
: "${NC_USERNAME:?Missing NC_USERNAME}"
: "${NC_CLIENT_IP:?Missing NC_CLIENT_IP}"
: "${NC_DOMAIN:?Missing NC_DOMAIN}"
: "${NC_RECORD_TTL:=60}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[hook] missing command: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd python3
need_cmd awk
need_cmd sed

SLD="${NC_DOMAIN%.*}"
TLD="${NC_DOMAIN##*.}"
if [[ -z "$SLD" || -z "$TLD" || "$SLD" == "$NC_DOMAIN" ]]; then
  echo "[hook] invalid NC_DOMAIN: $NC_DOMAIN" >&2
  exit 1
fi

urlencode() {
  python3 - <<'PY' "$1"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

namecheap_api() {
  local command="$1"
  shift
  local args=(
    "ApiUser=$NC_API_USER"
    "ApiKey=$NC_API_KEY"
    "UserName=$NC_USERNAME"
    "ClientIp=$NC_CLIENT_IP"
    "Command=$command"
    "SLD=$SLD"
    "TLD=$TLD"
  )
  while (($#)); do
    args+=("$1")
    shift
  done
  local query=""
  local kv key val
  for kv in "${args[@]}"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    [[ -n "$query" ]] && query+="&"
    query+="$(urlencode "$key")=$(urlencode "$val")"
  done
  curl -fsS "https://api.namecheap.com/xml.response?$query"
}

xml_error_check() {
  local xml="$1"
  if grep -q 'Status="ERROR"' <<<"$xml"; then
    echo "[hook] Namecheap API error:" >&2
    echo "$xml" | sed -n '1,120p' >&2
    exit 1
  fi
}

extract_hosts() {
  python3 - <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
for host in root.findall('.//{*}Host'):
    print('\t'.join([
        host.attrib.get('Name',''),
        host.attrib.get('Type',''),
        host.attrib.get('Address',''),
        host.attrib.get('MXPref','10'),
        host.attrib.get('TTL','1800'),
    ]))
PY
}

build_args() {
  local infile="$1"
  local idx=1
  while IFS=$'\t' read -r name type address mxpref ttl; do
    [[ -z "$name" && -z "$type" ]] && continue
    printf 'HostName%d=%s\n' "$idx" "$name"
    printf 'RecordType%d=%s\n' "$idx" "$type"
    printf 'Address%d=%s\n' "$idx" "$address"
    printf 'MXPref%d=%s\n' "$idx" "$mxpref"
    printf 'TTL%d=%s\n' "$idx" "$ttl"
    idx=$((idx+1))
  done < "$infile"
}

resp="$(namecheap_api 'namecheap.domains.dns.getHosts')"
xml_error_check "$resp"
work_hosts="$(mktemp)"
extract_hosts <<<"$resp" > "$work_hosts"

record_name="_acme-challenge"
awk -F '\t' -v n="$record_name" -v t="TXT" '!(tolower($1)==tolower(n) && toupper($2)==toupper(t))' "$work_hosts" > "${work_hosts}.next"
printf '%s\tTXT\t%s\t10\t%s\n' "$record_name" "$CERTBOT_VALIDATION" "$NC_RECORD_TTL" >> "${work_hosts}.next"
mv "${work_hosts}.next" "$work_hosts"

args_file="$(mktemp)"
build_args "$work_hosts" > "$args_file"
mapfile -t kv_lines < "$args_file"
resp="$(namecheap_api 'namecheap.domains.dns.setHosts' "${kv_lines[@]}")"
xml_error_check "$resp"

echo "[hook] Created/updated TXT record _acme-challenge for $CERTBOT_DOMAIN"
sleep "${NC_PROPAGATION_SECONDS:-60}"
HOOK
  chmod +x "$hook_path"
}

create_cleanup_hook() {
  local hook_path="$1"
  cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${NC_API_USER:?Missing NC_API_USER}"
: "${NC_API_KEY:?Missing NC_API_KEY}"
: "${NC_USERNAME:?Missing NC_USERNAME}"
: "${NC_CLIENT_IP:?Missing NC_CLIENT_IP}"
: "${NC_DOMAIN:?Missing NC_DOMAIN}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[cleanup] missing command: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd python3
need_cmd awk
need_cmd sed

SLD="${NC_DOMAIN%.*}"
TLD="${NC_DOMAIN##*.}"
if [[ -z "$SLD" || -z "$TLD" || "$SLD" == "$NC_DOMAIN" ]]; then
  echo "[cleanup] invalid NC_DOMAIN: $NC_DOMAIN" >&2
  exit 1
fi

urlencode() {
  python3 - <<'PY' "$1"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

namecheap_api() {
  local command="$1"
  shift
  local args=(
    "ApiUser=$NC_API_USER"
    "ApiKey=$NC_API_KEY"
    "UserName=$NC_USERNAME"
    "ClientIp=$NC_CLIENT_IP"
    "Command=$command"
    "SLD=$SLD"
    "TLD=$TLD"
  )
  while (($#)); do
    args+=("$1")
    shift
  done
  local query=""
  local kv key val
  for kv in "${args[@]}"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    [[ -n "$query" ]] && query+="&"
    query+="$(urlencode "$key")=$(urlencode "$val")"
  done
  curl -fsS "https://api.namecheap.com/xml.response?$query"
}

xml_error_check() {
  local xml="$1"
  if grep -q 'Status="ERROR"' <<<"$xml"; then
    echo "[cleanup] Namecheap API error:" >&2
    echo "$xml" | sed -n '1,120p' >&2
    exit 1
  fi
}

extract_hosts() {
  python3 - <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
for host in root.findall('.//{*}Host'):
    print('\t'.join([
        host.attrib.get('Name',''),
        host.attrib.get('Type',''),
        host.attrib.get('Address',''),
        host.attrib.get('MXPref','10'),
        host.attrib.get('TTL','1800'),
    ]))
PY
}

build_args() {
  local infile="$1"
  local idx=1
  while IFS=$'\t' read -r name type address mxpref ttl; do
    [[ -z "$name" && -z "$type" ]] && continue
    printf 'HostName%d=%s\n' "$idx" "$name"
    printf 'RecordType%d=%s\n' "$idx" "$type"
    printf 'Address%d=%s\n' "$idx" "$address"
    printf 'MXPref%d=%s\n' "$idx" "$mxpref"
    printf 'TTL%d=%s\n' "$idx" "$ttl"
    idx=$((idx+1))
  done < "$infile"
}

resp="$(namecheap_api 'namecheap.domains.dns.getHosts')"
xml_error_check "$resp"
work_hosts="$(mktemp)"
extract_hosts <<<"$resp" > "$work_hosts"
awk -F '\t' -v n="_acme-challenge" -v t="TXT" '!(tolower($1)==tolower(n) && toupper($2)==toupper(t))' "$work_hosts" > "${work_hosts}.next"
mv "${work_hosts}.next" "$work_hosts"
args_file="$(mktemp)"
build_args "$work_hosts" > "$args_file"
if [[ -s "$args_file" ]]; then
  mapfile -t kv_lines < "$args_file"
  resp="$(namecheap_api 'namecheap.domains.dns.setHosts' "${kv_lines[@]}")"
  xml_error_check "$resp"
fi

echo "[cleanup] Removed TXT record _acme-challenge for $CERTBOT_DOMAIN"
HOOK
  chmod +x "$hook_path"
}

main() {
  echo "=== Gophish + Namecheap API + Certbot DNS automation ==="
  echo
  echo "This script will:"
  echo "  1) Ask for all required information"
  echo "  2) Create an install directory for Gophish"
  echo "  3) Download and extract a Gophish release"
  echo "  4) Change config.json admin_server.listen_url to 0.0.0.0:3333"
  echo "  5) Ensure Namecheap BasicDNS is enabled"
  echo "  6) Create/update the @ A record automatically using Namecheap API"
  echo "  7) Use Certbot manual DNS hooks to create/remove _acme-challenge TXT records automatically"
  echo

  need_cmd curl
  need_cmd unzip
  need_cmd certbot
  need_cmd python3
  need_cmd awk
  need_cmd sed
  need_cmd grep

  local domain install_base version install_dir archive url public_ip ttl prop_seconds
  local hosts_file kv_file auth_hook cleanup_hook cert_path key_path

  prompt_nonempty domain "Enter the domain to configure (example: kislay.online): "
  prompt_nonempty install_base "Enter the base directory to install Gophish (example: /opt or /home/ubuntu/tools): "
  prompt_nonempty version "Enter the Gophish release version tag (example: v0.12.1): "
  prompt_nonempty NC_API_USER "Enter Namecheap API user: "
  prompt_nonempty NC_USERNAME "Enter Namecheap account username: "
  prompt_secret NC_API_KEY "Enter Namecheap API key: "
  prompt_nonempty NC_CLIENT_IP "Enter whitelisted client IP for Namecheap API: "
  prompt_nonempty public_ip "Enter the public IPv4 address for the A record (@): "
  prompt_nonempty ttl "Enter DNS TTL in seconds (example: 60 or 1800): "
  prompt_nonempty prop_seconds "Enter DNS propagation wait time in seconds for Certbot (example: 60): "

  split_domain "$domain"

  export NC_API_USER NC_USERNAME NC_API_KEY NC_CLIENT_IP
  export NC_DOMAIN="$domain"
  export NC_RECORD_TTL="$ttl"
  export NC_PROPAGATION_SECONDS="$prop_seconds"

  install_dir="${install_base%/}/gophish"
  archive="gophish-${version}-linux-64bit.zip"
  url="https://github.com/gophish/gophish/releases/download/${version}/${archive}"

  echo
  echo "[+] Target domain      : $domain"
  echo "[+] Gophish directory  : $install_dir"
  echo "[+] Gophish download   : $url"
  echo "[+] DNS TTL            : $ttl"
  echo "[+] Propagation wait   : $prop_seconds seconds"
  echo

  mkdir -p "$install_dir"
  cd "$install_dir"

  echo "[+] Downloading Gophish release..."
  curl -fL --retry 3 -o "$archive" "$url"

  echo "[+] Extracting Gophish..."
  unzip -o "$archive"

  if [[ ! -f config.json ]]; then
    echo "[!] config.json not found after extraction. Check the selected version." >&2
    exit 1
  fi

  echo "[+] Updating config.json admin_server.listen_url ..."
  python3 - <<'PY'
import json
from pathlib import Path
p = Path('config.json')
data = json.loads(p.read_text())
if 'admin_server' not in data:
    raise SystemExit('admin_server key not found in config.json')
data['admin_server']['listen_url'] = '0.0.0.0:3333'
p.write_text(json.dumps(data, indent=2) + '\n')
PY

  ensure_namecheap_default_dns

  hosts_file="$(mktemp)"
  kv_file="$(mktemp)"
  get_existing_hosts "$hosts_file"
  upsert_record "$hosts_file" "@" "A" "$public_ip" "$ttl"
  build_sethosts_args "$hosts_file" "$kv_file"
  set_all_hosts "$kv_file"

  auth_hook="$install_dir/namecheap-certbot-auth.sh"
  cleanup_hook="$install_dir/namecheap-certbot-cleanup.sh"
  create_auth_hook "$auth_hook"
  create_cleanup_hook "$cleanup_hook"

  echo "[+] Starting Certbot with automatic Namecheap DNS hook..."
  sudo --preserve-env=NC_API_USER,NC_USERNAME,NC_API_KEY,NC_CLIENT_IP,NC_DOMAIN,NC_RECORD_TTL,NC_PROPAGATION_SECONDS \
    certbot certonly \
    --manual \
    --preferred-challenges dns \
    --manual-public-ip-logging-ok \
    --manual-auth-hook "$auth_hook" \
    --manual-cleanup-hook "$cleanup_hook" \
    --register-unsafely-without-email \
    -d "$domain"

  cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
  key_path="/etc/letsencrypt/live/$domain/privkey.pem"

  echo
  echo "[+] Completed successfully."
  echo "[+] Gophish installed in: $install_dir"
  echo "[+] Gophish config updated: $install_dir/config.json"
  echo "[+] Namecheap A record @ -> $public_ip has been applied"
  echo "[+] Certificate path: $cert_path"
  echo "[+] Private key path: $key_path"
  echo
  echo "[i] Next steps:"
  echo "    - Configure Gophish to use the generated certificate if needed"
  echo "    - Review and harden config.json before exposing the service"
  echo "    - Start Gophish from: $install_dir"
}

main "$@"
