#!/usr/bin/env bash
#
# ipv4-proxy-server.sh — HTTP proxy with one port per public IPv4 (outbound binding)
#
# Usage:
#   ./ipv4-proxy-server.sh [-u USER] [-p PASS] [-b BASE_PORT] [-a|--action start|stop|restart|status]
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
readonly PID_FILE="/var/run/ipv4-proxy-server.pid"
readonly LOG_FILE="/var/log/ipv4-proxy-server.log"
readonly MAP_FILE="${CONFIG_DIR}/proxy-map.txt"

BASE_PORT=30000
USERNAME=""
PASSWORD=""
ACTION="start"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Automatically detect public IPv4 addresses on this host and start an HTTP
proxy listener on each one. Each proxy binds outbound traffic to its IPv4.

Options:
  -u USER          Proxy username (requires -p for authentication)
  -p PASS          Proxy password (requires -u for authentication)
  -b BASE_PORT     First port to use (default: ${BASE_PORT})
  -a ACTION        start | stop | restart | status (default: start)
  -h               Show this help

Examples:
  ${SCRIPT_NAME} -u pxuser -p your-password
  ${SCRIPT_NAME} -b 20000
  ${SCRIPT_NAME} -a stop

When -u and -p are both provided, password authentication is enabled.
Otherwise proxies accept connections without authentication.
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

parse_args() {
    while getopts ":u:p:b:a:h" opt; do
        case "${opt}" in
            u) USERNAME="${OPTARG}" ;;
            p) PASSWORD="${OPTARG}" ;;
            b) BASE_PORT="${OPTARG}" ;;
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
        start|stop|restart|status) ;;
        *) die "Invalid action '${ACTION}'. Use start, stop, restart, or status." ;;
    esac
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

detect_public_ipv4s() {
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
        die "No public IPv4 addresses detected on this machine."
    fi

    printf '%s\n' "${ips[@]}"
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

generate_config() {
    local -a ips=()
    local ip port
    local port_offset=0

    mapfile -t ips < <(detect_public_ipv4s)

    mkdir -p "${CONFIG_DIR}"
    : >"${MAP_FILE}"

    {
        echo "# Generated by ${SCRIPT_NAME} on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "daemon"
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

        for ip in "${ips[@]}"; do
            port=$((BASE_PORT + port_offset))
            echo "proxy -p${port} -e${ip}"
            echo "${ip}:${port}" >>"${MAP_FILE}"
            port_offset=$((port_offset + 1))
        done
    } >"${CONFIG_FILE}"

    log "Wrote config: ${CONFIG_FILE}"
    log "Detected ${#ips[@]} public IPv4 address(es), ports ${BASE_PORT}-$((BASE_PORT + ${#ips[@]} - 1))"
}

is_running() {
    [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

stop_server() {
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

start_server() {
    if is_running; then
        die "3proxy is already running (PID $(cat "${PID_FILE}")). Use -a restart or -a stop first."
    fi

    ensure_3proxy
    generate_config

    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}"

    log "Starting 3proxy..."
    3proxy "${CONFIG_FILE}"

    sleep 0.5
    if ! is_running; then
        die "3proxy failed to start. Check ${LOG_FILE} for details."
    fi

    print_proxy_map
}

print_proxy_map() {
    local ip port
    local auth_prefix=""

    if [[ -n "${USERNAME}" && -n "${PASSWORD}" ]]; then
        auth_prefix="${USERNAME}:${PASSWORD}@"
    fi

    echo
    echo "HTTP proxies ready (one outbound IPv4 per port):"
    echo "------------------------------------------------"

    while IFS=: read -r ip port; do
        printf '  %-15s  http://%s%s:%s\n' "${ip}" "${auth_prefix}" "${ip}" "${port}"
    done <"${MAP_FILE}"

    echo
    echo "Config : ${CONFIG_FILE}"
    echo "Log    : ${LOG_FILE}"
    echo "PID    : $(cat "${PID_FILE}")"
    echo
}

show_status() {
    if is_running; then
        echo "Status : running (PID $(cat "${PID_FILE}"))"
        if [[ -f "${MAP_FILE}" ]]; then
            echo
            echo "Active proxy map:"
            cat "${MAP_FILE}" | while IFS=: read -r ip port; do
                printf '  %-15s  port %s\n' "${ip}" "${port}"
            done
        fi
    else
        echo "Status : not running"
    fi
}

main() {
    parse_args "$@"
    require_root

    case "${ACTION}" in
        start)
            start_server
            ;;
        stop)
            stop_server
            ;;
        restart)
            stop_server
            start_server
            ;;
        status)
            show_status
            ;;
    esac
}

main "$@"
