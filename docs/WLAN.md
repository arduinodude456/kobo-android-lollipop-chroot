# WLAN, Browser und App-Downloads

Android teilt sich den Netzwerkstack mit dem Kobo. Damit Browser, DownloadProvider und Apps „online“ sind, braucht Androids ConnectivityService zusätzlich ein *verbundenes* WLAN. Die WLAN-Brücke liefert genau das:

- **`kobo-wpa --supplicant`** ersetzt `wpa_supplicant`: Androids WifiStateMachine sieht ein verbundenes Netz (SSID des Kobo-WLANs). Verbinden, Passwort, Roaming bleiben beim Kobo. KitKat (`libhardware_legacy/wifi/wifi.c`) sucht den Kontrollsocket des Primär-Interfaces in `/data/system/wpa_supplicant/<iface>` (wenn das Verzeichnis existiert) bzw. `/dev/socket/<iface>` – **nicht** in `/data/misc/wifi/sockets` (das ist nur der Client-Socket-Ordner und der Pfad für Zweit-Interfaces). Die Attrappe lauscht deshalb auf allen vier Pfaden und legt `/data/system/wpa_supplicant` an. Findet Android den Socket nicht, startet WifiStateMachine den Supplicant alle ~11 s neu und der Schalter bleibt bei „Wird eingeschaltet…“.
- **`kobo-wpa --dhcp`** ersetzt `dhcpcd`: liest IP, Gateway und DNS des Hosts und setzt die Properties `dhcp.<iface>.*`.
- **Netz-Schutz in `libkobofb.so`**: Android darf Adressen, Routen und Schnittstellen des Hosts weder löschen noch herunterfahren (`ifc_*`, `SIOCSIF*`, `SIOCADDRT/DELRT`, Schreibzugriffe auf `/proc/sys/net`); solche Aufrufe werden zu No-Ops und in `kobo-net-guard.log` vermerkt.
- **`android.sh`** installiert alles bei jedem Start ins Rootfs (auch in ein bestehendes `rootfs.img`, kein Neuaufbau nötig), schreibt SSID/DNS des Hosts nach `/data/local/tmp/kobo-net.env`, schaltet nach dem Boot per `svc wifi enable` WLAN ein und erlaubt „Unbekannte Quellen“ (APK aus dem Browser).
- **Aktuelle CA-Wurzeln** (`cacerts/`, ca. 120 Zertifikate): KitKat kennt z. B. ISRG Root X1 nicht, sonst scheitert fast jede HTTPS-Seite. Erneuern: `bash scripts/make-cacerts.sh cacert.pem`.

## Benutzung

1. Kobo-WLAN verbinden (KOReader macht das beim Öffnen der Android-Ansicht automatisch, falls es aus ist).
2. Android starten. Nach dem Boot (ca. 40–60 s länger) in Android **Browser** öffnen. Heruntergeladene APKs lassen sich über die Benachrichtigung/den Download-Ordner installieren.
3. Wechselt der Kobo das WLAN, folgt Android innerhalb weniger Sekunden.

Abschalten: `KOBO_NET=0` in `config`. Andere Schnittstelle: `KOBO_NET_IFACE=wlan1`.

## Grenzen

- WLAN in Androids Einstellungen kann keine anderen Netze verbinden; das macht der Kobo.
- Uhrzeit und Zeitzone kommen vom Kobo; stimmt die Uhr nicht, scheitert HTTPS (Zertifikatsfehler).
- Moderne Seiten (TLS 1.3 only, aktuelles JavaScript) laufen im KitKat-Browser nur eingeschränkt; viele aktuelle Apps benötigen neueres Android.
- **Nicht auf echter Hardware getestet.** Getestet sind das wpa_ctrl-Protokoll, die DHCP-Properties und der Netz-Schutz auf dem Host.

## Fehlersuche

```sh
sh android.sh netinfo        # Host-Daten + Android-Seite (net.txt)
```
Dateien in `.adds/android/`: `net.log` (svc/settings), `net.txt` (Properties, `dumpsys connectivity/wifi`, Logs), und im Rootfs `data/local/tmp/kobo-wpa.log` (alle Supplicant-Kommandos) sowie `kobo-net-guard.log` (blockierte Host-Änderungen).
`net.txt` enthält außerdem `kobo-wpa --probe` (öffnet den Socket wie system_server als uid 1000 und nennt je Pfad den genauen Fehler), `ls -ln` der Socket-Ordner, die WLAN-Zeilen aus `android.log` und `dumpsys wifi`.
Typische Befunde: `init.svc.wpa_supplicant` nicht `running` → WLAN in Android nicht eingeschaltet oder `kobo-wpa` fehlt; `dhcp.<iface>.result` leer → Host-WLAN nicht verbunden; `net.dns1` leer → keine `nameserver` in `/etc/resolv.conf` des Kobo.
