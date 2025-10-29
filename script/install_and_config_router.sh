#!/usr/bin/env bash
set -e

### --- CONFIGURATION --- ###
LAN_IFACE="enp2s0f0"           # Interface LAN interne
LAN_IP="192.168.50.1"          # IP statique du LAN
LAN_NETMASK="/24"
DHCP_RANGE_START="192.168.50.10"
DHCP_RANGE_END="192.168.50.100"
DHCP_LEASE="12h"
DNS_SERVERS="8.8.8.8,8.8.4.4"
DOMAIN_NAME="lan"

echo "------------------------------------------"
echo " Installation d'un routeur Ubuntu complet"
echo " Interface LAN : $LAN_IFACE"
echo " IP LAN        : $LAN_IP$LAN_NETMASK"
echo "------------------------------------------"
sleep 2

### --- 1. INSTALLATION DES PAQUETS --- ###
echo "[1/7] Installation des paquets nécessaires..."
DEPS=(dnsmasq iptables-persistent ufw net-tools ethtool curl)
for pkg in "${DEPS[@]}"; do
    if ! dpkg -l | grep -qw "$pkg"; then
        echo "Installation de $pkg..."
        apt install -y "$pkg"
    else
        echo "$pkg déjà installé"
    fi
done

### --- 2. CONFIG NETPLAN --- ###
echo "[2/7] Configuration Netplan pour LAN..."
NETPLAN_FILE=$(ls /etc/netplan/*.yaml | head -n1)
cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak" 2>/dev/null || true

cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${LAN_IFACE}:
      dhcp4: false
      addresses: [${LAN_IP}${LAN_NETMASK}]
      optional: true
      link-local: []
      ignore-carrier: true
EOF

netplan generate
netplan apply

### --- 3. CONFIG DNSMASQ --- ###
echo "[3/7] Configuration dnsmasq..."
if [ -f /etc/dnsmasq.conf ]; then mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak; fi

cat > /etc/dnsmasq.conf <<EOF
interface=${LAN_IFACE}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}
dhcp-option=3,${LAN_IP}
dhcp-option=6,${DNS_SERVERS}
domain=${DOMAIN_NAME}
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq

### --- 4. ROUTAGE IP --- ###
echo "[4/7] Activation du routage IPv4..."
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

### --- 5. CONFIG UFW ET NAT --- ###
echo "[5/7] Configuration UFW et NAT..."

# Forwarding UFW
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# NAT dynamique pour WAN détecté
WAN_IFACE=$(ip -br link | grep -E 'enx|usb|eth0|wlan0' | awk '{print $1}' | head -n1)
if [ -n "$WAN_IFACE" ]; then
    echo "*nat" > /etc/ufw/before.rules
    echo ":POSTROUTING ACCEPT [0:0]" >> /etc/ufw/before.rules
    echo "-A POSTROUTING -s 192.168.50.0/24 -o $WAN_IFACE -j MASQUERADE" >> /etc/ufw/before.rules
    echo "COMMIT" >> /etc/ufw/before.rules
    echo "NAT configuré sur WAN : $WAN_IFACE"
fi

# Autoriser LAN et Internet
ufw allow in on $LAN_IFACE
[ -n "$WAN_IFACE" ] && ufw allow out on $WAN_IFACE

ufw --force enable

### --- 6. WATCHDOG AVEC DHCP WAN --- ###
echo "[6/7] Installation du démon router-watchdog..."
cat > /usr/local/bin/router-watchdog.sh <<'EOF'
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
EOF

chmod +x /usr/local/bin/router-watchdog.sh

cat > /etc/systemd/system/router-watchdog.service <<EOF
[Unit]
Description=Surveillance LAN/WAN + NAT DHCP WAN
After=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/bin/router-watchdog.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable router-watchdog.service
systemctl start router-watchdog.service

### --- 7. FIN --- ###
echo "------------------------------------------"
echo "✅ Routeur installé avec succès"
echo " LAN : $LAN_IFACE ($LAN_IP$LAN_NETMASK)"
echo " DHCP/DNS : dnsmasq actif"
echo " NAT : automatique via WAN détecté + dhclient"
echo " Watchdog : actif"
echo "------------------------------------------"
echo "Recommandé : redémarrer le serveur"
