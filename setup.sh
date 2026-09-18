#!/usr/bin/env bash
# setup.sh - Configuracion completa de la tarjeta Fenvi FV-AX900Pro (chip AIC8800D80)
# en Linux: driver PCIe WiFi + Bluetooth + punto de acceso (hotspot).
#
# Distros soportadas (se detecta automaticamente):
#   * Arch Linux / CachyOS y derivados  -> paquete AUR aic8800d80-pcie-dkms (o .pkg incluido)
#   * Debian / Ubuntu y derivados (apt) -> compila desde el zip del fabricante via DKMS
#   * Fedora / RHEL y derivados (dnf)   -> compila desde el zip del fabricante via DKMS
#
# Uso:
#   bash setup.sh                # usa la clave por defecto del hotspot
#   AP_PASS=MiClaveSegura bash setup.sh
#   AP_SSID=MiRed bash AP_PASS=... setup.sh
#
# Probado en: CachyOS kernel 7.2.6-1-cachyos (DKMS aic8800/6.4.3.0).
set -euo pipefail

AP_SSID="${AP_SSID:-cachyos-x8664}"
AP_PASS="${AP_PASS:-12345678}"   # <-- CAMBIA esta clave, no la reutilices

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_DIR="$REPO_DIR/driver"
HOTSPOT_DIR="$REPO_DIR/hotspot"
PCI_ID="a69c:8d80"
DRV_NAME="aic8800"
DRV_VER="6.4.3.0"
SRC_DIR="/usr/src/${DRV_NAME}-${DRV_VER}"
VENDOR_ZIP="$DRIVER_DIR/UGREEN-CM958-75615_Linux_Drive_V1.0.zip"

say()  { printf '\n[setup] %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -eq 0 ]]; then
  RUN(){ "$@"; }
else
  if ! need sudo; then echo "No hay sudo"; exit 1; fi
  RUN(){ sudo "$@"; }
fi

# --- Deteccion de distribucion ---------------------------------------------
detect_pm() {
  [[ -r /etc/os-release ]] && . /etc/os-release
  case "${ID:-}" in
    arch|cachyos|manjaro|garuda|endeavouros|artix) echo "arch" ;;
    debian|ubuntu|linuxmint|pop|elementary|raspbian|kali|tuxedo|whonix) echo "apt" ;;
    fedora|rhel|centos|rocky|almalinux|nobara|mageia|openmandriva) echo "dnf" ;;
    *) echo "unknown" ;;
  esac
}
PM=$(detect_pm)

install_pkgs() {
  case "$PM" in
    arch) $RUN pacman -S --needed --noconfirm "$@" ;;
    apt)  $RUN apt-get update >/dev/null; $RUN apt-get install -y "$@" ;;
    dnf)  $RUN dnf install -y "$@" ;;
    *)
      echo "  [ERROR] Distribucion no soportada (ID=${ID:-?})." >&2
      echo "  Soportadas: Arch/CachyOS, Debian/Ubuntu, Fedora/RHEL." >&2
      exit 1 ;;
  esac
}

say "Verificando hardware (esperado: $PCI_ID)"
if ! lspci -nn 2>/dev/null | grep -qi "$PCI_ID"; then
  echo "  [ERROR] No se ve la tarjeta AIC8800D80 en el bus PCIe ($PCI_ID)." >&2
  echo "  Comprueba que este bien insertada o prueba otra ranura." >&2
  exit 1
fi
echo "  OK: tarjeta detectada."

say "Detectando distribucion"
echo "  Paqueteria: $PM"

say "Instalando dependencias (dkms, headers del kernel, clang, hostapd, dnsmasq, firewall)"
HEADERS=""
case "$PM" in
  arch)
    case "$(uname -r)" in
      *-cachyos-lts) HEADERS="linux-cachyos-lts-headers" ;;
      *-cachyos)     HEADERS="linux-cachyos-headers" ;;
      *-lts)         HEADERS="linux-lts-headers" ;;
      *)             HEADERS="linux-headers" ;;
    esac
    install_pkgs base-devel git dkms clang hostapd dnsmasq ufw pciutils "$HEADERS"
    ;;
  apt)
    HEADERS="linux-headers-$(uname -r)"
    if ! install_pkgs dkms build-essential "$HEADERS" clang llvm hostapd dnsmasq ufw unzip patch pciutils 2>/dev/null; then
      echo "  Headers exactos no disponibles; usando linux-headers-generic..."
      install_pkgs dkms build-essential linux-headers-generic clang llvm hostapd dnsmasq ufw unzip patch pciutils
    fi
    ;;
  dnf)
    HEADERS="kernel-devel"
    if ! install_pkgs dkms "$HEADERS" gcc make clang llvm hostapd dnsmasq unzip patch pciutils firewalld 2>/dev/null; then
      echo "  kernel-devel no encontrado; usando kernel-devel-$(uname -r)..."
      install_pkgs dkms "kernel-devel-$(uname -r)" gcc make clang llvm hostapd dnsmasq unzip patch pciutils
    fi
    ;;
