#!/usr/bin/env bash
# setup.sh - Configuracion completa de la tarjeta Fenvi FV-AX900Pro (chip AIC8800D80)
# en Arch Linux / CachyOS: driver PCIe WiFi + Bluetooth + punto de acceso (hotspot).
#
# Uso:
#   bash setup.sh                # usa la clave por defecto del hotspot
#   AP_PASS=MiClaveSegura bash setup.sh
#   AP_SSID=MiRed bash AP_PASS=... setup.sh
#
# Probado en: CachyOS, kernel 7.2.6-1-cachyos (driver DKMS aic8800/6.4.3.0).
set -euo pipefail

AP_SSID="${AP_SSID:-cachyos-x8664}"
AP_PASS="${AP_PASS:-12345678}"   # <-- CAMBIA esta clave, no la reutilices

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_DIR="$REPO_DIR/driver"
HOTSPOT_DIR="$REPO_DIR/hotspot"
PCI_ID="a69c:8d80"

say()  { printf '\n[setup] %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -eq 0 ]]; then
  RUN(){ "$@"; }
else
  if ! need sudo; then echo "No hay sudo"; exit 1; fi
  RUN(){ sudo "$@"; }
fi

say "Verificando hardware (esperado: $PCI_ID)"
if ! lspci -nn 2>/dev/null | grep -qi "$PCI_ID"; then
  echo "  [ERROR] No se ve la tarjeta AIC8800D80 en el bus PCIe ($PCI_ID)." >&2
  echo "  Comprueba que este bien insertada o prueba otra ranura." >&2
  exit 1
fi
echo "  OK: tarjeta detectada."

say "Instalando dependencias (dkms, headers del kernel, clang, hostapd, dnsmasq, ufw)"
HEADERS=""
case "$(uname -r)" in
  *-cachyos-lts) HEADERS="linux-cachyos-lts-headers" ;;
  *-cachyos)     HEADERS="linux-cachyos-headers" ;;
  *-lts)         HEADERS="linux-lts-headers" ;;
  *)             HEADERS="linux-headers" ;;
esac
$RUN pacman -S --needed --noconfirm \
    base-devel git dkms clang hostapd dnsmasq ufw "$HEADERS" || {
  echo "  [ERROR] No se pudo instalar dependencias. Instala manualmente el paquete '$HEADERS'." >&2
  exit 1
}

say "Instalando driver AIC8800D80 (paquete AUR aic8800d80-pcie-dkms)"

install_module_already_done() {
  ls /usr/src/aic8800-* >/dev/null 2>&1 && modinfo aic8800D80_fdrv >/dev/null 2>&1
}

if install_module_already_done; then
  echo "  El modulo ya esta instalado."
else
  if need paru; then
    PKGHELPER=(paru -S --needed --noconfirm)
  elif need yay; then
    PKGHELPER=(yay -S --needed --noconfirm)
  else
    PKGHELPER=("$RUN" pacman -U)
  fi

  if [[ "${PKGHELPER[0]}" == "paru" ]]; then
    if ! "${PKGHELPER[@]}" aic8800d80-pcie-dkms; then
      echo "  AUR no disponible; instalando paquete compilado local..."
      $RUN pacman -U "$DRIVER_DIR/aic8800d80-pcie-dkms-6.4.3.0-5-x86_64.pkg.tar.zst"
    fi
  elif [[ "${PKGHELPER[0]}" == "yay" ]]; then
    if ! "${PKGHELPER[@]}" aic8800d80-pcie-dkms; then
      echo "  AUR no disponible; instalando paquete compilado local..."
      $RUN pacman -U "$DRIVER_DIR/aic8800d80-pcie-dkms-6.4.3.0-5-x86_64.pkg.tar.zst"
    fi
  else
    $RUN pacman -U "$DRIVER_DIR/aic8800d80-pcie-dkms-6.4.3.0-5-x86_64.pkg.tar.zst"
  fi
fi

say "Reconstruyendo modulo DKMS para el kernel $(uname -r)"
$RUN dkms autoinstall 2>/dev/null || $RUN dkms install aic8800/6.4.3.0 -k "$(uname -r)"

say "Cargando modulos"
$RUN modprobe aic8800D80_fdrv 2>/dev/null || true
$RUN modprobe aic_btusb 2>/dev/null || true
sleep 2

