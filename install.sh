#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

CYBERCHEF_DIR="${ROOT_DIR}/Cyberchef"
NAVIGATOR_DIR="${ROOT_DIR}/Navigator"
OPENCTI_DIR="${ROOT_DIR}/OpenCTI"
PROXY_DIR="${ROOT_DIR}/shared/reverse-proxy"

CYBERCHEF_CERT_DIR="${CYBERCHEF_DIR}/certs"
NAVIGATOR_CERT_DIR="${NAVIGATOR_DIR}/certs"
OPENCTI_CERT_DIR="${OPENCTI_DIR}/certs"

CYBERCHEF_CONF_TEMPLATE="${PROXY_DIR}/conf.d/cyberchef.conf.template"
CYBERCHEF_CONF_RENDERED="${PROXY_DIR}/conf.d/cyberchef.conf"

NAVIGATOR_CONF_TEMPLATE="${PROXY_DIR}/conf.d/navigator.conf.template"
NAVIGATOR_CONF_RENDERED="${PROXY_DIR}/conf.d/navigator.conf"

OPENCTI_CONF_TEMPLATE="${PROXY_DIR}/conf.d/opencti.conf.template"
OPENCTI_CONF_RENDERED="${PROXY_DIR}/conf.d/opencti.conf"

OPENCTI_REDIS_DATA_DIR="${OPENCTI_DIR}/redis"
OPENCTI_MINIO_DATA_DIR="${OPENCTI_DIR}/minio"

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

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local input1 input2

  while true; do
    read -r -s -p "$prompt_text: " input1 || true
    echo
    read -r -s -p "Confirm $prompt_text: " input2 || true
    echo

    if [[ "$input1" == "$input2" ]]; then
      printf -v "$var_name" '%s' "$input1"
      return 0
    fi

    warn "Values did not match. Try again."
  done
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

random_secret() {
  openssl rand -hex 32
}

random_base64_32() {
  openssl rand -base64 32 | tr -d '\n'
}

random_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

validate_uuid() {
  local value="$1"
  [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

ensure_dirs() {
  mkdir -p "$CYBERCHEF_CERT_DIR"
  mkdir -p "$NAVIGATOR_CERT_DIR"
  mkdir -p "$OPENCTI_CERT_DIR"
  mkdir -p "${PROXY_DIR}/conf.d"

  mkdir -p "$OPENCTI_REDIS_DATA_DIR"
  mkdir -p "$OPENCTI_MINIO_DATA_DIR"
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
OPENCTI_ADMIN_EMAIL=${OPENCTI_ADMIN_EMAIL}
OPENCTI_ADMIN_PASSWORD=${OPENCTI_ADMIN_PASSWORD}
OPENCTI_ADMIN_TOKEN=${OPENCTI_ADMIN_TOKEN}
OPENCTI_ENCRYPTION_KEY=${OPENCTI_ENCRYPTION_KEY}
OPENCTI_HEALTHCHECK_ACCESS_KEY=${OPENCTI_HEALTHCHECK_ACCESS_KEY}
OPENCTI_REDIS_PASSWORD=${OPENCTI_REDIS_PASSWORD}
OPENCTI_RABBITMQ_DEFAULT_PASS=${OPENCTI_RABBITMQ_DEFAULT_PASS}
OPENCTI_MINIO_ROOT_PASSWORD=${OPENCTI_MINIO_ROOT_PASSWORD}
OPENCTI_ELASTIC_PASSWORD=${OPENCTI_ELASTIC_PASSWORD}
EOF
  chmod 600 "$ENV_FILE"
}

handle_certificates_for_service() {
  local service_name="$1"
  local fqdn="$2"
  local cert_dir="$3"

  case "${CERT_MODE}" in
    selfsigned)
      generate_self_signed_cert "$fqdn" "$cert_dir"
      ;;
    provided)
      local cert_src key_src
      log "Using provided certificate files for ${fqdn}"
      prompt cert_src "Path to ${service_name} certificate file"
      prompt key_src "Path to ${service_name} private key file"

      copy_file_checked "$cert_src" "${cert_dir}/tls.crt"
      copy_file_checked "$key_src" "${cert_dir}/tls.key"

      chmod 600 "${cert_dir}/tls.key"
      chmod 644 "${cert_dir}/tls.crt"
      ;;
    *)
      fail "CERT_MODE must be either 'selfsigned' or 'provided'"
      ;;
  esac
}

handle_certificates() {
  handle_certificates_for_service "Cyberchef" "cyberchef.${DOMAIN}" "$CYBERCHEF_CERT_DIR"
  handle_certificates_for_service "Navigator" "navigator.${DOMAIN}" "$NAVIGATOR_CERT_DIR"
  handle_certificates_for_service "OpenCTI" "opencti.${DOMAIN}" "$OPENCTI_CERT_DIR"
}

render_proxy_configs() {
  [[ -f "$CYBERCHEF_CONF_TEMPLATE" ]] || fail "Template not found: ${CYBERCHEF_CONF_TEMPLATE}"
  [[ -f "$NAVIGATOR_CONF_TEMPLATE" ]] || fail "Template not found: ${NAVIGATOR_CONF_TEMPLATE}"
  [[ -f "$OPENCTI_CONF_TEMPLATE" ]] || fail "Template not found: ${OPENCTI_CONF_TEMPLATE}"

  log "Rendering reverse proxy configs"
  export DOMAIN
  envsubst '${DOMAIN}' < "$CYBERCHEF_CONF_TEMPLATE" > "$CYBERCHEF_CONF_RENDERED"
  envsubst '${DOMAIN}' < "$NAVIGATOR_CONF_TEMPLATE" > "$NAVIGATOR_CONF_RENDERED"
  envsubst '${DOMAIN}' < "$OPENCTI_CONF_TEMPLATE" > "$OPENCTI_CONF_RENDERED"
}

