# → Ubuntu Server – Linux Router NAT ←

---

## CONTEXTE

```text
Pour réaliser un réseau de test, j’ai plusieurs ordinateurs, dont un Lenovo TinyCenter.
Cet ordinateur servira de routeur, sous Ubuntu Server (dernière version disponible).

Si vous avez deux ports Ethernet ou deux interfaces réseau, ignorez les parties concernant la connexion du téléphone.

Dans mon cas, cet ordinateur n’a qu’une seule interface réseau physique (Ethernet : enp2s0f0),
qui servira de sortie vers le réseau interne.

La solution consiste à connecter un téléphone en USB (tethering) pour créer une interface réseau virtuelle,
puis configurer l’environnement du routeur.
```

---

## Préparatifs

Téléchargez l’ISO officielle d’Ubuntu Server (exemple : version 24.04.3).

👉 [Page de téléchargement Ubuntu Server](https://ubuntu.com/download/server)

Après installation, branchez votre port Ethernet à un réseau ayant Internet pour télécharger les outils nécessaires aux premières étapes.

---

## Connexion du téléphone

### Si vous possédez un Android :

1. Branchez votre téléphone au serveur.  
2. Sur le téléphone, activez **Partage de connexion → Partage USB**.

Vérifiez ensuite que l’interface est détectée :

```shell
ip a
```

⚠️ Si vous n’obtenez pas d’adresse IP, il est possible que le DHCP de votre téléphone ne réponde pas.  
Dans ce cas, relancez une requête DHCP :

```shell
sudo dhclient -v <interface_usb>
```

---

### Si vous possédez un iPhone :

Ubuntu ne possède pas nativement les outils nécessaires pour le tethering USB avec iPhone.

Installez donc les paquets suivants :

```shell
sudo apt install -y libimobiledevice6 usbmuxd ifuse ipheth-utils
```

Vérifiez que l’interface est bien détectée :

```shell
ip a
```

Et, si besoin, relancez la requête DHCP :

```shell
sudo dhclient -v <interface_usb>
```

---

## Installer les outils pour créer le routeur NAT

```shell
sudo apt update
sudo apt install -y dnsmasq iptables-persistent ufw
```

**Détails :**

- `dnsmasq` : Fournit DHCP + DNS local pour le réseau interne  
- `iptables-persistent` : Sauvegarde automatique des règles iptables au redémarrage  
- `ufw` : Pare-feu simplifié basé sur iptables, utile pour activer le NAT proprement

---

## Configurer dnsmasq

Modifiez le fichier `/etc/dnsmasq.conf` :

```shell
sudo nano /etc/dnsmasq.conf
```

Ajoutez à la fin :

```ini
# Interface LAN (adapter selon votre interface de sortie vers le réseau interne)
interface=enp2s0f0
bind-interfaces

# Plage d'adresses DHCP
dhcp-range=192.168.50.10,192.168.50.100,12h

# Passerelle et DNS
dhcp-option=3,192.168.50.1
dhcp-option=6,192.168.50.1

# Nom de domaine local (optionnel)
domain=lan
```

---

## Assigner une adresse IP statique (Netplan)

Modifiez le fichier de configuration Netplan (dans `/etc/netplan/`).
⚠️ Le fichier peut avoir un nom différent, par exemple `50-cloud-init.yaml`.

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp2s0f0:
      dhcp4: false
      addresses: [192.168.50.1/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8]
      optional: true
      link-local: [ipv4]
      ignore-carrier: true
```

Appliquez la configuration :

```shell
sudo netplan generate && sudo netplan apply
```

Redémarrez ensuite `dnsmasq` :

```shell
sudo systemctl restart dnsmasq
sudo systemctl enable dnsmasq
```

---

## Configurer le NAT (MASQUERADE)

Activez le routage IPv4 :

```shell
sudo nano /etc/sysctl.conf
```

Décommentez ou ajoutez :

```ini
net.ipv4.ip_forward=1
```

Rechargez :

```shell
sudo sysctl -p
```

---

## Configuration UFW

Modifiez `/etc/ufw/sysctl.conf` et assurez-vous que :

```ini
net/ipv4/ip_forward=1
```

Ajoutez en haut de `/etc/ufw/before.rules` avant `*filter` :

```ini
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o enx7c11be123456 -j MASQUERADE
COMMIT
```

Dans `/etc/default/ufw`, vérifiez que :

```ini
DEFAULT_FORWARD_POLICY="ACCEPT"
```

Puis activez UFW :

```shell
sudo ufw enable
```

---

## Automatiser le tethering et la reconfiguration réseau

Pour rendre le routeur **entièrement autonome**, nous allons créer un démon qui :
- détecte l’arrivée d’un iPhone/Android branché en USB ;
- exécute automatiquement `dhclient -v <interface>` pour obtenir une IP ;
- réapplique la configuration réseau et met à jour le NAT.

### 1. Créez le script de surveillance

```shell
sudo nano /usr/local/bin/router-watchdog.sh
```

Collez ceci :

```shell
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
```

Rends-le exécutable :

```shell
sudo chmod +x /usr/local/bin/router-watchdog.sh
```

---

### 2. Créez le service systemd

```shell
sudo nano /etc/systemd/system/router-watchdog.service
```

Collez :

```ini
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
```

Activez le service :

```shell
sudo systemctl daemon-reload
sudo systemctl enable router-watchdog.service
sudo systemctl start router-watchdog.service
```

---

## Vérification

Pour vérifier que tout fonctionne :

```shell
sudo journalctl -u router-watchdog -f
```

ou

```shell
sudo tail -f /var/log/router-watchdog.log
```

Vous devriez voir les événements suivants :
- détection de l’interface USB (`enx...`);
- attribution d’une IP via DHCP (`dhclient`);
- réapplication du NAT (`iptables -t nat -A POSTROUTING`).

---

## Résumé du fonctionnement automatique

| Événement | Action |
|------------|--------|
| iPhone/Android branché en USB | DHCP automatique + NAT appliqué |
| Câble LAN rebranché | `netplan apply` + redémarrage de `dnsmasq` |
| Redémarrage du serveur | Le démon `router-watchdog` reprend tout automatiquement |

---

```author
                                                                                                                                                                PETITt²
```