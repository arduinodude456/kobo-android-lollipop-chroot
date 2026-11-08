# Android KitKat (4.4 / API 19) für Kobo Libra Colour – experimenteller Chroot

Dieses Repository paketiert ein vorgefertigtes Android-KitKat-ARMv7-Systemimage aus dem offiziellen Android-SDK für **API 19**. Der Build lädt das fest gepinnte SDK-Image und das Android-NDK r10e herunter, baut Kobo-spezifische native Helfer, passt Ramdisk und Properties an und erzeugt ein ext4-Rootfs mit KOReader-/AppDock-Anbindung. **Es gibt keinen AOSP-Vollbuild.**

**Keine Kobo-Ersatzfirmware:** Android läuft als Chroot auf dem vorhandenen Kobo-Linux-Kernel. Das Projekt flasht keinen Kernel und keinen Bootloader. Das SDK-Image wurde für einen ARM-Android-Emulator gebaut, nicht für den Libra Colour. Ein erfolgreicher Build oder QEMU-Boot beweist deshalb noch keinen vollständigen Boot auf echter Kobo-Firmware.

## Paket bauen und herunterladen

1. Stelle sicher, dass die Workflow-Datei unter `.github/workflows/build.yml` im Standardbranch liegt und GitHub Actions aktiviert ist.
2. Öffne im GitHub-Reiter **Actions** den Workflow **Android KitKat API-19 ARM chroot for Kobo (experimental)** und wähle **Run workflow**. Pushes auf `main` und Pull Requests führen nur die schnellen Hosttests aus.
3. Nach einem erfolgreichen Lauf lade das Artefakt **kobo-android-kitkat-arm32** herunter. Darin liegen `android-kobo.zip` mit den `.adds/`-Installationsdateien und das alternative `.tar.gz`-Paket.

Der Build prüft SDK- und NDK-Archive gegen feste SHA-256-Prüfsummen. Diagnoselogs und Herkunftsnachweise werden zusätzlich als **android-build-provenance-and-logs** hochgeladen.

## Was das Paket enthält – und was nicht

Das SDK-Archiv enthält ein generisches Android-KitKat-API-19-ARM-EABI-v7a-Systemimage. Der Build übernimmt dessen `/system`-Partition und Ramdisk, ersetzt die Emulator-Init-Konfiguration durch eine isolierte Kobo-Chroot-Konfiguration, setzt konservative Dalvik-Heap-Limits und Software-EGL und entfernt Emulator-Grafikshim-Bibliotheken. Mit NDK r10e werden `libkobofb.so`, `kobo-vnc` und `kobo-container` gebaut. Danach werden Rootfs, Starter, KOReader-Plugin, Prüfsummen und Provenienz paketiert.

Die Chroot-Init-Konfiguration übernimmt jetzt die entscheidende QEMU-Bootfolge: auf `fs` `ro.crypto.state=unencrypted` setzen und `nonencrypted` triggern, danach `late_start` starten und bei `post-fs-data` `vold.post_fs_data_done` setzen. `healthd` wird – wie im bootenden KitKat-Stock-Init – als `core`-Dienst vor `servicemanager` deklariert, damit `batteryproperties` vor dem Frameworkstart verfügbar ist. Zusätzlich bindet die Chroot `devpts` für PTYs ein. Das sind gezielte Übernahmen aus der QEMU-Ramdisk, aber noch kein Nachweis eines erfolgreichen Boots auf dem Kobo.

Das SDK-Systemimage bleibt ein generischer Emulator-Userspace und kein Kobo-ROM. Der Libra Colour startet Kobo-Linux und erhält Android hier nur als Chroot-Userspace. Android-GSIs sind kein Ersatz: Sie setzen ein entsperrtes, Treble-fähiges Gerät mit passender Android-Basis voraus.

## RAM-schonender Ansatz

Die Android-Anzeige bleibt bei 600 × 800 Pixeln und RGB565 mit zwei Bildseiten. Die VNC-Brücke benötigt keine externe VNC-Bibliothek. KOReader zeigt das Bild ohne zusätzliche Desktop-Umgebung an. Niedrige Dalvik-Heap-Limits, Low-RAM-Einstellungen, deaktivierte Animationen und eine reduzierte Grafik-Konfiguration sollen unnötige Last begrenzen.

