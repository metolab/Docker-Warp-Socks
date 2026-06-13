#!/bin/sh

set -e

sleep 3

_WARP_SERVER=engage.cloudflareclient.com
_WARP_PORT=2408
_SS_METHOD=aes-256-gcm
_FEATURE='ss=12300,warp=12301,socks=12302,http=12303'

WARP_SERVER="${WARP_SERVER:-$_WARP_SERVER}"
WARP_PORT="${WARP_PORT:-$_WARP_PORT}"
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
            echo "[v7] DW_AUTH must use user:password format" >&2
            exit 1
            ;;
    esac

    if [ -z "$AUTH_USER" ] || [ -z "$AUTH_PASS" ]; then
        echo "[v7] DW_AUTH user and password cannot be empty" >&2
        exit 1
    fi
fi

if [ -z "$AUTH_PASS" ]; then
    AUTH_USER=warp
    AUTH_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
    echo "[v7] proxy auth (auto-generated): $AUTH_USER:$AUTH_PASS"
fi

if [ -z "$DW_FEATURE" ]; then
    echo "[v7] DW_FEATURE cannot be empty" >&2
    exit 1
fi

INBOUNDS=$(mktemp)
ROUTE_RULES=$(mktemp)
printf '[]' > "$INBOUNDS"
cat > "$ROUTE_RULES" <<'EOF'
[
  {
    "protocol": "dns",
    "action": "hijack-dns"
  },
  {
    "ip_is_private": true,
    "outbound": "direct-out"
  },
  {
    "ip_cidr": [
      "0.0.0.0/8",
      "10.0.0.0/8",
      "127.0.0.0/8",
      "169.254.0.0/16",
      "172.16.0.0/12",
      "192.168.0.0/16",
      "224.0.0.0/4",
      "240.0.0.0/4",
      "52.80.0.0/16",
      "112.95.0.0/16"
    ],
    "outbound": "direct-out"
  }
]
EOF

add_route_rule() {
    tag=$1
    outbound=$2
    tmp=$(mktemp)
    jq --arg tag "$tag" --arg outbound "$outbound" \
        '.[:0] + [{"inbound": $tag, "action": "sniff"}] + [{"inbound": $tag, "outbound": $outbound}] + .[0:]' \
        "$ROUTE_RULES" > "$tmp"
    mv "$tmp" "$ROUTE_RULES"
}

NEEDS_WARP=0

add_inbound() {
    name=$1
    port=$2
    if [ "$name" = "socks" ]; then
        name=socks5
    fi
    tag="${name}-in"
    tmp=$(mktemp)

    case "$name" in
        ss)
            jq --arg tag "$tag" --argjson port "$port" --arg method "$SS_METHOD" --arg password "$AUTH_PASS" \
                '. += [{
                    "type": "shadowsocks",
                    "tag": $tag,
                    "listen": "::",
                    "listen_port": $port,
                    "method": $method,
                    "password": $password
                }]' "$INBOUNDS" > "$tmp"
            mv "$tmp" "$INBOUNDS"
            add_route_rule "$tag" "direct-out"
            ;;
        warp)
            NEEDS_WARP=1
            jq --arg tag "$tag" --argjson port "$port" --arg method "$SS_METHOD" --arg password "$AUTH_PASS" \
                '. += [{
                    "type": "shadowsocks",
                    "tag": $tag,
                    "listen": "::",
                    "listen_port": $port,
                    "method": $method,
                    "password": $password
                }]' "$INBOUNDS" > "$tmp"
            mv "$tmp" "$INBOUNDS"
            add_route_rule "$tag" "WARP"
            ;;
        socks5)
            if [ -n "$AUTH_USER" ]; then
                jq --arg tag "$tag" --argjson port "$port" --arg user "$AUTH_USER" --arg password "$AUTH_PASS" \
                    '. += [{
                        "type": "socks",
                        "tag": $tag,
                        "listen": "::",
                        "listen_port": $port,
                        "users": [{"username": $user, "password": $password}]
                    }]' "$INBOUNDS" > "$tmp"
            else
                jq --arg tag "$tag" --argjson port "$port" \
                    '. += [{
                        "type": "socks",
                        "tag": $tag,
                        "listen": "::",
                        "listen_port": $port
                    }]' "$INBOUNDS" > "$tmp"
            fi
            mv "$tmp" "$INBOUNDS"
            add_route_rule "$tag" "direct-out"
            ;;
        http)
            if [ -n "$AUTH_USER" ]; then
                jq --arg tag "$tag" --argjson port "$port" --arg user "$AUTH_USER" --arg password "$AUTH_PASS" \
                    '. += [{
                        "type": "http",
                        "tag": $tag,
                        "listen": "::",
                        "listen_port": $port,
                        "users": [{"username": $user, "password": $password}]
                    }]' "$INBOUNDS" > "$tmp"
            else
                jq --arg tag "$tag" --argjson port "$port" \
                    '. += [{
                        "type": "http",
                        "tag": $tag,
                        "listen": "::",
                        "listen_port": $port
                    }]' "$INBOUNDS" > "$tmp"
            fi
            mv "$tmp" "$INBOUNDS"
            add_route_rule "$tag" "direct-out"
            ;;
        *)
            echo "[v7] unsupported feature: $name" >&2
            echo "[v7] supported features: ss, warp, socks5, http" >&2
            exit 1
            ;;
    esac
}

