# Estado del trabajo: Tarjeta WiFi Fenvi FV-AX900Pro (AIC8800D80)

> SESIÓN 18-SEP-2026: estado verificado y funcionando. Todo este setup quedó
> empaquetado en el proyecto Git `fenvi-fv-ax900pro-setup` (setup.sh + driver +
> hotspot) para reinstalar de un tiro tras formatear. Confirmado en vivo:
> wlan0 conectado (FmAlmanzar), modulo `aic8800D80_fdrv` DKMS para
> 7.2.6-1-cachyos, hostapd/dnsmasq desactivados, hotspot manual con
> `hotspot-on` / `hotspot-off`.

Fecha: jueves 17-sep-2026
Sistema: CachyOS (Arch), kernel 7.2.6-1-cachyos
Usuario: niziro

## Hardware detectado
- Controladora de red PCIe en 0000:22:00.0: AIC Semiconductor [a69c:8d80]
- Módulo kernel requerido: aic8800D80_fdrv (DKMS 6.4.3.0)
- El Bluetooth de la misma tarjeta SÍ funciona (aic_btusb) y descarga su firmware.

## Lo que se verificó (todo OK)
1. Driver DKMS compilado para el kernel actual:
   - /lib/modules/7.2.6-1-cachyos/updates/dkms/aic8800D80_fdrv.ko.zst (existe)
   - dkms status: aic8800/6.4.3.0, 7.2.6-1-cachyos: installed
2. Firmware presente en /lib/firmware/aic8800D80/:
   - fmacfw_8800D80_pcie.bin, lmacfw_rf_pcie.bin, fw_patch_8800d80_u02.bin, etc.
3. La tarjeta se enumera en el bus PCIe correctamente (LinkSta: 2.5GT/s x1, ASPM desactivado).

## El problema real
- El kernel carga el driver pero la prueba de hardware DMA FALLA:
  `AICWFDBG(LOGERROR) aicpcie: aic dma done, dma irq failed!`
  `aicwf_pcie_probe: pci set&tst fail`
  `aic8800D80_fdrv 0000:22:00.0: probe with driver aic8800D80_fdrv failed with error -1`
- El MCU/firmware embebido del chip NO arranca: no llega la interrupción de DMA.
- Antes del bloqueo/congelamiento se llenó el log con `PCIE_FW_ERR_BIT` repetido:
  esto indica que el chip quedó en estado de error tras el bloqueo de la PC.

## Intentos hechos (sin éxito, todos por software)
1. Recargar módulos: `modprobe -r aic_btusb`, `modprobe -r aic8800D80_fdrv`,
   `modprobe aic8800D80_fdrv` -> "could not insert ... No such device"
2. Reset del bus PCIe vía sysfs: remove + rescan
   (`echo 1 > /sys/bus/pci/devices/0000:22:00.0/remove` y `echo 1 > /sys/bus/pci/rescan`)
   -> la DMA volvió a fallar igual.
3. Reset de la placa: `echo 1 > /sys/bus/pci/devices/0000:22:00.0/reset`
   -> sin cambio.
4. Forzar bind del driver -> sin cambio, la interfaz wlan0 nunca aparece.

Conclusión: es un estado de ENERGÍA del chip, NO un problema de software.
Un reinicio NORMAL no arregla esto (el PCIe sigue con energía del standby).

## Solución aplicada / pendiente (pasos físicos)
1. Apagar la PC por completo (no reiniciar).
2. Apagar el interruptor de la fuente (PSU) o desenchufar el cable ~30-60 segundos.
3. Si no aparece después, revisar que la tarjeta esté bien insertada o probar otra ranura PCIe.
4. Encender y volver a iniciar sesión.

## Verificación post-reinicio (lo que hay que comprobar al volver)
- `nmcli device status` -> debe aparecer un dispositivo WLAN (wlan0).
- `ip link show` -> interfaz inalámbrica presente.
- `journalctl -k | grep aic8800` -> debe salir "dma irq success" en vez de "failed".
- Conectar WiFi y listo.

## Punto de acceso (Hotspot) — SOLUCIONADO DE VERDAD (17-sep-2026, confirmado con celular)
Estado HOY: el hotspot FUNCIONA. El celular (OnePlus 10T 5G) se conectó, obtuvo
IP por DHCP y navegó (hubo tráfico real en el NAT). SSID `cachyos-x8664`, clave
(la definida en /etc/hostapd/hostapd.conf), WPA2, en **5 GHz canal 36** (configurado así a petición del usuario;
para volver a 2.4 GHz cambiar en /etc/hostapd/hostapd.conf `hw_mode=g` y
`channel=6`), compartiendo internet desde eno1 (cable).
- Nota: en el celular no se puede forzar banda 2.4/5G; la banda se elige AQUÍ en
  el AP cambiando hw_mode/channel y reiniciando hostapd.

