# Fenvi FV-AX900Pro setup (chip AIC8800D80) — Arch/CachyOS

Script y documentación para que la tarjeta **Fenvi FV-AX900Pro** (controlador PCIe
`AIC Semiconductor [a69c:8d80]`, mismo chip que la Ugreen CM958) funcione de una
tras un formateo/respaldo en **Arch Linux / CachyOS**:

- **WiFi PCIe** (wlan0) con driver DKMS `aic8800D80_fdrv` + firmware del fabricante.
- **Bluetooth** integrado en la misma tarjeta con el módulo `aic_btusb`.
- **Punto de acceso (hotspot)** en 5 GHz (hostapd + dnsmasq + NAT con UFW).

## ¿Por qué existen los parches y qué pasó con "kernel 6" vs "kernel 7"?

La versión del driver **`6.4.3.0` NO es una versión de kernel 6**: es la versión
del driver del fabricante. El kernel sí fue el problema, porque el árbol original
no compilaba con kernels modernos:

- `0005-linux-7.1-compat.patch` y `0006-linux-7.2-compat.patch` → compatibilidad
  con **kernel 7.x** (los que usa CachyOS hoy).
- `0001-linux-6.13-plus-compat.patch` → compatibilidad con kernels 6.13+.
- `0002`, `0003`, `0004` → modalias PCI, logs, y arreglos de Bluetooth con BlueZ.

`dkms` recompila el módulo de forma automática en cada actualización de kernel,
siempre que tengas instalados los headers correspondientes (`linux-cachyos-headers`).

## Contenido

```
.
├── setup.sh          # Instalador completo (driver + hotspot), listo para ejecutar
├── driver/           # Paquete AUR aic8800d80-pcie-dkms 6.4.3.0-5
│   ├── PKGBUILD        # Recompilar desde el zip del fabricante (para kernels futuros)
│   ├── *.patch         # Parches de compatibilidad 6.13+/7.1+/7.2+ y BT
│   └── *.pkg.tar.zst   # Paquete ya compilado (fallback sin AUR ni macro pak)
├── hotspot/          # Configuración del punto de acceso
│   ├── hostapd.conf                # AP con SSID/contraseña (WPA2, 5 GHz)
│   ├── dnsmasq-wlan0-hotspot.conf  # DHCP/DNS del AP
│   ├── dnsmasq-10-hotspot-ip.conf  # drop-in que repone la IP 10.42.0.1
│   ├── 30-hotspot.conf             # net.ipv4.ip_forward=1
│   └── hotspot-on.sh / hotspot-off.sh
└── docs/wifi-fenvi-estado.md     # Bitácora completa del trabajo (hardware, diagnósticos, causas raíz)
```

## Instalación en un solo comando

Solo copia, pega y Enter. Clona a `/tmp`, ejecuta el instalador y se limpia solo
(pedirá `sudo` y no hace falta descargar nada a mano):

```bash
git clone https://github.com/N1ZIRO/fenvi-fv-ax900pro-setup /tmp/fenvi-fv-ax900pro-setup && cd /tmp/fenvi-fv-ax900pro-setup && bash setup.sh && cd ~ && rm -rf /tmp/fenvi-fv-ax900pro-setup
```

> **Importante:** si ya existe `/etc/hostapd/hostapd.conf`, el instalador lo conserva
> tal cual: **no cambia la contraseña ni el SSID** que ya tenga la máquina.

Con tu propia contraseña para el hotspot (evita el aviso de la clave por defecto `12345678`):

```bash
git clone https://github.com/N1ZIRO/fenvi-fv-ax900pro-setup /tmp/fenvi-fv-ax900pro-setup && cd /tmp/fenvi-fv-ax900pro-setup && AP_PASS="TuClaveSegura" bash setup.sh && cd ~ && rm -rf /tmp/fenvi-fv-ax900pro-setup
```

Requisito: red/dispositivo para instalar deps (base-devel, dkms, headers, hostapd,
dnsmasq) — p. ej. el cable ethernet.

## Uso tras formatear

Instalación manual (equivalente al comando de arriba):

```bash
git clone https://github.com/N1ZIRO/fenvi-fv-ax900pro-setup.git
cd fenvi-fv-ax900pro-setup

# Instalación con la password del hotspot que quieras
sudo bash setup.sh          # (o AP_PASS=MiClave bash setup.sh)

# Conectar el PC a tu red: sistema -> Bluetooth/WiFi o:
nmcli device wifi connect "TU_RED" password "TU_CLAVE"

# Punto de acceso (manual):
hotspot-on   # servicio manual; conecta tu celular al SSID definido
hotspot-off  # vuelve a NetworkManager
```

### Notas

- El driver se instala **desde AUR** (`aic8800d80-pcie-dkms`) si tienes paru/yay;
  si no, se instala el `.pkg.tar.zst` incluido. Con DKMS, los parches quedan en
  `/usr/src/aic8800-6.4.3.0/` y los rebuilt de kernel nuevos son automáticos.
- Si en un futuro un kernel rompe la compilación, recompila con:
  ```bash
  cd driver && makepkg -sf --nodeps  # requiere el zip del fabricante (incluido aquí) + base-devel
  sudo pacman -U aic8800d80-pcie-dkms-*.pkg.tar.zst
  ```
- La tarjeta es **WiFi 6 / Bluetooth 5.4** (chip AIC8800D80); `lspci` reporta
  "AIC Semiconductor" sin nombre comercial.
- Lee `docs/wifi-fenvi-estado.md` para entender cómo se resolvieron los problemas
  (DMA del chip, firmware `g586bc1e8`, UFW bloqueando el DHCP del hotspot, etc.).