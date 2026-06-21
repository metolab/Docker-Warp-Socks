#!/bin/sh

set -e

sleep 3

_SS_METHOD=aes-256-gcm
_FEATURE='ss=12300,warp=12301,masque=12304,socks=12302,http=12303'
_WARP_SERVER=engage.cloudflareclient.com
_WARP_PORT=2408
_LOCAL_TARGET_IP_VERSION=prefer-v4
_WARP_ENDPOINT_IP_VERSION=prefer-v4
_WARP_TARGET_IP_VERSION=prefer-v6
_MASQUE_ENDPOINT_IP_VERSION=prefer-v4
_MASQUE_TARGET_IP_VERSION=prefer-v6

SS_METHOD="${SS_METHOD:-$_SS_METHOD}"
DW_FEATURE="${DW_FEATURE:-$_FEATURE}"
WARP_SERVER="${WARP_SERVER:-$_WARP_SERVER}"
WARP_PORT="${WARP_PORT:-$_WARP_PORT}"
LOCAL_TARGET_IP_VERSION="${LOCAL_TARGET_IP_VERSION:-${LOCAL_IP_VERSION:-$_LOCAL_TARGET_IP_VERSION}}"
WARP_ENDPOINT_IP_VERSION="${WARP_ENDPOINT_IP_VERSION:-${WARP_IP_VERSION:-$_WARP_ENDPOINT_IP_VERSION}}"
WARP_TARGET_IP_VERSION="${WARP_TARGET_IP_VERSION:-${WARP_IP_VERSION:-$_WARP_TARGET_IP_VERSION}}"
MASQUE_ENDPOINT_IP_VERSION="${MASQUE_ENDPOINT_IP_VERSION:-${MASQUE_IP_VERSION:-$_MASQUE_ENDPOINT_IP_VERSION}}"
MASQUE_TARGET_IP_VERSION="${MASQUE_TARGET_IP_VERSION:-${MASQUE_IP_VERSION:-$_MASQUE_TARGET_IP_VERSION}}"

normalize_ip_version() {
    value=$1
    name=$2

    case "$value" in
        prefer-v4|ipv4-prefer)
            printf '%s\n' ipv4-prefer
            ;;
        prefer-v6|ipv6-prefer)
            printf '%s\n' ipv6-prefer
            ;;
        only-v4|ipv4)
            printf '%s\n' ipv4
            ;;
        only-v6|ipv6)
            printf '%s\n' ipv6
            ;;
        dual)
            printf '%s\n' dual
            ;;
        *)
            echo "[mihomo] invalid $name: $value" >&2
            echo "[mihomo] supported values: prefer-v4, prefer-v6, only-v4, only-v6, dual" >&2
            exit 1
            ;;
    esac
}

LOCAL_TARGET_IP_VERSION=$(normalize_ip_version "$LOCAL_TARGET_IP_VERSION" LOCAL_TARGET_IP_VERSION)
WARP_ENDPOINT_IP_VERSION=$(normalize_ip_version "$WARP_ENDPOINT_IP_VERSION" WARP_ENDPOINT_IP_VERSION)
WARP_TARGET_IP_VERSION=$(normalize_ip_version "$WARP_TARGET_IP_VERSION" WARP_TARGET_IP_VERSION)
MASQUE_ENDPOINT_IP_VERSION=$(normalize_ip_version "$MASQUE_ENDPOINT_IP_VERSION" MASQUE_ENDPOINT_IP_VERSION)
MASQUE_TARGET_IP_VERSION=$(normalize_ip_version "$MASQUE_TARGET_IP_VERSION" MASQUE_TARGET_IP_VERSION)

is_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF == 4 {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
                    exit 1
                }
            }
            exit 0
        }
        { exit 1 }
    '
}

is_ipv6() {
    case "$1" in
        *:*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_host_ips() {
    host=$1
    type=$2

    if is_ipv4 "$host" || is_ipv6 "$host"; then
        printf '%s\n' "$host"
        return
    fi

    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" 2>/dev/null | awk '{print $1}'
    fi

    if command -v dig >/dev/null 2>&1; then
        case "$type" in
            v4) dig +short A "$host" 2>/dev/null ;;
            v6) dig +short AAAA "$host" 2>/dev/null ;;
            *) dig +short A "$host" 2>/dev/null; dig +short AAAA "$host" 2>/dev/null ;;
        esac
    fi
}