esac

say "Instalando driver AIC8800D80 ($DRV_NAME/$DRV_VER)"

install_module_already_done() {
  ls /usr/src/aic8800-* >/dev/null 2>&1 && modinfo aic8800D80_fdrv >/dev/null 2>&1
}

install_driver_arch() {
  if need paru; then
    PKGHELPER=(paru -S --needed --noconfirm)
  elif need yay; then
    PKGHELPER=(yay -S --needed --noconfirm)
  else
    PKGHELPER=("$RUN" pacman -U)
  fi

  if [[ "${PKGHELPER[0]}" == "paru" ]] || [[ "${PKGHELPER[0]}" == "yay" ]]; then
    if ! "${PKGHELPER[@]}" aic8800d80-pcie-dkms; then
      echo "  AUR no disponible; instalando paquete compilado local..."
      $RUN pacman -U "$DRIVER_DIR/aic8800d80-pcie-dkms-6.4.3.0-5-x86_64.pkg.tar.zst"
    fi
  else
    $RUN pacman -U "$DRIVER_DIR/aic8800d80-pcie-dkms-6.4.3.0-5-x86_64.pkg.tar.zst"
  fi
}

install_driver_source() {
  local TMP FDRV BT bad
  TMP="$(mktemp -d)"
  echo "  Desempaquetando codigo del fabricante (zip UGREEN CM958)..."
  ( cd "$TMP" \
    && unzip -q "$VENDOR_ZIP" \
    && unzip -q "Linux/aic8800_linux_drvier.zip" \
    && cd aic8800_linux_drvier \
    && unzip -q aic_btusb.zip \
    && sed -i 's/\r$//' aic_btusb/aic_btusb.h )

  echo "  Aplicando parches de compatibilidad 6.13+/7.1+/7.2+ y Bluetooth..."
  for p in "$DRIVER_DIR"/000[1-6]-*.patch; do
    ( cd "$TMP/aic8800_linux_drvier" && patch -s -p1 -i "$p" )
  done

  FDRV="$TMP/aic8800_linux_drvier/drivers/aic8800/aic8800_fdrv"
  BT="$TMP/aic8800_linux_drvier/aic_btusb"

  echo "  Copiando fuentes a $SRC_DIR..."
  $RUN rm -rf "$SRC_DIR"
  $RUN mkdir -p "$SRC_DIR/aic_btusb"
  while IFS= read -r -d '' f; do
    bad=0
    case "$(basename "$f")" in
      *.o|*.ko|*.mod|*.mod.c|*.cmd|*.orig|*.rej|modules.order|Module.symvers|build.log) bad=1 ;;
    esac
    [[ $bad -eq 1 ]] && continue
    $RUN install -m644 "$f" "$SRC_DIR/"
  done < <(find "$FDRV" -maxdepth 1 -type f -print0)
  while IFS= read -r -d '' f; do
    bad=0
    case "$(basename "$f")" in
      *.o|*.ko|*.mod|*.mod.c|*.cmd|*.orig|*.rej|modules.order|Module.symvers|build.log) bad=1 ;;
    esac
    [[ $bad -eq 1 ]] && continue
    $RUN install -m644 "$f" "$SRC_DIR/aic_btusb/"
  done < <(find "$BT" -maxdepth 1 -type f -print0)

  $RUN sed "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$DRV_VER\"/" "$DRIVER_DIR/dkms.conf" > "$TMP/dkms.conf"
  $RUN install -m644 "$TMP/dkms.conf" "$SRC_DIR/dkms.conf"

  echo "  Instalando firmware, reglas udev y configuración modprobe..."
  if [[ -d "$TMP/aic8800_linux_drvier/fw/aic8800D80" ]]; then
    $RUN mkdir -p /usr/lib/firmware/aic8800D80
    $RUN install -m644 "$TMP"/aic8800_linux_drvier/fw/aic8800D80/* /usr/lib/firmware/aic8800D80/
  fi
  $RUN install -Dm644 "$DRIVER_DIR/aic.rules" /usr/lib/udev/rules.d/70-aic8800d80.rules
  $RUN install -Dm644 "$DRIVER_DIR/aic8800d80-btusb.conf" /usr/lib/modprobe.d/aic8800d80-btusb.conf
  $RUN install -Dm755 "$DRIVER_DIR/aic8800d80-sleep-hook" /usr/lib/systemd/system-sleep/aic8800d80

  echo "  Registrando y compilando modulo en DKMS..."
  $RUN dkms remove -m "$DRV_NAME" -v "$DRV_VER" --all 2>/dev/null || true
  $RUN dkms add -m "$DRV_NAME" -v "$DRV_VER"
  $RUN dkms build -m "$DRV_NAME" -v "$DRV_VER" -k "$(uname -r)"
  $RUN dkms install -m "$DRV_NAME" -v "$DRV_VER" -k "$(uname -r)"
  rm -rf "$TMP"
}

if install_module_already_done; then
  echo "  El modulo ya esta instalado."
elif [[ "$PM" == "arch" ]]; then
  echo "  Usando paquete AUR aic8800d80-pcie-dkms..."
  install_driver_arch
else
  echo "  Compilando desde el codigo del fabricante (DKMS)..."
  install_driver_source
fi

say "Reconstruyendo modulo DKMS para el kernel $(uname -r)"
$RUN dkms autoinstall 2>/dev/null || $RUN dkms install $DRV_NAME/$DRV_VER -k "$(uname -r)"

say "Cargando modulos"
$RUN modprobe aic8800D80_fdrv 2>/dev/null || true
$RUN modprobe aic_btusb 2>/dev/null || true
sleep 2

if modinfo aic8800D80_fdrv >/dev/null 2>&1; then
  echo "  OK: modulo aic8800D80_fdrv cargado."
else
  echo "  [AVISO] El modulo no aparece cargado; revisa 'dkms status' y 'journalctl -k | grep aic'."
  echo "  Si el equipo tiene Secure Boot activo, firma el modulo con MOK:"
  echo "  'sudo mokutil --import <firmware clave>' por UEFI, o desactiva Secure Boot."
fi

# Interfaz por donde sale Internet (para el NAT del hotspot)
WAN="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
WAN="${WAN:-eno1}"

say "Configurando punto de acceso (hostapd + dnsmasq + firewall + sysctl)"
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

# NAT + firewall (idempotente; según lo que tenga la distro)
setup_nat_ufw() {
  if ! $RUN grep -q "10.42.0.0/24" /etc/ufw/before.rules 2>/dev/null; then
    printf '\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.42.0.0/24 -o %s -j MASQUERADE\nCOMMIT\n\n' "$WAN" |
      $RUN tee -a /etc/ufw/before.rules >/dev/null
  fi
  $RUN ufw allow in on wlan0 >/dev/null 2>&1 || true
  $RUN ufw route allow in on wlan0 >/dev/null 2>&1 || true
}

setup_nat_firewalld() {
  $RUN firewall-cmd --permanent --zone=internal --add-interface=wlan0 >/dev/null 2>&1 || true
  $RUN firewall-cmd --permanent --zone=internal --add-service=dhcp >/dev/null 2>&1 || true
  $RUN firewall-cmd --permanent --zone=internal --add-service=dns >/dev/null 2>&1 || true
  $RUN firewall-cmd --permanent --zone=internal --add-masquerade >/dev/null 2>&1 || true
  $RUN firewall-cmd --reload >/dev/null 2>&1 || true
}

setup_nat_iptables() {
  $RUN iptables -t nat -C POSTROUTING -s 10.42.0.0/24 -o "$WAN" -j MASQUERADE 2>/dev/null ||
    $RUN iptables -t nat -A POSTROUTING -s 10.42.0.0/24 -o "$WAN" -j MASQUERADE
  $RUN iptables -C FORWARD -i wlan0 -j ACCEPT 2>/dev/null ||
    $RUN iptables -A FORWARD -i wlan0 -j ACCEPT
  $RUN iptables -C FORWARD -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
    $RUN iptables -A FORWARD -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
}

if need ufw && $RUN ufw status >/dev/null 2>&1; then
  echo "  Firewall: UFW (NAT de la subred 10.42.0.0/24 sale por $WAN)"
  setup_nat_ufw
elif need firewall-cmd && $RUN firewall-cmd --state >/dev/null 2>&1; then
  echo "  Firewall: firewalld (wlan0 en zona internal + masquerade)"
  setup_nat_firewalld
elif need iptables; then
  echo "  Firewall: reglas iptables directas (NAT 10.42.0.0/24 -> $WAN)"
  setup_nat_iptables
else
  echo "  [AVISO] Sin firewall/NAT configurable automaticamente;"
  echo "  configura el NAT a mano si el hotspot no da Internet."
fi

# El hotspot NO arranca al boot (uso manual con hotspot-on / hotspot-off)
$RUN systemctl disable --now hostapd dnsmasq >/dev/null 2>&1 || true

say "Bluetooth: desactivando tethering PAN/NAP (no soportado por el chip AIC8800D80)"
if need nmcli; then
  echo "  Eliminando conexiones de tipo bluetooth (ej. 'bluetooth' / nombre del telefono)..."
  while IFS=: read -r cname ctype; do
    if [[ "$ctype" == "bluetooth" ]]; then
      echo "    conexion borrada: $cname"
      $RUN nmcli connection delete "$cname" >/dev/null 2>&1 || true
    fi
  done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
  $RUN mkdir -p /etc/NetworkManager/conf.d
  printf '[keyfile]\nunmanaged-devices=type:bt\n' |
    $RUN tee /etc/NetworkManager/conf.d/50-no-bluetooth-tether.conf >/dev/null
  $RUN systemctl restart NetworkManager 2>/dev/null || $RUN systemctl reload NetworkManager 2>/dev/null || true
  echo "  NetworkManager: dispositivos bluetooth marcados como no gestionados (sin fila 'Bluetooth' en GNOME)."
fi

if need btmgmt; then
  $RUN tee /usr/local/sbin/aic-bt-class-laptop >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
sleep 6
for i in $(btmgmt info 2>/dev/null | sed -n "s/^hci\([0-9][0-9]*\).*/\1/p"); do
  btmgmt -i "$i" class 1 12 || true
