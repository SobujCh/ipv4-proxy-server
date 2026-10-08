#!/usr/bin/env bash
#
# ipv4-proxy-server.sh — HTTP proxy with one port per public IPv4 (outbound binding)
#
# Usage:
#   ./ipv4-proxy-server.sh [-u USER] [-p PASS] [-b BASE_PORT] [-a start|stop|restart|status]
#
# The first start saves the login and ports and turns the proxy on at boot.
# Later restarts reuse that saved setup.
#
# Examples:
#   ./ipv4-proxy-server.sh -u pxuser -p your-password
#   ./ipv4-proxy-server.sh                          # no authentication
#   ./ipv4-proxy-server.sh -b 20000 -u pxuser -p secret
#

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly CONFIG_DIR="/etc/ipv4-proxy-server"
readonly CONFIG_FILE="${CONFIG_DIR}/3proxy.cfg"
readonly SETTINGS_FILE="${CONFIG_DIR}/settings.env"
readonly PID_FILE="/var/run/ipv4-proxy-server.pid"
readonly LOG_FILE="/var/log/ipv4-proxy-server.log"
readonly MAP_FILE="${CONFIG_DIR}/proxy-map.txt"
readonly IP_LIST_FILE="${CONFIG_DIR}/ip_list.txt"
readonly INSTALL_PATH="/usr/local/sbin/ipv4-proxy-server.sh"
readonly UNIT_NAME="ipv4-proxy-server.service"
readonly UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"

BASE_PORT=30000
USERNAME=""
PASSWORD=""
ACTION="start"
BASE_PORT_SET=0
AUTH_SET=0

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Automatically detect public IPv4 addresses on this host and start an HTTP
proxy listener on each one. Each proxy binds outbound traffic to its IPv4.

After the first start, the same proxies start again when the machine restarts.
The first start also saves every public address to ${IP_LIST_FILE}.
Later starts use only the addresses still listed there. Delete a line and
restart to stop proxying that address. The others keep their ports.

Options:
  -u USER          Proxy username (requires -p for authentication)
  -p PASS          Proxy password (requires -u for authentication)
  -b BASE_PORT     First port to use (default: ${BASE_PORT})
  -a ACTION        start | stop | restart | status (default: start)
  -h               Show this help

Examples:
  ${SCRIPT_NAME} -u pxuser -p your-password
  ${SCRIPT_NAME} -b 20000
  ${SCRIPT_NAME} -a status
  ${SCRIPT_NAME} -a restart
  ${SCRIPT_NAME} -a stop

When -u and -p are both provided, password authentication is enabled.
Otherwise proxies accept connections without authentication.

Restart reuses the username, password, and base port from the last setup
unless you pass new ones.
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
        die "systemd is required so the proxies can start again after a reboot."
    fi
}

parse_args() {
    while getopts ":u:p:b:a:h" opt; do
        case "${opt}" in
            u)
                USERNAME="${OPTARG}"
                AUTH_SET=1
                ;;
            p)
                PASSWORD="${OPTARG}"
                AUTH_SET=1
                ;;
            b)
                BASE_PORT="${OPTARG}"
                BASE_PORT_SET=1
                ;;
            a) ACTION="${OPTARG}" ;;
            h)
                usage
                exit 0
                ;;
            :)
                die "Option -${OPTARG} requires an argument."
                ;;
            ?)
                die "Unknown option: -${OPTARG} (use -h for help)."
                ;;
        esac
    done

    if [[ -n "${USERNAME}" && -z "${PASSWORD}" ]] || [[ -z "${USERNAME}" && -n "${PASSWORD}" ]]; then
        die "Both -u and -p must be set together for password authentication."
    fi

    if ! [[ "${BASE_PORT}" =~ ^[0-9]+$ ]] || (( BASE_PORT < 1024 || BASE_PORT > 65500 )); then
        die "BASE_PORT must be a number between 1024 and 65500."
    fi

    case "${ACTION}" in
        start|stop|restart|status|prepare) ;;
        *) die "Invalid action '${ACTION}'. Use start, stop, restart, or status." ;;
    esac
}

apply_saved_value() {
    local name="$1"
    local value="$2"
    printf -v "${name}" '%s' "${value}"
}