select_ip_by_policy() {
    v4_values=$1
    v6_values=$2
    policy=$3
    name=$4

    first_v4=$(printf '%s\n' "$v4_values" | awk 'NF {print; exit}')
    first_v6=$(printf '%s\n' "$v6_values" | awk 'NF {print; exit}')

    case "$policy" in
        ipv4)
            selected=$first_v4
            ;;
        ipv6)
            selected=$first_v6
            ;;
        ipv6-prefer)
            selected=${first_v6:-$first_v4}
            ;;
        ipv4-prefer|dual)
            selected=${first_v4:-$first_v6}
            ;;
    esac

    if [ -z "$selected" ]; then
        echo "[mihomo] failed to resolve $name for $policy" >&2
        exit 1
    fi

    printf '%s\n' "$selected"
}

select_host_ip_by_policy() {
    host=$1
    policy=$2
    name=$3

    all_ips=$(resolve_host_ips "$host" all | awk '!seen[$0]++')
    v4_ips=$(printf '%s\n' "$all_ips" | awk '/^[0-9]+\./')
    v6_ips=$(printf '%s\n' "$all_ips" | awk '/:/')

    select_ip_by_policy "$v4_ips" "$v6_ips" "$policy" "$name"
}

AUTH_USER=""
AUTH_PASS=""
if [ -n "$DW_AUTH" ]; then
    case "$DW_AUTH" in
        *:*)
            AUTH_USER=${DW_AUTH%%:*}
            AUTH_PASS=${DW_AUTH#*:}
            ;;
        *)
            echo "[mihomo] DW_AUTH must use user:password format" >&2
            exit 1
            ;;
    esac

    if [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASS" ]; then
        echo "[mihomo] DW_AUTH user and password cannot be empty" >&2
        exit 1
    fi
fi

if [ -z "$AUTH_PASS" ]; then
    AUTH_USER=warp
    AUTH_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
    echo "[mihomo] proxy auth (auto-generated): $AUTH_USER:$AUTH_PASS"
fi

if [ -z "$DW_FEATURE" ]; then
    echo "[mihomo] DW_FEATURE cannot be empty" >&2
    exit 1
fi

LISTENERS=$(mktemp)
PROXIES=$(mktemp)
printf '[]' > "$LISTENERS"
printf '[]' > "$PROXIES"

add_listener() {
    name=$1
    port=$2
    proxy=LOCAL
    tmp=$(mktemp)

    case "$name" in
        ss|warp|masque)
            case "$name" in
                warp)
                    listener_name=ss-in-warp
                    proxy=WARP
                    ;;
                masque)
                    listener_name=ss-in-masque
                    proxy=MASQUE
                    ;;
                *)
                    listener_name=ss-in
                    ;;
            esac
            jq --arg name "$listener_name" --argjson port "$port" --arg method "$SS_METHOD" --arg password "$AUTH_PASS" --arg proxy "$proxy" \
                '. += [{
                    "name": $name,
                    "type": "shadowsocks",
                    "listen": "::",
                    "port": $port,
                    "cipher": $method,
                    "password": $password,
                    "udp": true,
                    "proxy": $proxy
                }]' "$LISTENERS" > "$tmp"
            ;;
        socks5)
            jq --argjson port "$port" --arg user "$AUTH_USER" --arg password "$AUTH_PASS" \
                '. += [{
                    "name": "socks5-in",
                    "type": "socks",
                    "listen": "::",
                    "port": $port,
                    "users": [{"username": $user, "password": $password}],
                    "udp": true,
                    "proxy": "LOCAL"
                }]' "$LISTENERS" > "$tmp"
            ;;
        http)
            jq --argjson port "$port" --arg user "$AUTH_USER" --arg password "$AUTH_PASS" \
                '. += [{
                    "name": "http-in",
                    "type": "http",
                    "listen": "::",
                    "port": $port,
                    "users": [{"username": $user, "password": $password}],
                    "proxy": "LOCAL"
                }]' "$LISTENERS" > "$tmp"
            ;;
        *)
            echo "[mihomo] unsupported feature: $name" >&2
            echo "[mihomo] supported features: ss, warp, masque, socks5, http" >&2
            exit 1
            ;;
    esac

    mv "$tmp" "$LISTENERS"
}

seen_features=","
seen_ports=","
old_ifs=$IFS
IFS=,
for item in $DW_FEATURE; do
    IFS=$old_ifs
    item=$(echo "$item" | tr -d '[:space:]')
    case "$item" in
        *=*) ;;
        *)
            echo "[mihomo] invalid feature item: $item" >&2
            echo "[mihomo] expected format: DW_FEATURE='ss=12300,warp=12301,socks=12302,http=12303'" >&2
            exit 1
            ;;
    esac

    name=${item%%=*}
    if [ "$name" = "socks" ]; then
        name=socks5
    fi
    port=${item#*=}
    case "$port" in
        ''|*[!0-9]*)
            echo "[mihomo] invalid port for $name: $port" >&2
            exit 1
            ;;
    esac
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "[mihomo] port out of range for $name: $port" >&2
        exit 1
    fi
    case "$seen_features" in
        *,"$name",*)
            echo "[mihomo] duplicate feature: $name" >&2
            exit 1
            ;;
    esac
    case "$seen_ports" in
        *,"$port",*)
            echo "[mihomo] duplicate port: $port" >&2
            exit 1
            ;;
    esac
    seen_features="${seen_features}${name},"
    seen_ports="${seen_ports}${port},"
    add_listener "$name" "$port"
    IFS=,
