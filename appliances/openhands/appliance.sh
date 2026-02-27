#!/usr/bin/env bash
# --------------------------------------------------------------------------
# OpenHands -- ONE-APPS Appliance Lifecycle Script
#
# Implements the one-apps service_* interface for an AI coding agent
# powered by OpenHands, packaged as an OpenNebula marketplace appliance.
# Docker-based sandbox execution behind Caddy reverse proxy with TLS
# and HTTP basic auth.
# --------------------------------------------------------------------------

# shellcheck disable=SC2034  # ONE_SERVICE_* vars used by one-apps framework

ONE_SERVICE_NAME='Service OpenHands - AI Coding Agent'
ONE_SERVICE_VERSION='1.0.0'
ONE_SERVICE_BUILD=$(date +%s)
ONE_SERVICE_SHORT_DESCRIPTION='AI coding agent (OpenHands) with HTTPS and basic auth'
ONE_SERVICE_DESCRIPTION='OpenHands AI coding agent behind Caddy reverse proxy.
HTTPS with self-signed or Let'\''s Encrypt certificates. HTTP basic auth.
Docker-based sandbox execution for code, commands, and web browsing.'
ONE_SERVICE_RECONFIGURABLE=true

# --------------------------------------------------------------------------
# ONE_SERVICE_PARAMS -- flat array, 4-element stride:
#   'VARNAME' 'lifecycle_step' 'Description' 'default_value'
#
# All variables are bound to the 'configure' step so they are re-read on
# every VM boot / reconfigure cycle.
# --------------------------------------------------------------------------
ONE_SERVICE_PARAMS=(
    'ONEAPP_OH_AUTH_PASSWORD'  'configure' 'Basic auth password (auto-generated if empty)' ''
    'ONEAPP_OH_TLS_DOMAIN'    'configure' 'FQDN for Let'\''s Encrypt (self-signed if empty)' ''
    'ONEAPP_OH_LLM_API_KEY'   'configure' 'LLM provider API key' ''
    'ONEAPP_OH_LLM_MODEL'     'configure' 'LLM model (e.g. anthropic/claude-sonnet-4-20250514)' ''
    'ONEAPP_OH_LLM_BASE_URL'  'configure' 'Custom LLM endpoint (OpenAI-compatible)' ''
)

# --------------------------------------------------------------------------
# Default value assignments
# --------------------------------------------------------------------------
ONEAPP_OH_AUTH_PASSWORD="${ONEAPP_OH_AUTH_PASSWORD:-}"
ONEAPP_OH_TLS_DOMAIN="${ONEAPP_OH_TLS_DOMAIN:-}"
ONEAPP_OH_LLM_API_KEY="${ONEAPP_OH_LLM_API_KEY:-}"
ONEAPP_OH_LLM_MODEL="${ONEAPP_OH_LLM_MODEL:-}"
ONEAPP_OH_LLM_BASE_URL="${ONEAPP_OH_LLM_BASE_URL:-}"

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
readonly OH_DATA_DIR="/var/lib/openhands"
readonly OH_WORKSPACE_DIR="/opt/openhands/workspace"
readonly OH_CERT_DIR="/etc/ssl/openhands"
readonly OH_ENV_FILE="/etc/openhands/env"
readonly OH_CADDYFILE="/etc/caddy/Caddyfile"
readonly OH_LOG="/var/log/one-appliance/openhands.log"
readonly CADDY_BIN="/usr/local/bin/caddy"
readonly CADDY_VERSION="2.11.1"

# OpenHands v1.4.0 (2026-02-17) - verified from docs.openhands.dev
readonly OH_IMAGE="docker.openhands.dev/openhands/openhands:1.4"
readonly OH_RUNTIME_IMAGE="ghcr.io/openhands/agent-server:1.11.4-python"
# Pre-built sandbox runtime - avoids build-time apt-get failures in nested virt
readonly OH_SANDBOX_RUNTIME_IMAGE="ghcr.io/openhands/runtime:1.4-nikolaik"

