#!/bin/sh

set -eu
umask 077

APP_VERSION='0.2.0'
SING_BOX_SERIES='1.13'
ALPINE_EDGE_COMMUNITY='https://dl-cdn.alpinelinux.org/alpine/edge/community'
DEFAULT_SNI='addons.mozilla.org'
DEFAULT_VLESS_PORT='443'
DEFAULT_HY2_PORT='8443'
DEFAULT_NODE_NAME='singbox-alpine-lite'

WORK_DIR='/etc/sing-box'
APP_DIR='/usr/local/libexec/singbox-alpine-lite'
BINARY_PATH='/usr/bin/sing-box'
CONFIG_FILE="${WORK_DIR}/config.json"
STATE_FILE="${WORK_DIR}/state.env"
OWNER_FILE="${WORK_DIR}/owner.env"
LINKS_FILE="${WORK_DIR}/links.txt"
SERVICE_FILE='/etc/init.d/sing-box'
MANAGE_FILE="${APP_DIR}/manage.sh"
FIREWALL_FILE="${APP_DIR}/firewall.sh"
APK_REPOSITORIES_FILE="${APP_DIR}/repositories"
VERIFY_PIPE="${APP_DIR}/package.verify.pipe"
STAGED_BINARY="${BINARY_PATH}.new"

PROTOCOLS_RAW=''
VLESS_PORT=''
HY2_PORT=''
HY2_PORT_EXPLICIT=0
HY2_HOP_RANGE=''
HOP_IPTABLES_RANGE=''
HOP_CLIENT_RANGE=''
SNI=''
SERVER=''
NODE_NAME=''
DRY_RUN=0
INTERACTIVE=0
PORT_HOPPING_FALLBACK=0
SUPERVISOR_MODE='start-stop-daemon'

if [ -t 0 ]; then
    INTERACTIVE=1
fi

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

disable_hopping() {
    HY2_HOP_RANGE=''
    HOP_IPTABLES_RANGE=''
    HOP_CLIENT_RANGE=''
}

warn_about_hopping() {
    [ -n "$HY2_HOP_RANGE" ] || return 0
    warn 'Hysteria2 port hopping needs the complete UDP range forwarded to this host.'
    warn 'A host-side iptables rule cannot create missing port mappings on an upstream NAT VPS.'
    warn 'The installer will fall back to the single Hysteria2 port if the range rule cannot be installed.'
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

usage() {
    cat <<'EOF'
singbox-alpine-lite installer

Usage:
  install.sh [options]

Options:
  --protocols VALUE       vless, hy2, or both (default: both)
  --vless-port PORT       VLESS Reality TCP port (default: 443)
  --hy2-port PORT         Hysteria2 UDP port (default: 8443); with hopping,
                          it must equal the range start/fallback port
  --hy2-port-range RANGE  Optional UDP hopping range, e.g. 20000:30000;
                          the first port is the listen/fallback port
  --sni DOMAIN            Reality/TLS server name (default: addons.mozilla.org)
  --server HOST           Public IPv4, IPv6, or hostname used in node links
  --name NAME             Node name; letters, digits, dot, underscore, hyphen
  --dry-run               Validate and print resolved settings without changes
  --help                  Show this help

The installer is intentionally limited to Alpine Linux. It installs the
maintained Alpine edge/community package, one process, and one OpenRC service.
EOF
}

require_argument() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --protocols)
            require_argument "$@"
            PROTOCOLS_RAW=$2
            shift 2
            ;;
        --vless-port)
            require_argument "$@"
            VLESS_PORT=$2
            shift 2
            ;;
        --hy2-port)
            require_argument "$@"
            HY2_PORT=$2
            HY2_PORT_EXPLICIT=1
            shift 2
            ;;
        --hy2-port-range)
            require_argument "$@"
            HY2_HOP_RANGE=$2
            shift 2
            ;;
        --sni)
            require_argument "$@"
            SNI=$2
            shift 2
            ;;
        --server)
            require_argument "$@"
            SERVER=$2
            shift 2
            ;;
        --name)
            require_argument "$@"
            NODE_NAME=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

