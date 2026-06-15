#!/bin/sh

set -e

sleep 3

_SS_METHOD=aes-256-gcm
_FEATURE='ss=12300,socks=12302,http=12303'

SS_METHOD="${SS_METHOD:-$_SS_METHOD}"
DW_FEATURE="${DW_FEATURE:-$_FEATURE}"

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
printf '[]' > "$LISTENERS"

add_listener() {
    name=$1
    port=$2
    tmp=$(mktemp)

    case "$name" in
        ss)
            jq --argjson port "$port" --arg method "$SS_METHOD" --arg password "$AUTH_PASS" \
                '. += [{
                    "name": "ss-in",
                    "type": "shadowsocks",
                    "listen": "::",
                    "port": $port,
                    "cipher": $method,
                    "password": $password,
                    "udp": true,
                    "proxy": "DIRECT"
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
            echo "[mihomo] supported features: ss, socks5, http" >&2
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
            echo "[mihomo] expected format: DW_FEATURE='ss=12300,socks=12302,http=12303'" >&2
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

jq '
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
        proxies: [],
        "proxy-groups": [],
        listeners: .,
        rules: ["MATCH,DIRECT"]
    }
' "$LISTENERS" > /etc/mihomo/config.yaml

rm -f "$LISTENERS"

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
