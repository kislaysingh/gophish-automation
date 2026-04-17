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

prompt_yes_no() {
  local prompt_text="$1"
  local answer
  while true; do
    read -r -p "$prompt_text [y/n]: " answer
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

main() {
  echo "=== Gophish setup helper ==="
  echo
  echo "This script will:"
  echo "  1) Create a directory for Gophish"
  echo "  2) Download and extract Gophish"
  echo "  3) Update config.json admin listen_url to 0.0.0.0:3333"
  echo "  4) Run Certbot manual DNS flow"
  echo "  5) Pause so you can create the required Namecheap TXT record"
  echo "  6) Remind you to create the Namecheap A record"
  echo

  need_cmd curl
  need_cmd tar
  need_cmd sed
  need_cmd awk
  need_cmd grep
  need_cmd certbot
  need_cmd python3
  need_cmd unzip

  local domain install_base version archive url install_dir certbot_log public_ip

  prompt_nonempty domain "Enter the domain for TLS (example: kislay.online): "
  prompt_nonempty install_base "Enter the base directory to install Gophish (example: /opt or /home/ubuntu/tools): "
  prompt_nonempty version "Enter the Gophish release version tag (example: v0.12.1): "

  install_dir="${install_base%/}/gophish"
  archive="gophish-${version}-linux-64bit.zip"
  url="https://github.com/gophish/gophish/releases/download/${version}/${archive}"
  certbot_log="/tmp/certbot-${domain//[^a-zA-Z0-9.-]/_}-$(date +%s).log"

  echo
  echo "[+] Installation directory: $install_dir"
  echo "[+] Download URL: $url"
  echo

  mkdir -p "$install_dir"
  cd "$install_dir"

  echo "[+] Downloading Gophish..."
  curl -fL --retry 3 -o "$archive" "$url"

  echo "[+] Extracting Gophish..."
  unzip -o "$archive"

  if [[ ! -f config.json ]]; then
    echo "[!] config.json not found after extraction. Check the release archive/version." >&2
    exit 1
  fi

  echo "[+] Updating config.json admin listen_url to 0.0.0.0:3333 ..."
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

  echo "[+] Updated config.json successfully."
  echo
  echo "[+] Starting manual DNS certificate request for $domain"
  echo "    Certbot output will also be saved to: $certbot_log"
  echo
  echo "    IMPORTANT: When Certbot shows the TXT value, create this Namecheap TXT record:"
  echo "      Host: _acme-challenge"
  echo "      Value: <the exact value shown by certbot>"
  echo

  set +e
  sudo certbot certonly \\
    --manual \\
    --preferred-challenges dns \\
    --register-unsafely-without-email \\
    -d "$domain" 2>&1 | tee "$certbot_log"
  certbot_rc=${PIPESTATUS[0]}
  set -e

  echo
  echo "[+] Namecheap DNS guidance"
  echo "    1) TXT record"
  echo "       Host : _acme-challenge"
  echo "       Value: use the token Certbot displayed"
  echo

  public_ip="$(curl -fsS https://api.ipify.org || true)"
  if [[ -n "$public_ip" ]]; then
    echo "    2) A record"
    echo "       Host : @"
    echo "       Value: $public_ip"
  else
    echo "    2) A record"
    echo "       Host : @"
    echo "       Value: <your server public IP>"
  fi
  echo

  if [[ $certbot_rc -ne 0 ]]; then
    echo "[!] Certbot did not complete successfully. Review: $certbot_log" >&2
    echo "    After fixing DNS propagation or command issues, rerun only the certbot step manually."
    exit $certbot_rc
  fi

  echo "[+] Certificate request completed."
  echo "[+] Gophish extracted in: $install_dir"
  echo "[+] Config updated: $install_dir/config.json"
  echo
  echo "[i] Next steps:"
  echo "    - Verify A record for $domain points to your server"
  echo "    - Review Gophish config.json before starting"
  echo "    - Start Gophish from: $install_dir"
}

main "$@"