if [ -z "$PROTOCOLS_RAW" ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
        printf '%s\n' 'Choose protocols:'
        printf '%s\n' '  1) VLESS Reality'
        printf '%s\n' '  2) Hysteria2'
        printf '%s\n' '  3) Both (default)'
        printf 'Selection [3]: '
        read -r PROTOCOLS_RAW || true
        PROTOCOLS_RAW=${PROTOCOLS_RAW:-3}
    else
        PROTOCOLS_RAW='both'
    fi
fi

VLESS_ENABLED=0
HY2_ENABLED=0
case "$(printf '%s' "$PROTOCOLS_RAW" | tr '[:upper:]' '[:lower:]')" in
    vless|b|1)
        VLESS_ENABLED=1
        PROTOCOLS='vless'
        ;;
    hy2|hysteria2|c|2)
        HY2_ENABLED=1
        PROTOCOLS='hy2'
        ;;
    both|bc|vless,hy2|vless+hy2|3)
        VLESS_ENABLED=1
        HY2_ENABLED=1
        PROTOCOLS='both'
        ;;
    *)
        die "Invalid protocols value: $PROTOCOLS_RAW"
        ;;
esac

is_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

prompt_port() {
    label=$1
    default=$2
    current=$3
    if [ -n "$current" ]; then
        return
    fi
    if [ "$INTERACTIVE" -eq 1 ]; then
        printf '%s [%s]: ' "$label" "$default"
        read -r current || true
        current=${current:-$default}
    else
        current=$default
    fi
    case "$label" in
        VLESS*) VLESS_PORT=$current ;;
        Hysteria2*) HY2_PORT=$current ;;
    esac
}

if [ "$VLESS_ENABLED" -eq 1 ]; then
    prompt_port 'VLESS Reality TCP port' "$DEFAULT_VLESS_PORT" "$VLESS_PORT"
fi
if [ "$HY2_ENABLED" -eq 1 ]; then
    prompt_port 'Hysteria2 UDP port' "$DEFAULT_HY2_PORT" "$HY2_PORT"
fi

[ "$VLESS_ENABLED" -eq 0 ] || is_port "$VLESS_PORT" || die "Invalid VLESS port: $VLESS_PORT"
[ "$HY2_ENABLED" -eq 0 ] || is_port "$HY2_PORT" || die "Invalid Hysteria2 port: $HY2_PORT"

