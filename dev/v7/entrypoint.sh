#!/bin/sh

set -e

sleep 3

_SS_METHOD=aes-256-gcm
_FEATURE='ss=12300,warp=12301,socks=12302,http=12303'
_WARP_SERVER=engage.cloudflareclient.com
_WARP_PORT=2408

SS_METHOD="${SS_METHOD:-$_SS_METHOD}"
DW_FEATURE="${DW_FEATURE:-$_FEATURE}"
WARP_SERVER="${WARP_SERVER:-$_WARP_SERVER}"
WARP_PORT="${WARP_PORT:-$_WARP_PORT}"

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
    proxy=DIRECT
    tmp=$(mktemp)

    case "$name" in
        ss|warp)
            if [ "$name" = "warp" ]; then
                listener_name=ss-in-warp
                proxy=WARP
            else
                listener_name=ss-in
            fi
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
                    "proxy": "DIRECT"
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
                    "proxy": "DIRECT"
                }]' "$LISTENERS" > "$tmp"
            ;;
        *)
            echo "[mihomo] unsupported feature: $name" >&2
            echo "[mihomo] supported features: ss, warp, socks5, http" >&2
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

        tmp=$(mktemp)
        jq --arg server "$WARP_SERVER" \
            --argjson port "$WARP_PORT" \
            --arg private_key "$CF_PRIVATE_KEY" \
            --arg ip "$CF_ADDR_V4" \
            --arg ipv6 "$CF_ADDR_V6" \
            --arg public_key "$CF_PUBLIC_KEY" \
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
                reserved: $reserved,
                udp: true,
                mtu: 1408
            }]' "$PROXIES" > "$tmp"
        mv "$tmp" "$PROXIES"
        ;;
esac

jq -n --slurpfile listeners "$LISTENERS" --slurpfile proxies "$PROXIES" '
    {
        "mixed-port": 0,
        "allow-lan": true,
        "bind-address": "*",
        mode: "rule",
        "log-level": "info",
        ipv6: false,
        dns: {
            enable: true,
            ipv6: false,
            "enhanced-mode": "normal",
            nameserver: ["1.1.1.1", "8.8.8.8"]
        },
        proxies: $proxies[0],
        "proxy-groups": [],
        listeners: $listeners[0],
        rules: ["MATCH,DIRECT"]
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
