#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

CYBERCHEF_DIR="${ROOT_DIR}/CyberChef"
PROXY_DIR="${ROOT_DIR}/shared/reverse-proxy"
CYBERCHEF_CERT_DIR="${CYBERCHEF_DIR}/certs"
PROXY_CONF_TEMPLATE="${PROXY_DIR}/conf.d/cyberchef.conf.template"
PROXY_CONF_RENDERED="${PROXY_DIR}/conf.d/cyberchef.conf"

log() {
  echo "[+] $*"
}

warn() {
  echo "[!] $*" >&2
}

fail() {
  echo "[-] $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || fail ".env file not found at ${ENV_FILE}"

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  [[ -n "${DOMAIN:-}" ]] || fail "DOMAIN is not set in .env"
  [[ -n "${TZ:-}" ]] || fail "TZ is not set in .env"
  [[ -n "${CERT_MODE:-}" ]] || fail "CERT_MODE is not set in .env"
}

prompt_path() {
  local prompt_text="$1"
  local outvar="$2"
  local input
  read -r -p "$prompt_text: " input
  printf -v "$outvar" "%s" "$input"
}

ensure_dirs() {
  mkdir -p "$CYBERCHEF_CERT_DIR"
  mkdir -p "${PROXY_DIR}/conf.d"
}

create_networks() {
  log "Creating Docker network"
  docker network inspect soc_shared >/dev/null 2>&1 || docker network create soc_shared >/dev/null
}

copy_file_checked() {
  local src="$1"
  local dst="$2"

  [[ -f "$src" ]] || fail "File not found: $src"
  cp "$src" "$dst"
}

generate_self_signed_cert() {
  local fqdn="$1"
  local cert_dir="$2"

  log "Generating self-signed certificate for ${fqdn}"
  openssl req -x509 -nodes -newkey rsa:4096 \
    -keyout "${cert_dir}/tls.key" \
    -out "${cert_dir}/tls.crt" \
    -days 825 \
    -subj "/CN=${fqdn}" \
    -addext "subjectAltName=DNS:${fqdn}" >/dev/null 2>&1

  chmod 600 "${cert_dir}/tls.key"
  chmod 644 "${cert_dir}/tls.crt"
}

handle_certificates() {
  local cyberchef_fqdn="cyberchef.${DOMAIN}"

  case "${CERT_MODE}" in
    selfsigned)
      generate_self_signed_cert "$cyberchef_fqdn" "$CYBERCHEF_CERT_DIR"
      ;;
    provided)
      log "Using provided certificate files for ${cyberchef_fqdn}"

      local cert_src key_src
      prompt_path "Path to CyberChef certificate file" cert_src
      prompt_path "Path to CyberChef private key file" key_src

      copy_file_checked "$cert_src" "${CYBERCHEF_CERT_DIR}/tls.crt"
      copy_file_checked "$key_src" "${CYBERCHEF_CERT_DIR}/tls.key"

      chmod 600 "${CYBERCHEF_CERT_DIR}/tls.key"
      chmod 644 "${CYBERCHEF_CERT_DIR}/tls.crt"
      ;;
    *)
      fail "CERT_MODE must be either 'selfsigned' or 'provided'"
      ;;
  esac
}

require_envsubst() {
  require_cmd envsubst
}

render_proxy_config() {
  [[ -f "$PROXY_CONF_TEMPLATE" ]] || fail "Template not found: ${PROXY_CONF_TEMPLATE}"

  log "Rendering CyberChef reverse proxy config"
  envsubst '${DOMAIN}' < "$PROXY_CONF_TEMPLATE" > "$PROXY_CONF_RENDERED"
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    fail "Neither docker compose nor docker-compose is installed"
  fi
}

start_services() {
  [[ -f "${CYBERCHEF_DIR}/docker-compose.yml" ]] || fail "Missing ${CYBERCHEF_DIR}/docker-compose.yml"
  [[ -f "${PROXY_DIR}/docker-compose.yml" ]] || fail "Missing ${PROXY_DIR}/docker-compose.yml"

  log "Starting CyberChef"
  compose_cmd --env-file "$ENV_FILE" -f "${CYBERCHEF_DIR}/docker-compose.yml" up -d

  log "Starting reverse proxy"
  compose_cmd --env-file "$ENV_FILE" -f "${PROXY_DIR}/docker-compose.yml" up -d
}

main() {
  require_cmd docker
  require_cmd openssl
  require_envsubst

  load_env
  ensure_dirs
  create_networks
  handle_certificates
  render_proxy_config
  start_services

  cat <<EOF

[+] Done

CyberChef URL:
    https://cyberchef.${DOMAIN}:8443

Notes:
- This assumes the reverse proxy compose publishes 8443 -> 443.
- If you changed the host port in shared/reverse-proxy/docker-compose.yml, use that port instead.
- If CERT_MODE=provided, the certificate and key were copied into:
    ${CYBERCHEF_CERT_DIR}

EOF
}

main "$@"