if [ "$HY2_ENABLED" -eq 1 ]; then
    if [ -z "$HY2_HOP_RANGE" ] && [ "$INTERACTIVE" -eq 1 ]; then
        printf 'Hysteria2 port hopping range (empty to disable): '
        read -r HY2_HOP_RANGE || true
    fi
    case "$HY2_HOP_RANGE" in
        ''|none|disabled)
            HY2_HOP_RANGE=''
            ;;
        *)
            HY2_HOP_RANGE=$(printf '%s' "$HY2_HOP_RANGE" | tr ':' '-')
            HOP_START=${HY2_HOP_RANGE%-*}
            HOP_END=${HY2_HOP_RANGE#*-}
            is_port "$HOP_START" || die 'Invalid Hysteria2 hopping range start'
            is_port "$HOP_END" || die 'Invalid Hysteria2 hopping range end'
            [ "$HOP_START" -lt "$HOP_END" ] || die 'Hysteria2 hopping range must be ascending'
            if [ "$HY2_PORT_EXPLICIT" -eq 1 ] && [ "$HY2_PORT" -ne "$HOP_START" ]; then
                die "When hopping is enabled, --hy2-port must equal the range start (${HOP_START})"
            fi
            if [ "$HY2_PORT" -ne "$HOP_START" ]; then
                info "Using Hysteria2 range start ${HOP_START} as the listen/fallback port."
            fi
            HY2_PORT=$HOP_START
            HOP_FORWARD_START=$((HOP_START + 1))
            if [ "$HOP_FORWARD_START" -eq "$HOP_END" ]; then
                HOP_IPTABLES_RANGE=$HOP_END
            else
                HOP_IPTABLES_RANGE="${HOP_FORWARD_START}:${HOP_END}"
            fi
            HOP_CLIENT_RANGE="${HOP_START}-${HOP_END}"
            ;;
    esac
else
    [ -z "$HY2_HOP_RANGE" ] || die 'Hysteria2 hopping requires the Hysteria2 protocol'
fi

[ "$VLESS_ENABLED" -eq 0 ] || [ "$HY2_ENABLED" -eq 0 ] || [ "$VLESS_PORT" -ne "$HY2_PORT" ] || die 'VLESS and Hysteria2 ports must differ'

if [ -z "$SNI" ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
        printf 'SNI / Reality handshake domain [%s]: ' "$DEFAULT_SNI"
        read -r SNI || true
        SNI=${SNI:-$DEFAULT_SNI}
    else
        SNI=$DEFAULT_SNI
    fi
fi
printf '%s' "$SNI" | grep -Eq '^[A-Za-z0-9.-]+$' || die 'SNI must be a domain name'

if [ -z "$NODE_NAME" ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
        printf 'Node name [%s]: ' "$DEFAULT_NODE_NAME"
        read -r NODE_NAME || true
        NODE_NAME=${NODE_NAME:-$DEFAULT_NODE_NAME}
    else
        NODE_NAME=$DEFAULT_NODE_NAME
    fi
fi
printf '%s' "$NODE_NAME" | grep -Eq '^[A-Za-z0-9._-]+$' || die 'Node name contains unsupported characters'

fetch_public_address() {
    if has_command curl; then
        curl -fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null && return 0
    fi
    if has_command wget; then
        wget --no-check-certificate -qO- --timeout=10 https://api.ipify.org 2>/dev/null && return 0
    fi
    return 1
}

if [ -z "$SERVER" ]; then
    detected_server=$(fetch_public_address || true)
    if [ "$INTERACTIVE" -eq 1 ]; then
        printf 'Public server address [%s]: ' "${detected_server:-unknown}"
        read -r SERVER || true
        SERVER=${SERVER:-$detected_server}
    else
        SERVER=$detected_server
    fi
fi
[ -n "$SERVER" ] || die 'Cannot detect the public server address; use --server'
printf '%s' "$SERVER" | grep -Eq '^[A-Za-z0-9.:-]+$' || die 'Server address contains unsupported characters'

warn_about_hopping

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' 'Resolved settings:'
    printf '  Protocols: %s\n' "$PROTOCOLS"
    [ "$VLESS_ENABLED" -eq 0 ] || printf '  VLESS port: %s\n' "$VLESS_PORT"
    [ "$HY2_ENABLED" -eq 0 ] || printf '  Hysteria2 port: %s\n' "$HY2_PORT"
    if [ -n "$HY2_HOP_RANGE" ]; then
        printf '  Hysteria2 hopping range: %s\n' "$HOP_CLIENT_RANGE"
    else
        printf '%s\n' '  Hysteria2 hopping: disabled'
    fi
    if [ -n "$HY2_HOP_RANGE" ]; then
        printf '%s\n' '  Warning: provider-side UDP forwarding for the full range is required.'
    fi
    printf '  SNI: %s\n' "$SNI"
    printf '  Server: %s\n' "$SERVER"
    printf '  Node name: %s\n' "$NODE_NAME"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die 'Run this installer as root'
[ -f /etc/alpine-release ] || die 'This installer supports Alpine Linux only'
has_command rc-service || die 'OpenRC is required'
has_command rc-update || die 'OpenRC is required'
has_command apk || die 'Alpine apk is required'
has_command wget || has_command curl || die 'wget or curl is required'

[ ! -e "$STATE_FILE" ] || die "Already installed: $STATE_FILE (do not overwrite existing credentials)"
if [ -e "$CONFIG_FILE" ] && [ ! -e "$OWNER_FILE" ]; then
    die "Existing configuration found: $CONFIG_FILE (do not overwrite it)"
fi

mkdir -p "$WORK_DIR" "$APP_DIR"
if [ ! -e "$OWNER_FILE" ]; then
    printf '%s\n' "APP='singbox-alpine-lite'" > "$OWNER_FILE"
    chmod 0600 "$OWNER_FILE"
fi

if [ "$HY2_ENABLED" -eq 1 ] && ! has_command openssl; then
    info 'Installing openssl for Hysteria2 certificate generation...'
    apk add --no-cache openssl || die 'Failed to install openssl'
fi
if [ "$HY2_ENABLED" -eq 1 ]; then
    has_command openssl || die 'openssl is required for Hysteria2'
fi

if has_command supervise-daemon; then
    SUPERVISOR_MODE='supervise-daemon'
    info 'OpenRC supervise-daemon detected; limited crash restart will be enabled.'
else
    warn 'OpenRC supervise-daemon is unavailable; continuing without crash restart.'
fi

if [ -n "$HY2_HOP_RANGE" ] && ! has_command iptables; then
    info 'Installing iptables for Hysteria2 port hopping...'
    if ! apk add --no-cache iptables; then
        warn 'iptables installation failed; continuing with single-port Hysteria2.'
        disable_hopping
        PORT_HOPPING_FALLBACK=1
    fi
fi
if [ -n "$HY2_HOP_RANGE" ] && ! has_command iptables; then
    warn 'iptables is unavailable; continuing with single-port Hysteria2.'
    disable_hopping
    PORT_HOPPING_FALLBACK=1
fi
if [ -n "$HY2_HOP_RANGE" ] && ! has_command ip6tables; then
    warn 'ip6tables is unavailable; IPv6 port hopping will not work.'
fi

info "Resolving sing-box ${SING_BOX_SERIES}.x from Alpine edge/community..."
cat /etc/apk/repositories > "$APK_REPOSITORIES_FILE"
printf '%s\n' "$ALPINE_EDGE_COMMUNITY" >> "$APK_REPOSITORIES_FILE"
apk --repositories-file "$APK_REPOSITORIES_FILE" update || die 'Failed to update Alpine repository indexes'

package_version=$(apk --repositories-file "$APK_REPOSITORIES_FILE" query --fields version sing-box |
    awk '/^Version: /{print $2; exit}')
case "$package_version" in
    "${SING_BOX_SERIES}."*-r*) ;;
    *) die "Alpine edge/community did not provide sing-box ${SING_BOX_SERIES}.x" ;;
esac

package_url="${ALPINE_EDGE_COMMUNITY}/$(apk --print-arch)/sing-box-${package_version}.apk"

info "Downloading Alpine sing-box ${package_version} package..."
if [ ! -p "$VERIFY_PIPE" ]; then
    [ ! -e "$VERIFY_PIPE" ] || die "Verification pipe path is occupied: $VERIFY_PIPE"
    mkfifo "$VERIFY_PIPE"
fi

apk verify "$VERIFY_PIPE" &
verify_pid=$!
stream_result=0
if has_command wget; then
    wget -qO- "$package_url" |
        tee "$VERIFY_PIPE" |
        tar -xzOf - usr/bin/sing-box > "$STAGED_BINARY" || stream_result=$?
else
    curl -fsSL "$package_url" |
        tee "$VERIFY_PIPE" |
        tar -xzOf - usr/bin/sing-box > "$STAGED_BINARY" || stream_result=$?
fi
verify_result=0
wait "$verify_pid" || verify_result=$?
[ "$stream_result" -eq 0 ] || die 'Failed to download or extract the Alpine sing-box package'
[ "$verify_result" -eq 0 ] || die 'Alpine package signature or integrity verification failed'
[ -s "$STAGED_BINARY" ] || die 'The Alpine package did not provide a sing-box binary'

info 'Installing the verified sing-box binary...'
chmod 0755 "$STAGED_BINARY"
mv "$STAGED_BINARY" "$BINARY_PATH"
has_command sing-box || die 'The Alpine sing-box binary was not installed'

binary_version=$($BINARY_PATH version 2>&1 | sed -n '1p') || die 'sing-box binary cannot execute'
SING_BOX_VERSION=$(printf '%s\n' "$binary_version" | awk '/^sing-box version /{print $3; exit}')
case "$SING_BOX_VERSION" in
    "${SING_BOX_SERIES}."*) ;;
    *) die "Unexpected sing-box version: $binary_version" ;;
