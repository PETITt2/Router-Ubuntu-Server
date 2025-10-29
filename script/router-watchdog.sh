#!/usr/bin/env bash
LAN_IFACE="enp2s0f0"
LAN_NET="192.168.50.0/24"
LOG_FILE="/var/log/router-watchdog.log"

echo "$(date '+%F %T') [watchdog] Service démarré" >> "$LOG_FILE"

get_wan_iface() {
    ip -br link | grep -E 'enx|usb|eth0|wlan0' | awk '{print $1}' | head -n1
}

setup_nat() {
    local wan
    wan=$(get_wan_iface)
    if [ -n "$wan" ]; then
        echo "$(date '+%F %T') [watchdog] WAN détecté : $wan" >> "$LOG_FILE"
        # Redemande IP via DHCP
        dhclient -v "$wan" >> "$LOG_FILE" 2>&1
        # Configurer NAT
        iptables -t nat -F
        iptables -t nat -A POSTROUTING -s $LAN_NET -o "$wan" -j MASQUERADE
        netfilter-persistent save
        echo "$(date '+%F %T') [watchdog] NAT configuré sur $wan" >> "$LOG_FILE"
    else
        echo "$(date '+%F %T') [watchdog] Aucun WAN détecté" >> "$LOG_FILE"
    fi
}

last_lan=""
last_wan=""

while true; do
    # Surveille LAN
    lan_state=$(cat /sys/class/net/$LAN_IFACE/carrier 2>/dev/null || echo 0)
    lan_state=$([ "$lan_state" = "1" ] && echo "up" || echo "down")
    # Surveille WAN
    wan_iface=$(get_wan_iface)

    # Si changement LAN
    if [ "$lan_state" != "$last_lan" ]; then
        if [ "$lan_state" = "up" ]; then
            echo "$(date '+%F %T') [watchdog] LAN UP" >> "$LOG_FILE"
            systemctl restart dnsmasq
        fi
        last_lan="$lan_state"
    fi

    # Si changement WAN
    if [ "$wan_iface" != "$last_wan" ]; then
        echo "$(date '+%F %T') [watchdog] WAN changé ($last_wan → $wan_iface)" >> "$LOG_FILE"
        setup_nat
        last_wan="$wan_iface"
    fi

    sleep 5
done
