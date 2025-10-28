#!/usr/bin/env bash
set -e

### --- CONFIGURATION --- ###
LAN_IFACE="enp2s0f0"           # Interface LAN interne
LAN_IP="192.168.50.1"          # IP statique du LAN
LAN_NETMASK="/24"

echo "------------------------------------------"
echo " Installation d un routeur Ubuntu complet"
echo "------------------------------------------"
echo "Interface LAN : $LAN_IFACE"
echo "------------------------------------------"
sleep 2


### --- 1. MISE À JOUR ET INSTALLATION --- ###
echo "[1/7] Installation des paquets..."
apt update -y
apt install -y dnsmasq iptables-persistent ufw net-tools ethtool curl \
    libimobiledevice6 usbmuxd ifuse ipheth-utils


### --- 2. CONFIG NETPLAN --- ###
echo "[2/7] Configuration de Netplan..."
NETPLAN_FILE=$(ls /etc/netplan/*.yaml | head -n1)
cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"

cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${LAN_IFACE}:
      dhcp4: false
      addresses: [${LAN_IP}${LAN_NETMASK}]
      optional: true
      link-local: [ipv4]
      ignore-carrier: true
EOF

netplan generate
netplan apply


### --- 3. CONFIG DNSMASQ --- ###
echo "[3/7] Configuration de dnsmasq..."
cat > /etc/dnsmasq.conf <<EOF
interface=${LAN_IFACE}
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,12h
dhcp-option=3,${LAN_IP}
dhcp-option=6,${LAN_IP}
domain=lan
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq


### --- 4. ROUTAGE IP --- ###
echo "[4/7] Activation du routage IPv4..."
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p


### --- 5. CONFIG UFW --- ###
echo "[5/7] Configuration UFW..."
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw allow ssh
ufw --force enable


### --- 6. INSTALLATION DU DEMON AUTO --- ###
echo "[6/7] Installation du démon router-watchdog..."

cat > /usr/local/bin/router-watchdog.sh <<'EOF'
#!/usr/bin/env bash
# === ROUTER WATCHDOG ===
# Surveille l’état du LAN et du WAN (tethering)
# et relance la configuration réseau et NAT automatiquement

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
    # Surveille LAN
    lan_carrier=$(cat /sys/class/net/$LAN_IFACE/carrier 2>/dev/null || echo 0)
    lan_state=$([ "$lan_carrier" = "1" ] && echo "up" || echo "down")

    # Surveille WAN
    wan_iface=$(get_wan_iface)

    # Si LAN change
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

    # Si WAN change
    if [ "$wan_iface" != "$last_wan_iface" ]; then
        echo "$(date '+%F %T') [watchdog] Changement WAN détecté ($last_wan_iface → $wan_iface)" >> "$LOG_FILE"
        setup_wan
        last_wan_iface="$wan_iface"
    fi

    sleep 5
done
EOF

chmod +x /usr/local/bin/router-watchdog.sh


cat > /etc/systemd/system/router-watchdog.service <<EOF
[Unit]
Description=Surveillance automatique LAN/WAN + DHCP tethering
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
echo "✅ Installation terminée avec succès"
echo "  - LAN : ${LAN_IFACE} (${LAN_IP}${LAN_NETMASK})"
echo "  - DHCP/DNS : dnsmasq actif"
echo "  - NAT : auto via interface WAN détectée"
echo "  - Démon : router-watchdog actif"
echo "------------------------------------------"
echo "Recommandé : redémarrer le serveur"
