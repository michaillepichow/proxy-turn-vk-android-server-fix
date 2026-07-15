FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    iproute2 \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /etc/wdtt

# Скачивание бинарника и проверка SHA256 хеша
ARG WDTT_SERVER_URL="https://github.com/michaillepichow/proxy-turn-vk-android-server-fix/releases/download/1/server"
ARG WDTT_SHA256="847c02657a135f7235c016b40b5d161b53fb20a9fb963ffd0ecc75c959a1e9c5"
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wdtt-server "$WDTT_SERVER_URL"; \
    echo "$WDTT_SHA256  /usr/local/bin/wdtt-server" | sha256sum -c -; \
    chmod +x /usr/local/bin/wdtt-server

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV WDTT_DTLS_PORT=56000
ENV WDTT_WG_PORT=56001
ENV WDTT_ARGS=""

EXPOSE 56000/udp 56001/udp

ENTRYPOINT ["/entrypoint.sh"]