Damit ist Android aber nicht auf wenige Megabyte reduziert: Zygote, Systemserver, SurfaceFlinger, notwendige Framework-Dienste und Apps benötigen weiterhin Speicher. Es gibt keine Garantie gegen Speicherknappheit bei parallel laufendem Nickel/KOReader. E-Ink begrenzt die wahrnehmbare Bildrate; schnelle Spiele und flüssiges Video sind kein Ziel. Der Bildpfad ist auf möglichst hohe Bildrate getrimmt (siehe „Bildrate“ in [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md)); 10 FPS sind auf dem Gerät noch nicht gemessen. Maßnahmen gegen Langsamkeit (fsync, Mountoptionen, CPU-Governor, Dalvik-Dexopt, Logging) und ihre Schalter stehen in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Auf dem Kobo starten

Das von Actions erzeugte Installationspaket entpacken und `.adds/` auf den Kobo kopieren. KOReader muss bereits installiert sein. Das Plugin ergänzt das Werkzeugmenü um **Android KitKat 4.4 (Chroot)**. Der erste Start prüft und entpackt das Rootfs. Das Image enthält danach auch persistente Android-App-Daten.

Manuell aus einer Kobo-Root-Shell:

```sh
cd /mnt/onboard/.adds/android
sh install.sh
sh android.sh check
sh android.sh start
sh android.sh exec getprop sys.boot_completed
sh android.sh stop
```

`sys.boot_completed` muss schließlich `1` ergeben. Ein offener VNC-Port oder sichtbares Bild allein ist kein vollständiger Bootnachweis. Vor USB-Datenträgermodus oder Firmware-Update Android unbedingt stoppen. Vollständige Installation, APK-Sideloading, Logs und Fehlerbehebung stehen in [docs/KOBO.md](docs/KOBO.md).

## WLAN, Browser und App-Downloads

Android nutzt das WLAN des Kobo (Browser, Downloads, APK-Installation). Einrichtung und Fehlersuche: [docs/WLAN.md](docs/WLAN.md).

## Voraussetzungen und Sicherheit

Erforderlich sind Root-Rechte, ein Binder-Treiber mit von der Shim-Library unterstützter ABI, Ashmem, `uinput`, Loop-Geräte und ext4. Der Starter verwendet PID-/Mount-Namespaces, wenn der Kernel sie unterstützt. Auf älteren Kobo-Kerneln ist standardmäßig ein weniger isolierter Chroot-Fallback aktiv; dabei teilen Android und Kobo Mount- und PID-Namespace. Keine unpassenden Kernelmodule laden und keine Kernel- oder Firmwarepartitionen überschreiben.

VNC lauscht nur auf `127.0.0.1:5963`. Die echten Kobo-Touch- und Framebuffer-Geräte werden nicht in Android eingebunden. Im Namespace-Fallback teilen Android-Prozesse zusätzlich Mount- und PID-Namespace mit dem Host; ein Fehler kann dann den Kobo beeinflussen. Android teilt sich immer Kernel und Netzwerkstack mit dem Host. KitKat ist veraltet und unsicher für untrusted Apps; nur mit vertrauenswürdigen Apps experimentieren (WLAN-Brücke abschaltbar mit `KOBO_NET=0`, siehe [docs/WLAN.md](docs/WLAN.md)) und keine persönlichen Konten einrichten. Vor dem ersten Test ein Backup anlegen. Belegte Hardwaregrenzen stehen in [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md).

## Lokale Prüfungen

Auf Linux mit GCC, Make, Python 3 und LuaJIT:

```sh
make -C native clean all
python3 -m unittest discover -s tests -p 'test_*.py' -v
luajit tests/test_lua.lua
shellcheck -S warning runtime/*.sh scripts/*.sh
```

Die Hosttests prüfen Fake-Framebuffer, RFB-Protokoll und Pixelformate, beschädigte Eingaben, Installer, Lua-Parser und Buildskripte. Sie starten Android nicht. Ein echter Kobo-Boot ist weiterhin separat zu verifizieren; Details stehen in [docs/TESTSTATUS.md](docs/TESTSTATUS.md).

## Lizenzen

Der Integrationscode steht unter MIT; siehe [LICENSE](LICENSE). Android- und SDK/NDK-Komponenten behalten ihre jeweiligen Upstream-Lizenzen und Hinweise. Der Build übernimmt den SDK-Hinweis aus dem Image.