esac

UUID=''
REALITY_PRIVATE=''
REALITY_PUBLIC=''
HY2_PASSWORD=''

if [ "$VLESS_ENABLED" -eq 1 ]; then
    keypair=$($BINARY_PATH generate reality-keypair 2>/dev/null) || die 'Failed to generate Reality keypair'
    REALITY_PRIVATE=$(printf '%s\n' "$keypair" | awk -F ': ' '/^PrivateKey:/{print $2}')
    REALITY_PUBLIC=$(printf '%s\n' "$keypair" | awk -F ': ' '/^PublicKey:/{print $2}')
    UUID=$(cat /proc/sys/kernel/random/uuid)
    [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] && [ -n "$UUID" ] || die 'Failed to generate VLESS credentials'
fi

if [ "$HY2_ENABLED" -eq 1 ]; then
    HY2_PASSWORD=$(openssl rand -hex 16)
    [ -n "$HY2_PASSWORD" ] || die 'Failed to generate Hysteria2 password'
fi

if [ "$HY2_ENABLED" -eq 1 ]; then
    info 'Generating self-signed certificate for Hysteria2...'
    openssl ecparam -name prime256v1 -genkey -noout -out "${WORK_DIR}/hy2.key"
    openssl req -x509 -new -sha256 -days 3650 \
        -key "${WORK_DIR}/hy2.key" \
        -subj "/CN=${SNI}" \
        -out "${WORK_DIR}/hy2.crt" 2>/dev/null
    chmod 0600 "${WORK_DIR}/hy2.key"
    chmod 0644 "${WORK_DIR}/hy2.crt"