done
SCRIPT
  $RUN chmod +x /usr/local/sbin/aic-bt-class-laptop
  $RUN mkdir -p /etc/systemd/system/bluetooth.service.d
  printf '[Service]\nExecStartPost=/usr/local/sbin/aic-bt-class-laptop\n' |
    $RUN tee /etc/systemd/system/bluetooth.service.d/bt-class-laptop.conf >/dev/null
  $RUN sed -i 's/^#\?Class = .*/Class = 0x00010c/' /etc/bluetooth/main.conf
  $RUN systemctl daemon-reload
  $RUN systemctl restart bluetooth 2>/dev/null || true
  echo "  Clase Bluetooth fijada a Laptop (el telefono mostrara una PC, no un auto)."
fi

if need btmgmt && $RUN test -d /usr/share/wireplumber; then
  $RUN mkdir -p /etc/wireplumber/wireplumber.conf.d
  printf 'monitor.bluez.properties = {\n  bluez5.roles = [ a2dp_sink a2dp_source ]\n}\n' |
    $RUN tee /etc/wireplumber/wireplumber.conf.d/50-no-hfp.conf >/dev/null
  echo "  HandsFree/ManosLibres desactivado (B0 solo audio A2DP: tu PC ya no parece un auto en el telefono)."
  echo "  Aplica con: systemctl --user restart wireplumber  (o reinicia la sesion)"
