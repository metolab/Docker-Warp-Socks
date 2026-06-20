FROM alpine:3.22

LABEL maintainer="M0nius <m0niusplus@gmail.com>" \
    alpine-version="3.22.1" \
    org.opencontainers.image.title="Docker-Warp-Socks" \
    org.opencontainers.image.description="Expose configurable Shadowsocks, SOCKS5, and HTTP proxy inbounds with mihomo." \
    org.opencontainers.image.authors="M0nius <m0niusplus@gmail.com>" \
    org.opencontainers.image.vendor="M0nius Acc" \
    org.opencontainers.image.version="mihomo" \
    org.opencontainers.image.url="https://hub.docker.com/r/monius/docker-warp-socks" \
    org.opencontainers.image.source="https://github.com/Mon-ius/Docker-Warp-Socks" \
    org.opencontainers.image.base.name="docker.io/monius/docker-warp-socks"

RUN apk update && apk upgrade \
    && apk add --no-cache curl gzip jq openssl \
    && rm -rf /var/cache/apk/*

RUN set -e; \
    cd /tmp && \
    case $(arch) in \
        x86_64)  ASSET_ARCH='amd64-compatible' ;; \
        *)       echo "Unsupported architecture $(arch)" && exit 1 ;; \
    esac && \
    echo "Downloading mihomo for linux-${ASSET_ARCH}..." && \
    RELEASE_TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/MetaCubeX/mihomo/releases/latest" | sed 's|.*/||') && \
    RELEASE_URL="https://github.com/MetaCubeX/mihomo/releases/download/${RELEASE_TAG}/mihomo-linux-${ASSET_ARCH}-${RELEASE_TAG}.gz" && \
    echo "Downloading from: ${RELEASE_URL}" && \
    curl -fsSL "$RELEASE_URL" -o mihomo.gz && \
    gunzip -c mihomo.gz > /usr/bin/mihomo && \
    chmod +x /usr/bin/mihomo && \
    mkdir -p /etc/mihomo && \
    rm -rf /tmp/*

COPY entrypoint.sh /run/entrypoint.sh
ENTRYPOINT ["/run/entrypoint.sh"]

CMD ["rws-cli-mihomo"]
