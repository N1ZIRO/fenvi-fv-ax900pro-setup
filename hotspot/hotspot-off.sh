#!/usr/bin/env bash
# Apaga el punto de acceso y devuelve el wifi del PC a NetworkManager.
set -euo pipefail

systemctl stop hostapd dnsmasq
nmcli radio wifi on
echo "[OK] Hotspot apagado. NetworkManager vuelve a conectar tu red automaticamente."