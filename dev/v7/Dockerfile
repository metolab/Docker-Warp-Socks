FROM alpine:3.22

LABEL maintainer="M0nius <m0niusplus@gmail.com>" \
    alpine-version="3.22.1" \
    org.opencontainers.image.title="Docker-Warp-Socks" \
    org.opencontainers.image.description="Connect to CloudFlare WARP with configurable ss, warp, socks5, and http proxy inbounds." \
    org.opencontainers.image.authors="M0nius <m0niusplus@gmail.com>" \
    org.opencontainers.image.vendor="M0nius Acc" \
    org.opencontainers.image.version="7.0.0" \
    org.opencontainers.image.url="https://hub.docker.com/r/monius/docker-warp-socks" \
    org.opencontainers.image.source="https://github.com/Mon-ius/Docker-Warp-Socks" \
    org.opencontainers.image.base.name="docker.io/monius/docker-warp-socks"

RUN apk update && apk upgrade \
    && apk add --no-cache curl openssl jq tar gcompat \
    && rm -rf /var/cache/apk/*

RUN set -e; \
    cd /tmp && \
    case $(arch) in \
        x86_64)  ARCH='amd64' ;; \
        aarch64) ARCH='arm64' ;; \
        armv7l)  ARCH='armv7' ;; \
        armv6l)  ARCH='armv6' ;; \
        arm)     ARCH='armv7' ;; \
        ppc64le) ARCH='ppc64le' ;; \
        s390x)   ARCH='s390x' ;; \
        riscv64) ARCH='riscv64' ;; \
        *)       echo "Unsupported architecture $(arch)" && exit 1 ;; \
    esac && \
    echo "Downloading sing-box for linux-${ARCH}..." && \
    RELEASE_TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/SagerNet/sing-box/releases/latest" | sed 's|.*/||') && \
    VERSION=${RELEASE_TAG#v} && \
    RELEASE_URL="https://github.com/SagerNet/sing-box/releases/download/${RELEASE_TAG}/sing-box-${VERSION}-linux-${ARCH}.tar.gz" && \
    echo "Downloading from: ${RELEASE_URL}" && \
    curl -fsSL "$RELEASE_URL" -o singbox.tar.gz && \
    tar xzf singbox.tar.gz && \
    find . -name "sing-box" -type f -executable -exec mv {} /usr/bin/sing-box \; && \
    chmod +x /usr/bin/sing-box && \
    mkdir -p /etc/sing-box && \
    rm -rf /tmp/*

COPY entrypoint.sh /run/entrypoint.sh
ENTRYPOINT ["/run/entrypoint.sh"]

CMD ["rws-cli-v7"]
