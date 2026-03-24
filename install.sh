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

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local input

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt_text [$default_value]: " input || true
    input="${input:-$default_value}"
  else
    read -r -p "$prompt_text: " input || true
  fi

  printf -v "$var_name" '%s' "$input"
}

prompt_choice() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  shift 3
  local valid_choices=("$@")
  local input

  while true; do
    read -r -p "$prompt_text [${valid_choices[*]}] (default: $default_value): " input || true
    input="${input:-$default_value}"

    for choice in "${valid_choices[@]}"; do
      if [[ "$input" == "$choice" ]]; then
        printf -v "$var_name" '%s' "$input"
        return 0
      fi
    done

    warn "Invalid choice: $input"
  done
}

prompt_yes_no() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-y}"
  local input

  while true; do
    read -r -p "$prompt_text [y/n] (default: $default_value): " input || true
    input="${input:-$default_value}"
    case "${input,,}" in
      y|yes)
        printf -v "$var_name" 'yes'
        return 0
        ;;
      n|no)
        printf -v "$var_name" 'no'
        return 0
        ;;
      *)
        warn "Please answer y or n."
        ;;
    esac
  done
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

write_env_file() {
  log "Writing ${ENV_FILE}"
  cat > "$ENV_FILE" <<EOF
DOMAIN=${DOMAIN}
TZ=${TZ}
CERT_MODE=${CERT_MODE}
EOF
  chmod 600 "$ENV_FILE"
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
      prompt cert_src "Path to CyberChef certificate file"
      prompt key_src "Path to CyberChef private key file"

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

render_proxy_config() {
  [[ -f "$PROXY_CONF_TEMPLATE" ]] || fail "Template not found: ${PROXY_CONF_TEMPLATE}"

  log "Rendering CyberChef reverse proxy config"
  export DOMAIN
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
  require_cmd envsubst

  prompt DOMAIN "Base domain"
  prompt TZ "Timezone" "Europe/London"
  prompt_choice CERT_MODE "Certificate mode" "selfsigned" "selfsigned" "provided"

  write_env_file
  ensure_dirs
  create_networks
  handle_certificates
  render_proxy_config
  start_services

  cat <<EOF

[+] Done

Generated:
- ${ENV_FILE}
- ${CYBERCHEF_CERT_DIR}/tls.crt
- ${CYBERCHEF_CERT_DIR}/tls.key
- ${PROXY_CONF_RENDERED}

CyberChef should be available at:
- https://cyberchef.${DOMAIN}:8443

If your reverse proxy compose uses a different host port than 8443, use that instead.
EOF
}

main "$@"