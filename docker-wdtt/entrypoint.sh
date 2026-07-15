#!/bin/sh
set -e

ip link del wdtt0 2>/dev/null || true

WAN_IFACE=$(ip -o route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
if [ -z "$WAN_IFACE" ]; then
    WAN_IFACE="eth0"
fi

CLIENT_CIDR="${WDTT_CLIENT_CIDR:-10.66.66.0/24}"
ENABLE_TCPMSS="${WDTT_ENABLE_TCPMSS:-0}"

echo "Используется сетевой интерфейс: $WAN_IFACE"
echo "Используется клиентская подсеть: $CLIENT_CIDR"

iptables -t nat -C POSTROUTING -s "$CLIENT_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$CLIENT_CIDR" -o "$WAN_IFACE" -j MASQUERADE

if [ "$ENABLE_TCPMSS" = "1" ]; then
    echo "Настройка TCPMSS для $CLIENT_CIDR..."
    iptables -t mangle -C FORWARD -s "$CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -s "$CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -d "$CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -d "$CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
else
    echo "Пропускаем TCPMSS (WDTT_ENABLE_TCPMSS=$ENABLE_TCPMSS)"
fi

echo "Запуск wdtt-server (DTLS: ${WDTT_DTLS_PORT}, WG: ${WDTT_WG_PORT})..."
exec /usr/local/bin/wdtt-server \
    -listen "0.0.0.0:${WDTT_DTLS_PORT}" \
    -wg-port "${WDTT_WG_PORT}" \
    -config-dir "/etc/wdtt" \
    ${WDTT_ARGS}