fi

config_tmp="${WORK_DIR}/config.json.new"
{
    printf '%s\n' '{'
    printf '%s\n' '  "log": {'
    printf '%s\n' '    "level": "warn",'
    printf '    "output": "%s"\n' "${WORK_DIR}/sing-box.log"
    printf '%s\n' '  },'
    printf '%s\n' '  "inbounds": ['
    first_inbound=1

    if [ "$VLESS_ENABLED" -eq 1 ]; then
        [ "$first_inbound" -eq 1 ] || printf '%s\n' ','
        cat <<EOF
    {
      "type": "vless",
      "tag": "${NODE_NAME}-vless",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE}",
          "short_id": [
            ""
          ]
        }
      }
    }
EOF
        first_inbound=0
    fi

    if [ "$HY2_ENABLED" -eq 1 ]; then
        [ "$first_inbound" -eq 1 ] || printf '%s\n' ','
        cat <<EOF
    {
      "type": "hysteria2",
      "tag": "${NODE_NAME}-hysteria2",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HY2_PASSWORD}"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "${WORK_DIR}/hy2.crt",
        "key_path": "${WORK_DIR}/hy2.key"
      }
    }
EOF
    fi

    printf '%s\n' '  ],'
    printf '%s\n' '  "outbounds": ['
    printf '%s\n' '    {'
    printf '%s\n' '      "type": "direct",'
    printf '%s\n' '      "tag": "direct"'
    printf '%s\n' '    }'
    printf '%s\n' '  ]'
    printf '%s\n' '}'
} > "$config_tmp"
mv "$config_tmp" "$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

printf '%s\n' 'Generated configuration:'
$BINARY_PATH check -c "$CONFIG_FILE"

write_firewall() {
    printf '%s\n' '#!/bin/sh' 'set -eu' "HY2_PORT='${HY2_PORT:-}'" "HOP_RANGE='${HOP_IPTABLES_RANGE:-}'" > "$FIREWALL_FILE"
    cat <<'EOF' >> "$FIREWALL_FILE"

add_rule() {
    [ -n "$HOP_RANGE" ] || return 0
    IPTABLES=$(command -v iptables 2>/dev/null) || {
        printf '%s\n' 'iptables is required for Hysteria2 port hopping' >&2
        return 1
    }
    "$IPTABLES" -t nat -C PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null ||
        "$IPTABLES" -t nat -A PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$HY2_PORT"
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -C PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null ||
            ip6tables -t nat -A PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$HY2_PORT"
    else
        printf '%s\n' 'Warning: ip6tables is unavailable; IPv6 port hopping is disabled.' >&2
    fi
}

remove_rule() {
    [ -n "$HOP_RANGE" ] || return 0
    if command -v iptables >/dev/null 2>&1; then
        while iptables -t nat -C PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; do
            iptables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$HY2_PORT"
        done
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -t nat -C PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; do
            ip6tables -t nat -D PREROUTING -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$HY2_PORT"
        done
    fi
}

case "${1:-add}" in
    add) add_rule ;;
    remove) remove_rule ;;
    *) printf 'Usage: %s {add|remove}\n' "$0" >&2; exit 2 ;;
