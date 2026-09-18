#!/usr/bin/env bash
# Enciende el punto de acceso (hotspot) en wlan0.
# Requiere: configuracion hecha por setup.sh. NO debe haber wifi del PC conectado.
set -euo pipefail

nmcli radio wifi off
systemctl start hostapd dnsmasq
echo "[OK] Hotspot activo: SSID de /etc/hostapd/hostapd.conf. Internet sale por el cable (eno1)."