prepare_opencti_host() {
  log "Preparing OpenCTI host settings"

  mkdir -p "$OPENCTI_REDIS_DATA_DIR" "$OPENCTI_MINIO_DATA_DIR"

  chmod -R 755 "$OPENCTI_REDIS_DATA_DIR" "$OPENCTI_MINIO_DATA_DIR" || true

  sysctl -w vm.max_map_count=1048576 >/dev/null

  if [[ -d /etc/sysctl.d ]]; then
    cat > /etc/sysctl.d/99-elasticsearch.conf <<EOF
vm.max_map_count=1048576
EOF
    sysctl --system >/dev/null || warn "Could not reload all sysctl settings automatically"
  else
    warn "/etc/sysctl.d not present; vm.max_map_count was set for current runtime only"
  fi
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
  [[ -f "${NAVIGATOR_DIR}/docker-compose.yml" ]] || fail "Missing ${NAVIGATOR_DIR}/docker-compose.yml"
  [[ -f "${OPENCTI_DIR}/docker-compose.yml" ]] || fail "Missing ${OPENCTI_DIR}/docker-compose.yml"
  [[ -f "${PROXY_DIR}/docker-compose.yml" ]] || fail "Missing ${PROXY_DIR}/docker-compose.yml"

  log "Starting Cyberchef"
  compose_cmd --env-file "$ENV_FILE" -f "${CYBERCHEF_DIR}/docker-compose.yml" up -d

  log "Starting Navigator"
  compose_cmd --env-file "$ENV_FILE" -f "${NAVIGATOR_DIR}/docker-compose.yml" up -d

  log "Starting OpenCTI"
  compose_cmd --env-file "$ENV_FILE" -f "${OPENCTI_DIR}/docker-compose.yml" up -d

  log "Starting reverse proxy"
  compose_cmd --env-file "$ENV_FILE" -f "${PROXY_DIR}/docker-compose.yml" up -d
}

main() {
  [[ "$(id -u)" -eq 0 ]] || fail "Run this script as root"

  require_cmd docker
  require_cmd openssl
  require_cmd envsubst
  require_cmd sysctl

  prompt DOMAIN "Base domain"
  prompt TZ "Timezone" "Europe/London"
  prompt_choice CERT_MODE "Certificate mode" "selfsigned" "selfsigned" "provided"

  prompt OPENCTI_ADMIN_EMAIL "OpenCTI admin email"

  prompt_secret OPENCTI_ADMIN_PASSWORD "OpenCTI admin password"

  prompt_yes_no GENERATE_OPENCTI_SECRETS "Generate OpenCTI tokens and passwords automatically?" "y"
  if [[ "$GENERATE_OPENCTI_SECRETS" == "yes" ]]; then
    OPENCTI_ADMIN_TOKEN="$(random_uuid)"
    OPENCTI_ENCRYPTION_KEY="$(random_base64_32)"
    OPENCTI_HEALTHCHECK_ACCESS_KEY="$(random_secret)"
    OPENCTI_REDIS_PASSWORD="$(random_secret)"
    OPENCTI_RABBITMQ_DEFAULT_PASS="$(random_secret)"
    OPENCTI_MINIO_ROOT_PASSWORD="$(random_secret)"
    OPENCTI_ELASTIC_PASSWORD="$(random_secret)"
  else
    prompt OPENCTI_ADMIN_TOKEN "OpenCTI admin token (UUID format)"
    prompt OPENCTI_ENCRYPTION_KEY "OpenCTI encryption key (base64 from openssl rand -base64 32)"
    prompt_secret OPENCTI_HEALTHCHECK_ACCESS_KEY "OpenCTI healthcheck access key"
    prompt_secret OPENCTI_REDIS_PASSWORD "OpenCTI Redis password"
    prompt_secret OPENCTI_RABBITMQ_DEFAULT_PASS "OpenCTI RabbitMQ password"
    prompt_secret OPENCTI_MINIO_ROOT_PASSWORD "OpenCTI MinIO root password"
    prompt_secret OPENCTI_ELASTIC_PASSWORD "OpenCTI Elasticsearch password"
  fi

  validate_uuid "$OPENCTI_ADMIN_TOKEN" || fail "OPENCTI_ADMIN_TOKEN must be a valid UUID"

  write_env_file
  ensure_dirs
  create_networks
  prepare_opencti_host
  handle_certificates
  render_proxy_configs
  start_services

  cat <<EOF

[+] Done

Generated:
- ${ENV_FILE}
- ${CYBERCHEF_CERT_DIR}/tls.crt
- ${CYBERCHEF_CERT_DIR}/tls.key
- ${NAVIGATOR_CERT_DIR}/tls.crt
- ${NAVIGATOR_CERT_DIR}/tls.key
- ${OPENCTI_CERT_DIR}/tls.crt
- ${OPENCTI_CERT_DIR}/tls.key
- ${CYBERCHEF_CONF_RENDERED}
- ${NAVIGATOR_CONF_RENDERED}
- ${OPENCTI_CONF_RENDERED}

Prepared:
- ${OPENCTI_REDIS_DATA_DIR}
- ${OPENCTI_MINIO_DATA_DIR}
- /etc/sysctl.d/99-elasticsearch.conf

URLs:
- https://cyberchef.${DOMAIN}:8443
- https://navigator.${DOMAIN}:8443
- https://opencti.${DOMAIN}:8443

If your reverse proxy compose uses a different host port than 8443, use that instead.
EOF
}

main "$@"