### Estado FINAL (última sesión, 17-sep-2026)
- wlan0 volvió a ser GESTIONADA por NetworkManager (se eliminó el conf "sin gestión").
  El interruptor de WiFi on/off del sistema vuelve a funcionar (radio: enabled).
- FmAlmanzar (wifi del PC) restaurado con autoconnect=yes (como antes).
- El hotspot ya NO autoarranca; es un servicio MANUAL (ver "Uso diario" abajo).

### Cómo está montado (para tocar o revertir)
- AP: /etc/hostapd/hostapd.conf -> ssid cachyos-x8664 / hw_mode=a / channel=36
  (5 GHz) / WPA2 (clave en hostapd.conf). Para 2.4 GHz: hw_mode=g y channel=6.
- DHCP/DNS: dnsmasq (/etc/dnsmasq.d/wlan0-hotspot.conf), IP del AP 10.42.0.1/24
  (drop-in en dnsmasq.service.d/10-hotspot-ip.conf repone la IP al arrancar).
- NAT: /etc/ufw/before.rules -> `-A POSTROUTING -s 10.42.0.0/24 -o eno1 -j MASQUERADE`
  y reglas UFW: `ufw allow in on wlan0` y `ufw route allow in on wlan0`.
- Forwarding: /etc/sysctl.d/30-hotspot.conf -> net.ipv4.ip_forward=1.
- Servicios: hostapd y dnsmasq instalados y DESHABILITADOS (no arrancan al boot).
- Firmware: actualizado a la build Dec-05-2025 - g586bc1e8 (antes g934268ae).
  Respaldo del firmware anterior en /root/fw-orig. Unidad fw-trial-revert.service
  (inactiva; restaura el respaldo automáticamente si /root/FW_TRIAL existe; el flag
  se eliminó al confirmar que todo funciona). Los binarios vienen del paquete
  aic8800d80-pcie-dkms: si `pacman -Syu` lo actualiza, volvería el firmware viejo.

### Uso diario
1. Modo normal (PC): el wifi lo maneja NetworkManager como siempre (FmAlmanzar
   autoconecta); el hotspot está apagado.
2. Encender el hotspot:
   - `sudo nmcli radio wifi off`
   - `sudo systemctl start hostapd dnsmasq`
   - El celular se conecta al SSID de hostapd.conf (5 GHz). Internet sale por
     el cable eno1. NO arrancar hostapd con el wifi del PC conectado (conflicto).
3. Apagar el hotspot:
   - `sudo systemctl stop hostapd dnsmasq`
   - `sudo nmcli radio wifi on` (vuelve a conectar FmAlmanzar automáticamente).

### Síntoma y diagnóstico (por qué costó)
- El celular veía la red (visible, WPA2) pero NO conectaba: se asociaba y el driver
  lo soltaba a los ~18 s, sin IP.
- Descartado: canal invisible, handshake WPA (llegaba a completarse), interfaz monitor.
- Causa raíz real: UFW con política "deny (incoming)" descartaba el DHCPDISCOVER del
  celular (origen 0.0.0.0, que NO coincide con la regla 10.42.0.0/24). Sin DHCP el
  celular reintentaba y se desconectaba. Se arregló con `ufw allow in on wlan0`.
- Además el firmware g934268ae no entregaba el plano de datos en modo AP 5 GHz
  (los frames solo aparecían en capturas, no llegaban a los sockets UDP). Se confirmó
  que con g586bc1e8 el plano de datos fluye en 5 GHz y 2.4 GHz.
- El error del kernel "Error while (un)registering debug entry for sta N" es COSMÉTICO
  (fallo al crear/dir debugfs), no corta la conexión.
- Verificación final: el celular (OnePlus 10T 5G) se conectó, obtuvo IP 10.42.0.111
  por DHCP y navegó (contadores del NAT con tráfico real ~241 KB).

## Otras notas
- La contraseña compartida en el chat NO debe reutilizarse: se recomienda cambiarla.
- Si el problema persiste tras el corte de energía total, probablemente sea hardware
  (tarjeta defectuosa o mal asentada) y el siguiente paso sería probarla en otro equipo/ranura.