esac
EOF
    chmod 0755 "$FIREWALL_FILE"
}

write_firewall

if [ -x "$SERVICE_FILE" ]; then
    rc-service sing-box stop >/dev/null 2>&1 || true
fi

cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box VLESS Reality and Hysteria2 service"
command="${BINARY_PATH}"
EOF

if [ "$SUPERVISOR_MODE" = 'supervise-daemon' ]; then
    cat >> "$SERVICE_FILE" <<EOF
supervisor="supervise-daemon"
command_args_foreground="run -c ${CONFIG_FILE}"
pidfile="/run/sing-box.pid"
output_log="${WORK_DIR}/sing-box.log"
error_log="${WORK_DIR}/sing-box.log"
respawn_delay=10
respawn_max=3
respawn_period=60
EOF
else
    cat >> "$SERVICE_FILE" <<EOF
command_args="run -c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="${WORK_DIR}/sing-box.log"
error_log="${WORK_DIR}/sing-box.log"
EOF
fi

cat >> "$SERVICE_FILE" <<EOF

depend() {
    need net
    after net
}

start_pre() {
    mkdir -p "${WORK_DIR}"
    "${FIREWALL_FILE}" add
}

stop_post() {
    "${FIREWALL_FILE}" remove || true
}
EOF
chmod 0755 "$SERVICE_FILE"

write_links() {
    URI_SERVER=$SERVER
    case "$URI_SERVER" in
        *:*) URI_SERVER="[${URI_SERVER}]" ;;
    esac

    links_tmp="${WORK_DIR}/links.txt.new"
    {
        printf '%s\n' "singbox-alpine-lite ${APP_VERSION}"
        printf '%s\n' "Server: ${SERVER}"
        printf '%s\n' "SNI: ${SNI}"
        printf '%s\n' ''
        if [ "$VLESS_ENABLED" -eq 1 ]; then
            printf 'VLESS Reality:\nvless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&type=tcp&headerType=none#%s-vless\n\n' \
                "$UUID" "$URI_SERVER" "$VLESS_PORT" "$SNI" "$REALITY_PUBLIC" "$NODE_NAME"
        fi
        if [ "$HY2_ENABLED" -eq 1 ]; then
            hy2_uri_port=$HY2_PORT
            if [ -n "$HY2_HOP_RANGE" ]; then
                hy2_uri_port=$HOP_CLIENT_RANGE
            fi
            printf 'Hysteria2:\nhysteria2://%s@%s:%s/?sni=%s&insecure=1&alpn=h3#%s-hysteria2\n' \
                "$HY2_PASSWORD" "$URI_SERVER" "$hy2_uri_port" "$SNI" "$NODE_NAME"
        fi
    } > "$links_tmp"
    mv "$links_tmp" "$LINKS_FILE"
    chmod 0600 "$LINKS_FILE"
}

write_manage() {
    cat > "$MANAGE_FILE" <<EOF
#!/bin/sh

APP_VERSION='${APP_VERSION}'
PROTOCOLS='${PROTOCOLS}'
VLESS_PORT='${VLESS_PORT:-}'
HY2_PORT='${HY2_PORT:-}'
HY2_HOP_RANGE='${HY2_HOP_RANGE:-}'
LINKS_FILE='${LINKS_FILE}'
BINARY_PATH='${BINARY_PATH}'

show_info() {
    printf '%s\n' "singbox-alpine-lite \$APP_VERSION"
    printf 'Installed protocols: %s\n' "\$PROTOCOLS"
    [ -z "\$VLESS_PORT" ] || printf 'VLESS Reality TCP port: %s\n' "\$VLESS_PORT"
    if [ -n "\$HY2_PORT" ]; then
        printf 'Hysteria2 UDP port: %s\n' "\$HY2_PORT"
        if [ -n "\$HY2_HOP_RANGE" ]; then
            printf 'Hysteria2 port hopping: %s\n' "\$HY2_HOP_RANGE"
        else
            printf '%s\n' 'Hysteria2 port hopping: disabled'
        fi
    fi
}

show_nodes() {
    cat "\$LINKS_FILE"
}

show_menu() {
    while :; do
        printf '%s\n' '' 'singbox-alpine-lite management'
        show_info
        printf '%s\n' '' \
            '1) Show client links' \
            '2) Show service status' \
            '3) Restart sing-box' \
            '4) Stop sing-box' \
            '5) Show sing-box version' \
            '0) Exit'
        printf 'Select [1]: '
        if ! read -r choice; then
            printf '%s\n' ''
            exit 0
        fi
        choice=\${choice:-1}
        case "\$choice" in
            1) show_nodes ;;
            2) rc-service sing-box status ;;
            3) rc-service sing-box restart ;;
            4) rc-service sing-box stop ;;
            5) "\$BINARY_PATH" version ;;
            0) exit 0 ;;
            *) printf '%s\n' 'Invalid selection.' >&2 ;;
        esac
    done
}