seen_features=","
old_ifs=$IFS
IFS=,
for item in $DW_FEATURE; do
    IFS=$old_ifs
    item=$(echo "$item" | tr -d '[:space:]')
    case "$item" in
        *=*) ;;
        *)
            echo "[v7] invalid feature item: $item" >&2
            echo "[v7] expected format: DW_FEATURE='ss=12300,warp=12301,socks=12302,http=12303'" >&2
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
            echo "[v7] invalid port for $name: $port" >&2
            exit 1
            ;;
    esac
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "[v7] port out of range for $name: $port" >&2
        exit 1
    fi
    case "$seen_features" in
        *,"$name",*)
            echo "[v7] duplicate feature: $name" >&2
            exit 1
            ;;
    esac
    case "${seen_ports:-,}" in
        *,"$port",*)
            echo "[v7] duplicate port: $port" >&2
            exit 1
            ;;
    esac
    seen_features="${seen_features}${name},"
    seen_ports="${seen_ports:-,}${port},"
    add_inbound "$name" "$port"
    IFS=,
done
IFS=$old_ifs

if [ "$(jq 'length' "$INBOUNDS")" -eq 0 ]; then
    echo "[v7] no enabled feature found" >&2
    exit 1
fi

ROUTE_FINAL=direct-out
CF_ADDR_V4=""
CF_ADDR_V6=""
CF_PRIVATE_KEY=""
CF_PUBLIC_KEY=""
reserved="[]"
if [ "$NEEDS_WARP" -eq 1 ]; then
    RESPONSE=$(curl -fsSL bit.ly/create-cloudflare-warp | sh -s)
    CF_CLIENT_ID=$(echo "$RESPONSE" | grep -o '"client":"[^"]*' | cut -d'"' -f4 | head -n 1)
    CF_ADDR_V4=$(echo "$RESPONSE" | grep -o '"v4":"[^"]*' | cut -d'"' -f4 | tail -n 1)
    CF_ADDR_V6=$(echo "$RESPONSE" | grep -o '"v6":"[^"]*' | cut -d'"' -f4 | tail -n 1)

    CF_PUBLIC_KEY=$(echo "$RESPONSE" | grep -o '"key":"[^"]*' | cut -d'"' -f4 | head -n 1)
    CF_PRIVATE_KEY=$(echo "$RESPONSE" | grep -o '"secret":"[^"]*' | cut -d'"' -f4 | head -n 1)

    if [ -z "$CF_CLIENT_ID" ] || [ -z "$CF_ADDR_V4" ] || [ -z "$CF_ADDR_V6" ] || [ -z "$CF_PUBLIC_KEY" ] || [ -z "$CF_PRIVATE_KEY" ]; then
        echo "[v7] failed to parse WARP credentials" >&2
        exit 1
    fi

    reserved=$(echo "$CF_CLIENT_ID" | base64 -d | od -An -t u1 | awk '{print "["$1", "$2", "$3"]"}' | head -n 1)
    ROUTE_FINAL=WARP
fi

jq -n \
    --slurpfile inbounds "$INBOUNDS" \
    --slurpfile rules "$ROUTE_RULES" \
    --arg routeFinal "$ROUTE_FINAL" \
    --argjson needsWarp "$NEEDS_WARP" \
    --arg cfAddrV4 "$CF_ADDR_V4" \
    --arg cfAddrV6 "$CF_ADDR_V6" \
    --arg privateKey "$CF_PRIVATE_KEY" \
    --arg warpServer "$WARP_SERVER" \
    --argjson warpPort "$WARP_PORT" \
    --arg publicKey "$CF_PUBLIC_KEY" \
    --argjson reserved "$reserved" \
    '{
        dns: {
            servers: [
                {
                    tag: "remote",
                    type: "tls",
                    server: "1.1.1.1",
                    domain_resolver: "local",
                    detour: "direct-out"
                },
                {
                    tag: "local",
                    type: "udp",
                    server: "8.8.8.8",
                    detour: "direct-out"
                }
            ],
            strategy: "prefer_ipv6",
            final: "remote",
            reverse_mapping: true
        },
        route: {
            default_domain_resolver: {
                server: "local",
                rewrite_ttl: 60
            },
            rules: $rules[0],
            auto_detect_interface: true,
            final: $routeFinal
        },
        inbounds: $inbounds[0],
        endpoints: (if $needsWarp == 1 then [
            {
                tag: "WARP",
                type: "wireguard",
                address: [
                    "\($cfAddrV4)/32",
                    "\($cfAddrV6)/128"
                ],
                private_key: $privateKey,
                peers: [
                    {
                        address: $warpServer,
                        port: $warpPort,
                        public_key: $publicKey,
                        allowed_ips: [
                            "0.0.0.0/0",
                            "::/0"
                        ],
                        persistent_keepalive_interval: 30,
                        reserved: $reserved
                    }
                ],
                mtu: 1408,
                udp_fragment: true
            }
        ] else [] end),
        outbounds: [
            {
                tag: "direct-out",
                type: "direct",
                udp_fragment: true
            }
        ]
    }' | tee /etc/sing-box/config.json

rm -f "$INBOUNDS" "$ROUTE_RULES"

if [ ! -e "/usr/bin/rws-cli-v7" ]; then
    printf '#!/bin/sh\nexec sing-box -c /etc/sing-box/config.json run\n' > /usr/bin/rws-cli-v7 && chmod +x /usr/bin/rws-cli-v7
fi

exec "$@"