done
IFS=$old_ifs

if [ "$(jq 'length' "$LISTENERS")" -eq 0 ]; then
    echo "[mihomo] no enabled feature found" >&2
    exit 1
fi

case "$WARP_PORT" in
    ''|*[!0-9]*)
        echo "[mihomo] invalid WARP_PORT: $WARP_PORT" >&2
        exit 1
        ;;
esac
if [ "$WARP_PORT" -lt 1 ] || [ "$WARP_PORT" -gt 65535 ]; then
    echo "[mihomo] WARP_PORT out of range: $WARP_PORT" >&2
    exit 1
fi

case "$seen_features" in
    *,warp,*)
        RESPONSE=$(curl -fsSL bit.ly/create-cloudflare-warp | sh -s)
        CF_CLIENT_ID=$(echo "$RESPONSE" | grep -o '"client":"[^"]*' | cut -d'"' -f4 | head -n 1)
        CF_ADDR_V4=$(echo "$RESPONSE" | grep -o '"v4":"[^"]*' | cut -d'"' -f4 | tail -n 1)
        CF_ADDR_V6=$(echo "$RESPONSE" | grep -o '"v6":"[^"]*' | cut -d'"' -f4 | tail -n 1)
        CF_PUBLIC_KEY=$(echo "$RESPONSE" | grep -o '"key":"[^"]*' | cut -d'"' -f4 | head -n 1)
        CF_PRIVATE_KEY=$(echo "$RESPONSE" | grep -o '"secret":"[^"]*' | cut -d'"' -f4 | head -n 1)

        if [ -z "$CF_CLIENT_ID" ] || [ -z "$CF_ADDR_V4" ] || [ -z "$CF_ADDR_V6" ] || [ -z "$CF_PUBLIC_KEY" ] || [ -z "$CF_PRIVATE_KEY" ]; then
            echo "[mihomo] failed to create Cloudflare WARP profile" >&2
            exit 1
        fi

        reserved=$(echo "$CF_CLIENT_ID" | base64 -d | od -An -t u1 | awk '{print "["$1", "$2", "$3"]"}' | head -n 1)
        if [ -z "$reserved" ]; then
            echo "[mihomo] failed to decode Cloudflare WARP reserved bytes" >&2
            exit 1
        fi

        WARP_ENDPOINT_SERVER=$(select_host_ip_by_policy "$WARP_SERVER" "$WARP_ENDPOINT_IP_VERSION" WARP_SERVER)

        tmp=$(mktemp)
        jq --arg server "$WARP_ENDPOINT_SERVER" \
            --argjson port "$WARP_PORT" \
            --arg private_key "$CF_PRIVATE_KEY" \
            --arg ip "$CF_ADDR_V4" \
            --arg ipv6 "$CF_ADDR_V6" \
            --arg public_key "$CF_PUBLIC_KEY" \
            --arg ip_version "$WARP_TARGET_IP_VERSION" \
            --argjson reserved "$reserved" \
            '. += [{
                name: "WARP",
                type: "wireguard",
                "private-key": $private_key,
                server: $server,
                port: $port,
                ip: $ip,
                ipv6: $ipv6,
                "public-key": $public_key,
                "allowed-ips": ["0.0.0.0/0", "::/0"],
                "ip-version": $ip_version,
                reserved: $reserved,
                udp: true,
                mtu: 1408
            }]' "$PROXIES" > "$tmp"
        mv "$tmp" "$PROXIES"
        ;;
esac

