#!/usr/bin/env bash
LAN_IFACE="enp2s0f0"
LOG_FILE="/var/log/router-watchdog.log"

echo "$(date '+%F %T') [watchdog] Service démarré" >> "$LOG_FILE"

get_wan_iface() {
    ip -br link | grep -E 'enx|usb' | awk '{print $1}' | head -n1
}

setup_wan() {
    local wan
    wan=$(get_wan_iface)
    if [ -n "$wan" ]; then
        echo "$(date '+%F %T') [watchdog] Interface WAN détectée: $wan" >> "$LOG_FILE"
        dhclient -v "$wan" >> "$LOG_FILE" 2>&1
        iptables -t nat -F
        iptables -t nat -A POSTROUTING -o "$wan" -j MASQUERADE
        netfilter-persistent save
        echo "$(date '+%F %T') [watchdog] NAT configuré via $wan" >> "$LOG_FILE"
    else
        echo "$(date '+%F %T') [watchdog] Aucun WAN détecté" >> "$LOG_FILE"
    fi
}

last_lan_state=""
last_wan_iface=""

while true; do
    lan_carrier=$(cat /sys/class/net/$LAN_IFACE/carrier 2>/dev/null || echo 0)
    lan_state=$([ "$lan_carrier" = "1" ] && echo "up" || echo "down")
    wan_iface=$(get_wan_iface)

    if [ "$lan_state" != "$last_lan_state" ]; then
        if [ "$lan_state" = "up" ]; then
            echo "$(date '+%F %T') [watchdog] LAN $LAN_IFACE UP → reconfiguration" >> "$LOG_FILE"
            netplan apply
            systemctl restart dnsmasq
        else
            echo "$(date '+%F %T') [watchdog] LAN $LAN_IFACE DOWN" >> "$LOG_FILE"
        fi
        last_lan_state="$lan_state"
    fi

    if [ "$wan_iface" != "$last_wan_iface" ]; then
        echo "$(date '+%F %T') [watchdog] Changement WAN détecté ($last_wan_iface → $wan_iface)" >> "$LOG_FILE"
        setup_wan
        last_wan_iface="$wan_iface"
    fi

    sleep 5
done