if modinfo aic8800D80_fdrv >/dev/null 2>&1; then
  echo "  OK: modulo aic8800D80_fdrv cargado."
else
  echo "  [AVISO] El modulo no aparece cargado; revisa 'dkms status' y 'journalctl -k | grep aic'."
fi

say "Configurando punto de acceso (hostapd + dnsmasq + ufw + sysctl)"
if $RUN test -f /etc/hostapd/hostapd.conf; then
  echo "  /etc/hostapd/hostapd.conf ya existe: se conserva su SSID y contraseña actuales."
else
  $RUN sed "s/^wpa_passphrase=.*/wpa_passphrase=${AP_PASS}/; s/^ssid=.*/ssid=${AP_SSID}/" \
    "$HOTSPOT_DIR/hostapd.conf" > /tmp/.hostapd.conf.$$
  $RUN install -Dm600 -o root -g root /tmp/.hostapd.conf.$$ /etc/hostapd/hostapd.conf
  rm -f /tmp/.hostapd.conf.$$
fi
$RUN install -Dm644 "$HOTSPOT_DIR/dnsmasq-wlan0-hotspot.conf" /etc/dnsmasq.d/wlan0-hotspot.conf
$RUN mkdir -p /etc/systemd/system/dnsmasq.service.d
$RUN install -Dm644 "$HOTSPOT_DIR/dnsmasq-10-hotspot-ip.conf" /etc/systemd/system/dnsmasq.service.d/10-hotspot-ip.conf
$RUN install -Dm644 "$HOTSPOT_DIR/30-hotspot.conf" /etc/sysctl.d/30-hotspot.conf
$RUN sysctl --system >/dev/null 2>&1 || true
$RUN install -Dm755 "$HOTSPOT_DIR/hotspot-on.sh" /usr/local/bin/hotspot-on
$RUN install -Dm755 "$HOTSPOT_DIR/hotspot-off.sh" /usr/local/bin/hotspot-off

$RUN systemctl daemon-reload

# NAT + firewall (idempotente)
if $RUN ufw status >/dev/null 2>&1 && $RUN grep -q "IPV6=" /etc/default/ufw 2>/dev/null; then
  if ! $RUN grep -q "10.42.0.0/24" /etc/ufw/before.rules 2>/dev/null; then
    printf '\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.42.0.0/24 -o eno1 -j MASQUERADE\nCOMMIT\n\n' |
      $RUN tee -a /etc/ufw/before.rules >/dev/null
  fi
  $RUN ufw allow in on wlan0 >/dev/null 2>&1 || true
  $RUN ufw route allow in on wlan0 >/dev/null 2>&1 || true
fi

# El hotspot NO arranca al boot (uso manual con hotspot-on / hotspot-off)
$RUN systemctl disable --now hostapd dnsmasq >/dev/null 2>&1 || true

say "Resumen"
HOTSPOT_CONF=/etc/hostapd/hostapd.conf
if $RUN test -f "$HOTSPOT_CONF"; then
  CUR_SSID=$($RUN sed -n 's/^ssid=//p' "$HOTSPOT_CONF")
  CUR_PASS=$($RUN sed -n 's/^wpa_passphrase=//p' "$HOTSPOT_CONF")
else
  CUR_SSID="$AP_SSID"
  CUR_PASS="$AP_PASS"
fi
echo "  WiFi/Bluetooth:  driver DKMS aic8800/6.4.3.0 para kernel $(uname -r)"
echo "  Red del PC:      gestionada por NetworkManager (conecta tu red como siempre)"
echo "  Hotspot:         manual -> 'hotspot-on' / 'hotspot-off'"
echo "  Hotspot SSID:    ${CUR_SSID:-$AP_SSID}  |  canal 36 (5 GHz); para 2.4 GHz edita /etc/hostapd/hostapd.conf (hw_mode=g, channel=6)"
echo
echo "  Verifica el wifi:  nmcli device status"
echo "  Verifica BT:       bluetoothctl show   (o rfkill list)"

if [[ "$CUR_PASS" == "12345678" ]]; then
  echo
  echo "  [AVISO] Sigue usando la clave por defecto 12345678. Recomendado:"
  echo "  edita /etc/hostapd/hostapd.conf y cambia wpa_passphrase."
fi

exit 0