load_settings_into_globals() {
    [[ -f "${SETTINGS_FILE}" ]] || return 1

    local BASE_PORT="" USERNAME="" PASSWORD=""
    # shellcheck disable=SC1090
    source "${SETTINGS_FILE}"

    if ! [[ "${BASE_PORT}" =~ ^[0-9]+$ ]] || (( BASE_PORT < 1024 || BASE_PORT > 65500 )); then
        die "Saved base port in ${SETTINGS_FILE} is invalid."
    fi

    apply_saved_value SAVED_BASE_PORT "${BASE_PORT}"
    apply_saved_value SAVED_USERNAME "${USERNAME}"
    apply_saved_value SAVED_PASSWORD "${PASSWORD}"
    apply_saved_value SETTINGS_LOADED 1
}

merge_saved_settings() {
    SETTINGS_LOADED=0
    SAVED_BASE_PORT=""
    SAVED_USERNAME=""
    SAVED_PASSWORD=""
    load_settings_into_globals || return 0

    if [[ "${BASE_PORT_SET}" -eq 0 ]]; then
        apply_saved_value BASE_PORT "${SAVED_BASE_PORT}"
    fi
    if [[ "${AUTH_SET}" -eq 0 ]]; then
        apply_saved_value USERNAME "${SAVED_USERNAME}"
        apply_saved_value PASSWORD "${SAVED_PASSWORD}"
    fi
}

load_settings_required() {
    merge_saved_settings
    if [[ "${SETTINGS_LOADED}" -ne 1 ]]; then
        die "Proxy is not set up yet. Start it once so it can come back after a reboot."
    fi
}

save_settings() {
    local tmp

    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"
    tmp="$(mktemp "${CONFIG_DIR}/settings.XXXXXX")"
    {
        printf 'BASE_PORT=%q\n' "${BASE_PORT}"
        printf 'USERNAME=%q\n' "${USERNAME}"
        printf 'PASSWORD=%q\n' "${PASSWORD}"
    } >"${tmp}"
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${SETTINGS_FILE}"
}