case "$seen_features" in
    *,masque,*)
        MASQUE_CONFIG_DIR=$(mktemp -d)
        MASQUE_CONFIG="$MASQUE_CONFIG_DIR/config.json"
        if ! usque -c "$MASQUE_CONFIG" register --accept-tos >/tmp/usque-register.log 2>&1; then
            echo "[mihomo] failed to create Cloudflare MASQUE profile" >&2
            sed -n '1,120p' /tmp/usque-register.log >&2
            rm -rf "$MASQUE_CONFIG_DIR" /tmp/usque-register.log
            exit 1
        fi

        MASQUE_PRIVATE_KEY=$(jq -r '.private_key // empty' "$MASQUE_CONFIG")
        MASQUE_PUBLIC_KEY=$(jq -r '.endpoint_pub_key // empty' "$MASQUE_CONFIG" | sed '/^-----BEGIN PUBLIC KEY-----$/d;/^-----END PUBLIC KEY-----$/d' | tr -d '\n\r')
        MASQUE_ENDPOINT_V4=$(jq -r '.endpoint_v4 // empty' "$MASQUE_CONFIG")
        MASQUE_ENDPOINT_V6=$(jq -r '.endpoint_v6 // empty' "$MASQUE_CONFIG")
        MASQUE_ADDR_V4=$(jq -r '.ipv4 // empty' "$MASQUE_CONFIG")
        MASQUE_ADDR_V6=$(jq -r '.ipv6 // empty' "$MASQUE_CONFIG")

        if [ -z "$MASQUE_PRIVATE_KEY" ] || [ -z "$MASQUE_PUBLIC_KEY" ] || [ -z "$MASQUE_ENDPOINT_V4" ] || [ -z "$MASQUE_ENDPOINT_V6" ] || [ -z "$MASQUE_ADDR_V4" ] || [ -z "$MASQUE_ADDR_V6" ]; then
            echo "[mihomo] failed to parse Cloudflare MASQUE profile" >&2
            rm -rf "$MASQUE_CONFIG_DIR" /tmp/usque-register.log
            exit 1
        fi

        MASQUE_SERVER=$(select_ip_by_policy "$MASQUE_ENDPOINT_V4" "$MASQUE_ENDPOINT_V6" "$MASQUE_ENDPOINT_IP_VERSION" MASQUE_ENDPOINT)

        tmp=$(mktemp)
        jq --arg server "$MASQUE_SERVER" \
            --arg private_key "$MASQUE_PRIVATE_KEY" \
            --arg public_key "$MASQUE_PUBLIC_KEY" \
            --arg ip "$MASQUE_ADDR_V4/32" \
            --arg ipv6 "$MASQUE_ADDR_V6/128" \
            --arg ip_version "$MASQUE_TARGET_IP_VERSION" \
            '. += [{
                name: "MASQUE",
                type: "masque",
                server: $server,
                port: 443,
                "private-key": $private_key,
                "public-key": $public_key,
                ip: $ip,
                ipv6: $ipv6,
                "ip-version": $ip_version,
                udp: true,
                mtu: 1280
            }]' "$PROXIES" > "$tmp"
        mv "$tmp" "$PROXIES"
        rm -rf "$MASQUE_CONFIG_DIR" /tmp/usque-register.log
        ;;
esac

jq -n \
    --slurpfile listeners "$LISTENERS" \
    --slurpfile proxies "$PROXIES" \
    --arg local_ip_version "$LOCAL_TARGET_IP_VERSION" '
    {
        "mixed-port": 0,
        "allow-lan": true,
        "bind-address": "*",
        mode: "rule",
        "log-level": "info",
        ipv6: true,
        dns: {
            enable: true,
            ipv6: true,
            "enhanced-mode": "normal",
            nameserver: ["1.1.1.1", "8.8.8.8"]
        },
        proxies: ([{
            name: "LOCAL",
            type: "direct",
            udp: true,
            "ip-version": $local_ip_version
        }] + $proxies[0]),
        "proxy-groups": [],
        listeners: $listeners[0],
        rules: ["MATCH,LOCAL"]
    }
' > /etc/mihomo/config.yaml

rm -f "$LISTENERS" "$PROXIES"

start_cf_probe() {
    (
        set +e
        url="https://cp.cloudflare.com/cdn-cgi/trace"
        interval=10

        while true; do
            body=$(mktemp)
            metrics=$(curl -sS -L --max-time 15 -o "$body" -w '%{http_code} %{time_total}' "$url" 2>&1)
            rc=$?
            status=${metrics%% *}
            elapsed=${metrics#* }
            timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

            if [ "$rc" -eq 0 ]; then
                echo "[mihomo-probe] $timestamp status=$status elapsed=${elapsed}s url=$url"
                sed 's/^/[mihomo-probe] body: /' "$body"
            else
                echo "[mihomo-probe] $timestamp status=ERR elapsed=NA url=$url error=$metrics"
            fi

            rm -f "$body"
            sleep "$interval"
        done
    ) &
}

if [ ! -e "/usr/bin/rws-cli-mihomo" ]; then
    printf '#!/bin/sh\nexec mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml\n' > /usr/bin/rws-cli-mihomo
    chmod +x /usr/bin/rws-cli-mihomo
fi

start_cf_probe

exec "$@"