# ==========================================================================
#  LOGGING: dedicated application log helpers
# ==========================================================================

# Ensure log directory and file exist with correct permissions
init_oh_log() {
    mkdir -p /var/log/one-appliance
    touch "${OH_LOG}"
    chmod 0640 "${OH_LOG}"
}

# Log to both the one-apps framework (via msg) and the dedicated log file
log_oh() {
    local _level="$1"
    shift
    local _message="$*"
    local _timestamp
    _timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "${_timestamp} [${_level^^}] ${_message}" >> "${OH_LOG}"
    msg "${_level}" "${_message}"
}

# ==========================================================================
#  HELPER: get_docker_bridge_ip  (Docker bridge gateway, reachable from containers)
# ==========================================================================

# Returns the Docker bridge gateway IP so that sibling containers (agent-server)
# can reach the OpenHands main container via host.docker.internal.  The port
# binding and Caddy reverse_proxy must use this address instead of 127.0.0.1,
# because agent-server containers connect through the Docker bridge network.
#
# Detection order:
#   1. `docker network inspect bridge` (most reliable, requires dockerd running)
#   2. `ip addr show docker0` (works even before dockerd, reads kernel interface)
#   3. Fallback to 172.17.0.1 (Docker's compiled-in default)
get_docker_bridge_ip() {
    local _ip=""

    # Method 1: ask Docker daemon directly
    _ip=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
    if [[ "${_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${_ip}"
        return 0
    fi

    # Method 2: read from kernel interface (works if docker0 exists but daemon is down)
    _ip=$(ip -4 addr show docker0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [[ "${_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${_ip}"
        return 0
    fi

    # Method 3: Docker's compiled-in default
    echo "172.17.0.1"
}

# ==========================================================================
#  HELPER: get_public_ip  (resolve internet-reachable IP for endpoint)
# ==========================================================================

# Returns the public IP of this VM so that remote users can connect.
# Tries external lookup services first (the VM may be behind NAT),
# falls back to the first local IP if external lookup fails.
get_public_ip() {
    local _pub_ip=""
    for _svc in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
        _pub_ip=$(curl -sf --max-time 5 "${_svc}" 2>/dev/null | tr -d '[:space:]')
        if [[ "${_pub_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${_pub_ip}"
            return 0
        fi
    done
    # Fallback: local IP (private network, may not be reachable from internet)
    hostname -I 2>/dev/null | awk '{print $1}'
}

# ==========================================================================
#  LIFECYCLE: service_install  (Packer build-time, runs once)
# ==========================================================================
service_install() {
    init_oh_log
    log_oh info "=== service_install started ==="
    log_oh info "Installing OpenHands appliance components"

    # 1. Install runtime dependencies
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl jq certbot openssl >/dev/null

    # 2. Install Docker CE from official repository
    log_oh info "Installing Docker CE"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io >/dev/null
    systemctl enable docker
    log_oh info "Docker CE installed"

    # 3. Download Caddy static binary
    log_oh info "Downloading Caddy v${CADDY_VERSION}"
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
        | tar xz -C /usr/local/bin caddy
    chmod 0755 /usr/local/bin/caddy
    log_oh info "Caddy installed to ${CADDY_BIN}"

    # 4. Pre-pull OpenHands Docker images
    log_oh info "Pre-pulling OpenHands images (this may take a while)"
    docker pull "${OH_IMAGE}"
    docker pull "${OH_RUNTIME_IMAGE}"
    docker pull "${OH_SANDBOX_RUNTIME_IMAGE}"
    log_oh info "Main image size: $(docker image inspect "${OH_IMAGE}" --format='{{.Size}}' | numfmt --to=iec 2>/dev/null || echo 'unknown')"
    log_oh info "Runtime image size: $(docker image inspect "${OH_RUNTIME_IMAGE}" --format='{{.Size}}' | numfmt --to=iec 2>/dev/null || echo 'unknown')"
    log_oh info "Sandbox runtime image size: $(docker image inspect "${OH_SANDBOX_RUNTIME_IMAGE}" --format='{{.Size}}' | numfmt --to=iec 2>/dev/null || echo 'unknown')"

    # 5. Create openhands user and directories
    log_oh info "Creating openhands user and directories"
    useradd -r -m -u 1000 -d /var/lib/openhands -s /usr/sbin/nologin openhands
    mkdir -p "${OH_WORKSPACE_DIR}" "${OH_CERT_DIR}" /etc/openhands /etc/caddy
    chown 1000:1000 "${OH_DATA_DIR}" "${OH_WORKSPACE_DIR}"

    # 6. Create 2 GB swap file
    log_oh info "Creating 2 GB swap file"
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab

    # 7. Create OpenHands systemd unit
    log_oh info "Creating systemd units"
    cat > /etc/systemd/system/openhands.service <<'UNIT_EOF'
[Unit]
Description=OpenHands AI Coding Agent
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/bin/docker stop openhands
ExecStartPre=-/usr/bin/docker rm openhands
ExecStart=/usr/local/bin/openhands-start.sh
ExecStop=/usr/bin/docker stop openhands
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT_EOF

    # 8. Create OpenHands start wrapper
    #    Note: single-quoted heredoc -- variables resolve at runtime, not install time.
    #    The script detects the Docker bridge gateway IP dynamically so that
    #    agent-server containers can reach back to OpenHands via host.docker.internal.
    cat > /usr/local/bin/openhands-start.sh <<'WRAPPER_EOF'
#!/bin/bash
source /etc/openhands/env

# Detect Docker bridge gateway (agent-server containers connect through it)
DOCKER_BRIDGE_IP=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
if ! [[ "${DOCKER_BRIDGE_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    DOCKER_BRIDGE_IP=$(ip -4 addr show docker0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
fi
DOCKER_BRIDGE_IP="${DOCKER_BRIDGE_IP:-172.17.0.1}"

exec docker run -d --name openhands \
    --restart unless-stopped \
    -e AGENT_SERVER_IMAGE_REPOSITORY="ghcr.io/openhands/agent-server" \
    -e AGENT_SERVER_IMAGE_TAG="1.11.4-python" \
    -e SANDBOX_USER_ID=1000 \
    -e WORKSPACE_BASE=/opt/openhands/workspace \
    ${SSL_VERIFY:+-e SSL_VERIFY="${SSL_VERIFY}"} \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/openhands/.openhands:/.openhands \
    -v /opt/openhands/workspace:/opt/openhands/workspace \
    -p "${DOCKER_BRIDGE_IP}:3000:3000" \
    --add-host host.docker.internal:host-gateway \
    --pull=never \
    "${OH_MAIN_IMAGE}"
WRAPPER_EOF
    chmod +x /usr/local/bin/openhands-start.sh

    # 9. Create Caddy systemd unit
    cat > /etc/systemd/system/caddy.service <<'UNIT_EOF'
[Unit]
Description=Caddy Reverse Proxy for OpenHands
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

    # 10. Create Docker cleanup timer
    cat > /etc/systemd/system/openhands-cleanup.timer <<'TIMER_EOF'
[Unit]
Description=Periodic Docker cleanup for OpenHands

[Timer]
OnBootSec=1h
OnUnitActiveSec=4h
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

    cat > /etc/systemd/system/openhands-cleanup.service <<'UNIT_EOF'
[Unit]
Description=Docker cleanup for OpenHands

[Service]
Type=oneshot
ExecStart=/usr/bin/docker container prune -f --filter "until=2h"
ExecStart=/usr/bin/docker system prune -f --filter "until=24h"
UNIT_EOF

    # 11. Reload systemd
    systemctl daemon-reload

    # 12. Clean up apt cache
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # 13. Install SSH login banner
    cat > /etc/profile.d/openhands-banner.sh <<'BANNER_EOF'
#!/bin/bash
[[ $- == *i* ]] || return
_pub_ip=""
for _svc in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
    _pub_ip=$(curl -sf --max-time 3 "${_svc}" 2>/dev/null | tr -d '[:space:]')
    [[ "${_pub_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    _pub_ip=""
done
_vm_ip="${_pub_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
_password=$(cat /var/lib/openhands/password 2>/dev/null || echo 'see report')
_oh=$(systemctl is-active openhands 2>/dev/null || echo 'unknown')
_caddy=$(systemctl is-active caddy 2>/dev/null || echo 'unknown')
printf '\n'
printf '  OpenHands -- AI Coding Agent\n'
printf '  ============================\n'
printf '  Endpoint : https://%s\n' "${_vm_ip}"
printf '  Password : %s\n' "${_password}"
printf '  OpenHands: %s\n' "${_oh}"
printf '  Caddy    : %s\n' "${_caddy}"
printf '\n'
printf '  Report   : cat /etc/one-appliance/config\n'
printf '  Logs     : tail -f /var/log/one-appliance/openhands.log\n'
printf '\n'
BANNER_EOF
    chmod 0644 /etc/profile.d/openhands-banner.sh

    log_oh info "OpenHands appliance install complete"
}

# ==========================================================================
#  HELPER: generate_selfsigned_cert
# ==========================================================================
generate_selfsigned_cert() {
    local _vm_ip
    _vm_ip=$(hostname -I | awk '{print $1}')
    mkdir -p "${OH_CERT_DIR}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${OH_CERT_DIR}/selfsigned-key.pem" \
        -out "${OH_CERT_DIR}/selfsigned-cert.pem" \
        -days 3650 \
        -subj "/CN=OpenHands" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${_vm_ip}"
    chmod 0600 "${OH_CERT_DIR}/selfsigned-key.pem"
    chmod 0644 "${OH_CERT_DIR}/selfsigned-cert.pem"
    ln -sf "${OH_CERT_DIR}/selfsigned-cert.pem" "${OH_CERT_DIR}/cert.pem"
    ln -sf "${OH_CERT_DIR}/selfsigned-key.pem" "${OH_CERT_DIR}/key.pem"
    log_oh info "Self-signed certificate generated for ${_vm_ip}"
}

# ==========================================================================
#  HELPER: generate_password
# ==========================================================================
generate_password() {
    local _password="${ONEAPP_OH_AUTH_PASSWORD:-}"
    if [ -z "${_password}" ]; then
        if [ -f "${OH_DATA_DIR}/password" ]; then
            log_oh info "Keeping existing auto-generated password"
            return 0
        fi
        _password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        log_oh info "Auto-generated basic auth password"
    fi
    mkdir -p "${OH_DATA_DIR}"
    echo "${_password}" > "${OH_DATA_DIR}/password"
    chmod 0600 "${OH_DATA_DIR}/password"
}

# ==========================================================================
#  HELPER: generate_caddyfile
# ==========================================================================
generate_caddyfile() {
    local _password _hash _bridge_ip
    _password=$(cat "${OH_DATA_DIR}/password")
    _hash=$(${CADDY_BIN} hash-password --plaintext "${_password}")
    _bridge_ip=$(get_docker_bridge_ip)

    if [ -n "${ONEAPP_OH_TLS_DOMAIN:-}" ]; then
        cat > "${OH_CADDYFILE}" <<CADDY_EOF
{
    email admin@${ONEAPP_OH_TLS_DOMAIN}
}

${ONEAPP_OH_TLS_DOMAIN} {
    basicauth /* {
        admin ${_hash}
    }

    reverse_proxy ${_bridge_ip}:3000 {
        flush_interval -1
        stream_timeout 0
    }
}
CADDY_EOF
        log_oh info "Caddyfile generated for domain: ${ONEAPP_OH_TLS_DOMAIN} (proxy to ${_bridge_ip}:3000)"
    else
        cat > "${OH_CADDYFILE}" <<CADDY_EOF
{
    auto_https disable_redirects
}

:443 {
    tls ${OH_CERT_DIR}/cert.pem ${OH_CERT_DIR}/key.pem

    basicauth /* {
        admin ${_hash}
    }

    reverse_proxy ${_bridge_ip}:3000 {
        flush_interval -1
        stream_timeout 0
    }
}
CADDY_EOF
        log_oh info "Caddyfile generated for self-signed TLS (proxy to ${_bridge_ip}:3000)"
    fi
    chmod 0600 "${OH_CADDYFILE}"
}

# ==========================================================================
#  HELPER: generate_openhands_env
# ==========================================================================
generate_openhands_env() {
    mkdir -p /etc/openhands
    cat > "${OH_ENV_FILE}" <<ENV_EOF
OH_MAIN_IMAGE=${OH_IMAGE}
# OH_RUNTIME_IMAGE used at build time for docker pull (line 132)
ENV_EOF

    # Add SSL bypass when custom base URL is set (self-signed certs)
    if [ -n "${ONEAPP_OH_LLM_BASE_URL:-}" ]; then
        echo "SSL_VERIFY=False" >> "${OH_ENV_FILE}"
    fi

    chmod 0600 "${OH_ENV_FILE}"
    log_oh info "OpenHands environment file written to ${OH_ENV_FILE}"
}

# ==========================================================================
#  HELPER: generate_openhands_settings
# ==========================================================================
generate_openhands_settings() {
    local _settings_dir="${OH_DATA_DIR}/.openhands"
    local _settings_file="${_settings_dir}/settings.json"
    mkdir -p "${_settings_dir}"

    # If no LLM context vars are set and settings.json already exists,
    # preserve user's UI configuration (don't overwrite).
    if [ -z "${ONEAPP_OH_LLM_MODEL:-}" ] && \
       [ -z "${ONEAPP_OH_LLM_API_KEY:-}" ] && \
       [ -z "${ONEAPP_OH_LLM_BASE_URL:-}" ]; then
        if [ -f "${_settings_file}" ]; then
            log_oh info "No LLM context vars set, preserving existing settings.json"
            return 0
        fi
        # First boot with no LLM vars: write clean defaults (user configures via UI)
        jq -n --arg sandbox_img "${OH_SANDBOX_RUNTIME_IMAGE}" '{
            language: "en",
            agent: "CodeActAgent",
            max_iterations: null,
            security_analyzer: null,
            confirmation_mode: false,
            llm_model: null,
            llm_api_key: null,
            llm_base_url: null,
            remote_runtime_resource_factor: null,
            enable_default_condenser: true,
            enable_sound_notifications: false,
            enable_proactive_conversation_starters: true,
            enable_solvability_analysis: true,
            user_consents_to_analytics: null,
            sandbox_base_container_image: null,
            sandbox_runtime_container_image: $sandbox_img,
            mcp_config: null,
            search_api_key: null,
            sandbox_api_key: null,
            max_budget_per_task: null,
            condenser_max_size: null,
            secrets_store: { provider_tokens: {} },
            v1_enabled: true
        }' > "${_settings_file}"
        log_oh info "OpenHands settings.json written (no LLM pre-configured)"
    else
        # LLM context vars are set: inject them into settings.json
        jq -n \
            --arg model "${ONEAPP_OH_LLM_MODEL}" \
            --arg api_key "${ONEAPP_OH_LLM_API_KEY}" \
            --arg base_url "${ONEAPP_OH_LLM_BASE_URL}" \
            --arg sandbox_img "${OH_SANDBOX_RUNTIME_IMAGE}" \
            '{
                language: "en",
                agent: "CodeActAgent",
                max_iterations: null,
                security_analyzer: null,
                confirmation_mode: false,
                llm_model: (if $model == "" then null else $model end),
                llm_api_key: (if $api_key == "" then null else $api_key end),
                llm_base_url: (if $base_url == "" then null else $base_url end),
                remote_runtime_resource_factor: null,
                enable_default_condenser: true,
                enable_sound_notifications: false,
                enable_proactive_conversation_starters: true,
                enable_solvability_analysis: true,
                user_consents_to_analytics: null,
                sandbox_base_container_image: null,
                sandbox_runtime_container_image: $sandbox_img,
                mcp_config: null,
                search_api_key: null,
                sandbox_api_key: null,
                max_budget_per_task: null,
                condenser_max_size: null,
                secrets_store: { provider_tokens: {} },
                v1_enabled: true
            }' > "${_settings_file}"
        log_oh info "OpenHands settings.json written (model=${ONEAPP_OH_LLM_MODEL:-not set})"
    fi

    chown 1000:1000 "${_settings_dir}" "${_settings_file}"
    chmod 0600 "${_settings_file}"
}

# ==========================================================================
#  LIFECYCLE: service_configure  (runs at each VM boot)
# ==========================================================================
service_configure() {
    init_oh_log
    log_oh info "=== service_configure started ==="

    generate_selfsigned_cert
    generate_password
    generate_caddyfile
    generate_openhands_env
    generate_openhands_settings

    systemctl daemon-reload

    log_oh info "=== service_configure complete ==="
}

# ==========================================================================
#  HELPER: attempt_letsencrypt
# ==========================================================================
attempt_letsencrypt() {
    if [ -z "${ONEAPP_OH_TLS_DOMAIN:-}" ]; then
        log_oh info "No TLS domain set, skipping Let's Encrypt"
        return 0
    fi

    log_oh info "Attempting Let's Encrypt certificate for ${ONEAPP_OH_TLS_DOMAIN}"
    if certbot certonly --non-interactive --agree-tos \
        --register-unsafely-without-email --standalone \
        --preferred-challenges http \
        -d "${ONEAPP_OH_TLS_DOMAIN}" 2>&1 | tee -a "${OH_LOG}"; then

        # Update symlinks to Let's Encrypt certs
        ln -sf "/etc/letsencrypt/live/${ONEAPP_OH_TLS_DOMAIN}/fullchain.pem" "${OH_CERT_DIR}/cert.pem"
        ln -sf "/etc/letsencrypt/live/${ONEAPP_OH_TLS_DOMAIN}/privkey.pem" "${OH_CERT_DIR}/key.pem"

        # Create renewal hook to reload Caddy
        mkdir -p /etc/letsencrypt/renewal-hooks/post
        cat > /etc/letsencrypt/renewal-hooks/post/reload-caddy.sh <<'HOOK_EOF'
#!/bin/bash
systemctl reload caddy
HOOK_EOF
        chmod +x /etc/letsencrypt/renewal-hooks/post/reload-caddy.sh

        log_oh info "Let's Encrypt certificate obtained for ${ONEAPP_OH_TLS_DOMAIN}"
    else
        log_oh warn "Let's Encrypt failed, keeping self-signed certificate"
    fi
}

# ==========================================================================
#  HELPER: wait_for_openhands
# ==========================================================================
wait_for_openhands() {
    local _timeout=120 _elapsed=0 _bridge_ip
    _bridge_ip=$(get_docker_bridge_ip)
    log_oh info "Waiting for OpenHands readiness at ${_bridge_ip}:3000 (timeout: ${_timeout}s)"
    while ! curl -sf "http://${_bridge_ip}:3000/" >/dev/null 2>&1; do
        sleep 5
        _elapsed=$((_elapsed + 5))
        if [ "${_elapsed}" -ge "${_timeout}" ]; then
            log_oh error "OpenHands not ready after ${_timeout}s -- check: docker logs openhands"
            exit 1
        fi
    done
    log_oh info "OpenHands ready (${_elapsed}s)"
}

# ==========================================================================
#  HELPER: wait_for_caddy
# ==========================================================================
wait_for_caddy() {
    local _timeout=30 _elapsed=0 _code
    log_oh info "Waiting for Caddy readiness (timeout: ${_timeout}s)"
    sleep 2  # give Caddy time to open TLS listener after systemctl returns
    while true; do
        _code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1/" 2>/dev/null)
        if [ "${_code}" = "401" ] || [ "${_code}" = "200" ]; then
            break
        fi
        sleep 2
        _elapsed=$((_elapsed + 2))
        if [ "${_elapsed}" -ge "${_timeout}" ]; then
            log_oh warn "Caddy not ready after ${_timeout}s -- check: journalctl -u caddy"
            return 0  # don't abort bootstrap; Caddy may start momentarily
        fi
    done
    log_oh info "Caddy ready (${_elapsed}s)"
}

# ==========================================================================
#  HELPER: validate_llm_connection
# ==========================================================================
validate_llm_connection() {
    local _status="not configured"

    if [ -z "${ONEAPP_OH_LLM_API_KEY:-}" ]; then
        echo "${_status}"
        return 0
    fi

    if [ -n "${ONEAPP_OH_LLM_BASE_URL:-}" ]; then
        # Custom endpoint (OpenAI-compatible) -- probe /models
        if curl -sf --max-time 10 -k \
            -H "Authorization: Bearer ${ONEAPP_OH_LLM_API_KEY}" \
            "${ONEAPP_OH_LLM_BASE_URL}/models" >/dev/null 2>&1; then
            _status="connected"
        else
            _status="unreachable"
        fi
    else
        # Cloud provider -- just confirm API key is set
        _status="configured (cloud: ${ONEAPP_OH_LLM_MODEL%%/*})"
    fi

    echo "${_status}"
}

# ==========================================================================
#  HELPER: write_report_file
# ==========================================================================
write_report_file() {
    local _report="${ONE_SERVICE_REPORT:-/etc/one-appliance/config}"
    local _pub_ip _password _tls_mode _endpoint
    local _oh_status _caddy_status
    local _llm_model _llm_base_url _api_key_display _llm_status _step3

    _pub_ip=$(get_public_ip)
    _password=$(cat "${OH_DATA_DIR}/password" 2>/dev/null || echo 'unknown')

    if [ -n "${ONEAPP_OH_TLS_DOMAIN:-}" ]; then
        _tls_mode="Let's Encrypt (${ONEAPP_OH_TLS_DOMAIN})"
        _endpoint="${ONEAPP_OH_TLS_DOMAIN}"
    else
        _tls_mode="self-signed"
        _endpoint="${_pub_ip}"
    fi

    _oh_status=$(systemctl is-active openhands 2>/dev/null || echo 'unknown')
    _caddy_status=$(systemctl is-active caddy 2>/dev/null || echo 'unknown')

    # LLM configuration for report
    _llm_model="${ONEAPP_OH_LLM_MODEL:-(not set -- configure via UI)}"

    if [ -n "${ONEAPP_OH_LLM_API_KEY:-}" ]; then
        local _key="${ONEAPP_OH_LLM_API_KEY}"
        local _last4="${_key: -4}"
        _api_key_display="****${_last4}"
    else
        _api_key_display="(not set)"
    fi

    if [ -n "${ONEAPP_OH_LLM_BASE_URL:-}" ]; then
        _llm_base_url="${ONEAPP_OH_LLM_BASE_URL}"
    else
        _llm_base_url="(default provider endpoint)"
    fi

    _llm_status=$(validate_llm_connection)

    # Contextual step 3 based on LLM configuration
    if [ -n "${ONEAPP_OH_LLM_API_KEY:-}" ]; then
        _step3="Your LLM is pre-configured (${_llm_model}) -- start coding"
    else
        _step3="Configure your LLM provider in the OpenHands settings"
    fi

    mkdir -p "$(dirname "${_report}")"
    cat > "${_report}" <<REPORT_EOF
[Connection info]
url          = https://${_endpoint}
username     = admin
password     = ${_password}

[Service status]
openhands    = ${_oh_status}
caddy        = ${_caddy_status}
tls          = ${_tls_mode}

[Quick start]
1. Open https://${_endpoint} in your browser
2. Log in with username "admin" and password above
3. ${_step3}
4. Start coding with your AI agent

[LLM configuration]
model        = ${_llm_model}
base_url     = ${_llm_base_url}
api_key      = ${_api_key_display}
status       = ${_llm_status}

[Workspace]
path         = /opt/openhands/workspace (persisted across reboots)

[Service management]
systemctl status openhands
systemctl restart openhands
docker logs openhands -f
journalctl -u caddy -f

[Password retrieval]
cat /var/lib/openhands/password
REPORT_EOF
    chmod 600 "${_report}"
    log_oh info "Report written to ${_report}"
}

# ==========================================================================
#  LIFECYCLE: service_bootstrap  (runs after configure, starts services)
# ==========================================================================
service_bootstrap() {
    init_oh_log
    log_oh info "=== service_bootstrap started ==="

    # Ensure Docker is running
    systemctl start docker

    # Attempt Let's Encrypt (port 80 is free before Caddy starts)
    attempt_letsencrypt

    # Start OpenHands container
    systemctl enable openhands.service
    systemctl start openhands.service
    wait_for_openhands

    # Start Caddy reverse proxy
    systemctl enable caddy.service
    systemctl start caddy.service
    wait_for_caddy

    # Enable cleanup timer
    systemctl enable --now openhands-cleanup.timer

    # Write connection report
    write_report_file

    local _endpoint
    if [ -n "${ONEAPP_OH_TLS_DOMAIN:-}" ]; then
        _endpoint="${ONEAPP_OH_TLS_DOMAIN}"
    else
        _endpoint=$(get_public_ip)
    fi
    log_oh info "=== service_bootstrap complete ==="
    log_oh info "OpenHands available at https://${_endpoint}"
}

# ==========================================================================
#  LIFECYCLE: service_cleanup
# ==========================================================================
service_cleanup() { :; }

# ==========================================================================
#  LIFECYCLE: service_help
# ==========================================================================
service_help() {
    cat <<'HELP'
OpenHands Appliance
===================

AI coding agent (OpenHands) behind Caddy reverse proxy with TLS and
HTTP basic authentication. Docker-based sandbox execution for code,
commands, and web browsing.

Configuration variables (set via OpenNebula context):
  ONEAPP_OH_AUTH_PASSWORD    Basic auth password (auto-generated 16-char if empty)
  ONEAPP_OH_TLS_DOMAIN      FQDN for Let's Encrypt certificate (optional)
                             If empty, self-signed certificate is used
  ONEAPP_OH_LLM_API_KEY     LLM provider API key (e.g. Anthropic, OpenAI)
  ONEAPP_OH_LLM_MODEL       Model name (e.g. anthropic/claude-sonnet-4-20250514)
  ONEAPP_OH_LLM_BASE_URL    Custom LLM endpoint (OpenAI-compatible)

Ports:
  443   HTTPS (Caddy reverse proxy with basic auth)
  3000  OpenHands UI (bound to Docker bridge, not directly accessible)

Service management:
  systemctl status openhands        Check OpenHands container status
  systemctl restart openhands       Restart OpenHands container
  systemctl status caddy            Check Caddy reverse proxy status
  systemctl restart caddy           Restart Caddy
  journalctl -u openhands -f        Follow OpenHands logs
  journalctl -u caddy -f            Follow Caddy logs

Configuration files:
  /etc/openhands/env                Environment file (image refs)
  /etc/caddy/Caddyfile              Caddy reverse proxy config
  /etc/ssl/openhands/cert.pem       TLS certificate (symlink)
  /etc/ssl/openhands/key.pem        TLS private key (symlink)
  /var/lib/openhands/.openhands/settings.json  LLM configuration (via UI or context vars)

Data directories:
  /opt/openhands/workspace          Workspace files (persisted)
  /var/lib/openhands/.openhands     OpenHands state (persisted)

Report and logs:
  /etc/one-appliance/config         Service report (credentials, endpoints)
  /var/log/one-appliance/openhands.log   Application log (all stages)

Password retrieval:
  cat /var/lib/openhands/password
HELP
}