is_private_ipv4() {
    local ip="${1}"

    [[ "${ip}" =~ ^10\. ]] && return 0
    [[ "${ip}" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "${ip}" =~ ^192\.168\. ]] && return 0
    [[ "${ip}" =~ ^127\. ]] && return 0
    [[ "${ip}" =~ ^169\.254\. ]] && return 0
    [[ "${ip}" =~ ^0\. ]] && return 0
    [[ "${ip}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0  # CGNAT
    [[ "${ip}" =~ ^192\.0\.0\. ]] && return 0
    [[ "${ip}" =~ ^198\.1[89]\. ]] && return 0
    return 1
}

collect_public_ipv4s() {
    local -a ips=()
    local line ip

    if ! command -v ip >/dev/null 2>&1; then
        die "'ip' command not found. Install iproute2: apt-get install -y iproute2"
    fi

    while IFS= read -r line; do
        ip="${line%%/*}"
        if is_private_ipv4 "${ip}"; then
            continue
        fi
        ips+=("${ip}")
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | sort -u)

    if ((${#ips[@]} == 0)); then
        return 1
    fi

    printf '%s\n' "${ips[@]}"
}

detect_public_ipv4s() {
    local ips
    if ! ips="$(collect_public_ipv4s)"; then
        die "No public IPv4 addresses detected on this machine."
    fi
    printf '%s\n' "${ips}"
}

wait_for_public_ipv4s() {
    local attempt
    for attempt in $(seq 1 30); do
        if collect_public_ipv4s >/dev/null; then
            return 0
        fi
        log "No public IPv4 yet; waiting (${attempt}/30)..."
        sleep 1
    done
    die "No public IPv4 addresses detected on this machine."
}

ensure_3proxy() {
    if command -v 3proxy >/dev/null 2>&1; then
        return 0
    fi

    log "3proxy not found; attempting installation..."

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        if apt-get install -y 3proxy 2>/dev/null; then
            command -v 3proxy >/dev/null 2>&1 && return 0
        fi

        log "Package '3proxy' not available; building from source..."
        apt-get install -y build-essential git ca-certificates

        local build_dir
        build_dir="$(mktemp -d /tmp/3proxy-build.XXXXXX)"
        trap 'rm -rf "${build_dir}"' RETURN

        git clone --depth 1 https://github.com/z3APA3A/3proxy.git "${build_dir}/3proxy"
        make -C "${build_dir}/3proxy" -f Makefile.Linux
        install -m 0755 "${build_dir}/3proxy/bin/3proxy" /usr/local/bin/3proxy
        log "Installed 3proxy to /usr/local/bin/3proxy"
        trap - RETURN
        rm -rf "${build_dir}"
        return 0
    fi

    die "Could not install 3proxy. Install it manually and re-run this script."
}

is_ipv4() {
    local ip="${1}" octet

    [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        (( 10#${octet} <= 255 )) || return 1
    done
}

read_ip_list_addresses() {
    local raw ip

    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        raw="${raw%%#*}"
        raw="${raw//$'\r'/}"
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        [[ -z "${raw}" ]] && continue
        ip="${raw%%[[:space:]]*}"
        if ! is_ipv4 "${ip}"; then
            log "Ignoring invalid address in ${IP_LIST_FILE}: ${ip}"
            continue
        fi
        printf '%s\n' "${ip}"
    done <"${IP_LIST_FILE}"
}

fill_proxy_ips() {
    local -a detected=() listed=() chosen=()
    local -A on_host=()
    local ip listed_ip

    mapfile -t detected < <(detect_public_ipv4s)
    if ((${#detected[@]} == 0)); then
        die "No public IPv4 addresses detected on this machine."
    fi

    unset PROXY_PORT_INDEX
    declare -gA PROXY_PORT_INDEX=()
    local i
    for i in "${!detected[@]}"; do
        PROXY_PORT_INDEX["${detected[$i]}"]="${i}"
        on_host["${detected[$i]}"]=1
    done

    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"

    if [[ ! -f "${IP_LIST_FILE}" ]]; then
        printf '%s\n' "${detected[@]}" >"${IP_LIST_FILE}"
        chmod 644 "${IP_LIST_FILE}"
        PROXY_IPS=("${detected[@]}")
        log "Saved ${#PROXY_IPS[@]} address(es) to ${IP_LIST_FILE}"
        return 0
    fi

    mapfile -t listed < <(read_ip_list_addresses)
    local -A allow=()
    for listed_ip in "${listed[@]+"${listed[@]}"}"; do
        [[ -n "${listed_ip}" ]] || continue
        allow["${listed_ip}"]=1
    done

    for ip in "${detected[@]}"; do
        if [[ -n "${allow[${ip}]:-}" ]]; then
            chosen+=("${ip}")
        fi
    done

    if ((${#allow[@]} > 0)); then
        for listed_ip in "${!allow[@]}"; do
            if [[ -z "${on_host[${listed_ip}]:-}" ]]; then
                log "Skipping ${listed_ip}; it is not a public address on this machine."
            fi
        done
    fi

    if ((${#chosen[@]} == 0)); then
        die "No addresses in ${IP_LIST_FILE} match a public IPv4 on this machine."
    fi

    PROXY_IPS=("${chosen[@]}")
    log "Using ${#PROXY_IPS[@]} address(es) from ${IP_LIST_FILE}"
}

generate_config() {
    local ip port

    fill_proxy_ips

    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"
    : >"${MAP_FILE}"

    {
        echo "# Generated by ${SCRIPT_NAME} on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "pidfile ${PID_FILE}"
        echo "log ${LOG_FILE}"
        echo 'logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"'
        echo "rotate 30"
        echo "maxconn 500"
        echo

        if [[ -n "${USERNAME}" && -n "${PASSWORD}" ]]; then
            # CL = cleartext local password (3proxy compares directly)
            echo "users ${USERNAME}:CL:${PASSWORD}"
            echo "auth strong"
            echo "flush"
            echo "allow ${USERNAME}"
        else
            echo "auth none"
        fi
        echo

        for ip in "${PROXY_IPS[@]}"; do
            port=$((BASE_PORT + PROXY_PORT_INDEX[${ip}]))
            echo "proxy -p${port} -e${ip}"
            echo "${ip}:${port}" >>"${MAP_FILE}"
        done
    } >"${CONFIG_FILE}"

    chmod 600 "${CONFIG_FILE}"

    log "Wrote config: ${CONFIG_FILE}"
}

install_service() {
    local proxy_bin

    if [[ ! -f "$0" ]]; then
        die "Run the downloaded script file directly. Do not pipe it into bash."
    fi

    proxy_bin="$(command -v 3proxy)"
    if [[ -z "${proxy_bin}" ]]; then
        die "3proxy was not found after installation."
    fi

    install -m 0755 -- "$0" "${INSTALL_PATH}"

    cat >"${UNIT_FILE}" <<EOF
[Unit]
Description=IPv4 proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${INSTALL_PATH} -a prepare
ExecStart=${proxy_bin} ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${UNIT_FILE}"
    systemctl daemon-reload
}

service_is_active() {
    systemctl is-active --quiet "${UNIT_NAME}"
}

service_is_enabled() {
    [[ -f "${UNIT_FILE}" ]] && systemctl is-enabled --quiet "${UNIT_NAME}"
}

is_running() {
    [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

stop_process() {
    if is_running; then
        local pid
        pid="$(cat "${PID_FILE}")"
        log "Stopping 3proxy (PID ${pid})..."
        kill "${pid}" 2>/dev/null || true

        local i
        for i in $(seq 1 20); do
            if ! kill -0 "${pid}" 2>/dev/null; then
                rm -f "${PID_FILE}"
                log "Stopped."
                return 0
            fi
            sleep 0.25
        done

        log "Force killing 3proxy..."
        kill -9 "${pid}" 2>/dev/null || true
        rm -f "${PID_FILE}"
    else
        log "3proxy is not running."
    fi
}

start_failure() {
    die "Failed to start. Check ${LOG_FILE} or run: journalctl -u ${UNIT_NAME} -n 50 --no-pager"
}

prepare_config() {
    load_settings_required
    wait_for_public_ipv4s
    generate_config
}

start_service() {
    require_systemd
    merge_saved_settings
    save_settings
    ensure_3proxy
    install_service

    if service_is_active; then
        die "Already running. Use -a restart or -a stop first."
    fi

    if is_running; then
        stop_process
    fi

    systemctl enable "${UNIT_NAME}" >/dev/null
    if ! systemctl start "${UNIT_NAME}"; then
        start_failure
    fi

    print_proxy_map
}

restart_service() {
    require_systemd
    merge_saved_settings
    save_settings
    ensure_3proxy
    install_service

    if is_running && ! service_is_active; then
        stop_process
    fi

    systemctl enable "${UNIT_NAME}" >/dev/null
    if ! systemctl restart "${UNIT_NAME}"; then
        start_failure
    fi

    print_proxy_map
}

stop_service() {
    require_systemd
    local comes_back=0

    if service_is_enabled; then
        comes_back=1
    fi

    if [[ -f "${UNIT_FILE}" ]]; then
        systemctl stop "${UNIT_NAME}" || true
    fi

    if is_running; then
        stop_process
    elif [[ "${comes_back}" -eq 0 ]]; then
        log "3proxy is not running."
    fi

    if [[ "${comes_back}" -eq 1 ]]; then
        log "Stopped for now. It will start again when this machine restarts."
    fi
}

print_proxy_map() {
    local ip port pid
    local auth_prefix=""

    if [[ -n "${USERNAME}" && -n "${PASSWORD}" ]]; then
        auth_prefix="${USERNAME}:${PASSWORD}@"
    fi

    pid="$(systemctl show -p MainPID --value "${UNIT_NAME}" 2>/dev/null || true)"
    if [[ -z "${pid}" || "${pid}" == "0" ]]; then
        pid="unknown"
    fi

    echo
    echo "HTTP proxies ready (one outbound IPv4 per port):"
    echo "------------------------------------------------"

    while IFS=: read -r ip port; do
        printf '  %-15s  http://%s%s:%s\n' "${ip}" "${auth_prefix}" "${ip}" "${port}"
    done <"${MAP_FILE}"

    echo
    echo "Config : ${CONFIG_FILE}"
    echo "IP list: ${IP_LIST_FILE}"
    echo "Log    : ${LOG_FILE}"
    echo "PID    : ${pid}"
    echo "These proxies start again when the machine restarts."
    echo "Delete an address from the IP list, then restart, to stop using it."
    echo
}

show_status() {
    require_systemd
    local pid

    if service_is_active; then
        pid="$(systemctl show -p MainPID --value "${UNIT_NAME}" 2>/dev/null || true)"
        echo "Status : running (PID ${pid})"
    else
        echo "Status : not running"
    fi

    if service_is_enabled; then
        echo "After reboot : starts automatically"
    else
        echo "After reboot : will not start until you set it up"
    fi

    if [[ -f "${IP_LIST_FILE}" ]]; then
        echo "IP list : ${IP_LIST_FILE}"
    fi

    if [[ -f "${MAP_FILE}" ]]; then
        echo
        echo "Proxy map:"
        cat "${MAP_FILE}" | while IFS=: read -r ip port; do
            printf '  %-15s  port %s\n' "${ip}" "${port}"
        done
    fi
}

main() {
    parse_args "$@"
    require_root

    case "${ACTION}" in
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            restart_service
            ;;
        status)
            show_status
            ;;
        prepare)
            prepare_config
            ;;
    esac
}

main "$@"