usage() {
    printf '%s\n' \
        'Usage: sb [menu|nodes|status|restart|stop|version|info]' \
        '  sb                 Open the interactive management menu' \
        '  sb -N, --nodes     Print client links' \
        '  sb -S, --status    Show service status' \
        '  sb -r, --restart   Restart sing-box' \
        '  sb -s, --stop      Stop sing-box' \
        '  sb -v, --version   Show sing-box version' \
        '  sb -i, --info      Show installed protocols and ports' \
        '  sb -h, --help      Show this help'
}

if [ "\$#" -eq 0 ]; then
    if [ -t 0 ]; then
        show_menu
    else
        show_nodes
    fi
    exit 0
fi

case "\$1" in
    -N|--nodes|nodes)
        show_nodes
        ;;
    -S|--status|status)
        rc-service sing-box status
        ;;
    -r|--restart|restart)
        rc-service sing-box restart
        ;;
    -s|--stop|stop)
        rc-service sing-box stop
        ;;
    -v|--version|version)
        "\$BINARY_PATH" version
        ;;
    -i|--info|info)
        show_info
        ;;
    -h|--help|help)
        usage
        ;;
    -M|--menu|menu)
        show_menu
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
EOF
    chmod 0755 "$MANAGE_FILE"
    ln -sf "$MANAGE_FILE" /usr/bin/sb
}

rc-update add sing-box default >/dev/null 2>&1

if rc-service sing-box restart; then
    if [ -n "$HY2_HOP_RANGE" ]; then
        info 'Hysteria2 port hopping is active.'
    fi
else
    if [ -n "$HY2_HOP_RANGE" ]; then
        warn 'Hysteria2 port hopping could not be enabled.'
        warn 'This usually means the provider NAT, firewall, kernel, or container lacks range forwarding support.'
        warn 'Retrying the same installation with the single Hysteria2 port.'
        "${FIREWALL_FILE}" remove || true
        disable_hopping
        write_firewall
        if rc-service sing-box restart; then
            PORT_HOPPING_FALLBACK=1
            warn 'Single-port Hysteria2 started successfully; port hopping has been disabled.'
        else
            die 'sing-box failed with both port hopping and single-port Hysteria2'
        fi
    else
        die 'sing-box service failed to start'
    fi
fi

write_links
write_manage

cat > "${WORK_DIR}/state.env.new" <<EOF
APP_VERSION='${APP_VERSION}'
SING_BOX_VERSION='${SING_BOX_VERSION}'
PROTOCOLS='${PROTOCOLS}'
VLESS_PORT='${VLESS_PORT:-}'
HY2_PORT='${HY2_PORT:-}'
HY2_HOP_RANGE='${HY2_HOP_RANGE:-}'
SNI='${SNI}'
SERVER='${SERVER}'
NODE_NAME='${NODE_NAME}'
SUPERVISOR='${SUPERVISOR_MODE}'
EOF
chmod 0600 "${WORK_DIR}/state.env.new"
mv "${WORK_DIR}/state.env.new" "$STATE_FILE"

printf '%s\n' '' 'Installation completed successfully.'
printf '%s\n' 'Use "sb -N" to print client links.'
printf '%s\n' 'Use "sb -S" to check service status.'
[ "$PORT_HOPPING_FALLBACK" -eq 0 ] || printf '%s\n' 'Note: single-port fallback was used; Hysteria2 port hopping is disabled.'