fi

say "Resumen"
HOTSPOT_CONF=/etc/hostapd/hostapd.conf
if $RUN test -f "$HOTSPOT_CONF"; then
  CUR_SSID=$($RUN sed -n 's/^ssid=//p' "$HOTSPOT_CONF")
  CUR_PASS=$($RUN sed -n 's/^wpa_passphrase=//p' "$HOTSPOT_CONF")
else
  CUR_SSID="$AP_SSID"
  CUR_PASS="$AP_PASS"
fi
echo "  Distribucion:   $PM ($(uname -r))"
echo "  WiFi/Bluetooth: driver DKMS $DRV_NAME/$DRV_VER"
echo "  Red del PC:     gestionada por NetworkManager (conecta tu red como siempre)"
echo "  Hotspot:        manual -> 'hotspot-on' / 'hotspot-off'"
echo "  Hotspot SSID:   ${CUR_SSID:-$AP_SSID}  |  canal 36 (5 GHz); para 2.4 GHz edita /etc/hostapd/hostapd.conf (hw_mode=g, channel=6)"
echo
echo "  Verifica el wifi:  nmcli device status"
echo "  Verifica BT:       bluetoothctl show   (o rfkill list)"

if [[ "$CUR_PASS" == "12345678" ]]; then
  echo
  echo "  [AVISO] Sigue usando la clave por defecto 12345678. Recomendado:"
  echo "  edita /etc/hostapd/hostapd.conf y cambia wpa_passphrase."
fi

exit 0