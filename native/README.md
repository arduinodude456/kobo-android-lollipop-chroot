# Native Framebuffer- und VNC-Brücke

Diese ursprünglichen C-Implementierungen stehen unter MIT. Die Hosttests führen tatsächlich kompilierte Programme und echte RFB-Sockets aus. **Weder Android-Boot noch Kobo-Hardware sind damit getestet.** Die lokale Testmaschine ist AArch64 mit glibc, nicht der ARM32-Bionic-Zielrechner.

## Bauen

```sh
make -C native
make -C native STATIC=0
make -C native CC=arm-linux-musleabihf-gcc BUILD_DIR=build-arm kobo-vnc
python3 -m unittest discover -s tests -p test_native.py -v
```

`CC`, `CPPFLAGS`, `CFLAGS`, `LDFLAGS`, `BUILD_DIR` und `STATIC` sind überschreibbar. Standardausgaben sind `native/build/libkobofb.so` und `native/build/kobo-vnc`. Der Server benötigt keine Fremdbibliotheken. Eine glibc-/musl-Preloadbibliothek ist **nicht** Bionic-kompatibel: Für Android ausschließlich den AOSP-Build mit `native/Android.mk` verwenden. Dieser definiert die gemeinsame Bionic-Bibliothek `libkobofb` und die statischen Bionic-Programme `kobo-vnc` und `kobo-container`.

## Laufzeitschnittstelle

```sh
kobo-vnc --check
kobo-vnc --shared /pfad/run/shared --input-dir /pfad/rootfs/dev/input --port 5963
# Ausschließlich für Hosttests: Eingabe ausdrücklich deaktivieren.
kobo-vnc --shared /tmp/kobo-shared --no-input --width 600 --height 800 --port 5963
```

`--help` beschreibt die Optionen. Die Standardabmessungen sind 600 × 800; Server-Optionen beziehungsweise `KOBO_FB_WIDTH` und `KOBO_FB_HEIGHT` erlauben Werte von 1 bis 4096. Server und Shim müssen identische Abmessungen verwenden. Bestehende ungültige Dateien werden nicht still abgeschnitten. Das mitgelieferte Produkt und der Starter verwenden fest die niedrige Standardauflösung.

Zwei RGB565-Bildseiten benötigen 1.920.000 Byte, das letzte Serverbild zusätzlich 960.000 Byte und eine Konvertierungszeile höchstens 2.400 Byte. Das ist nur der Bildtransport, nicht der gesamte Android-Speicherbedarf.

Die gemeinsamen Dateien werden vor Listener und Eingabeinitialisierung angelegt. Der Launcher wartet zusätzlich auf beide Eingabe-Eventnodes. Root setzt `fb.bin` und `fb.meta` auf `1000:1003`, Modus `0660`. Das Verzeichnis muss für diese UID/GID erreichbar sein und im RAM liegen. Der Input-Pfad muss ein **privates** Verzeichnis sein, niemals das Host-`/dev/input`. Finale Symlink-Komponenten der gemeinsamen Dateien werden nicht verfolgt; das Elternverzeichnis muss trotzdem vertrauenswürdig sein.

## Framebuffer-Vertrag

Der Shim leitet `/dev/fb0` und `/dev/graphics/fb0` nach `/dev/kobo/fb.bin` um. Für Hosttests überschreibt `KOBO_FB_DIR` dieses Verzeichnis. Relative `openat`-Aufrufe aus `/dev` oder `/dev/graphics` werden ebenfalls erkannt. Normale Dateioperationen und fremde ioctls werden über Linux-Syscalls weitergegeben. Geräte-/Inode-Vergleich erkennt auch `dup`, `fcntl(F_DUPFD)` und anderweitig übergebene Deskriptoren. Der Bildspeicher bleibt ein gewöhnliches dateibasiertes `MAP_SHARED`-Mapping.

Unterstützt werden Framebuffer-GET-Abfragen, validierte RGB565-PUT-/PAN-Aufrufe, Blanking und emuliertes Vblank. Modusänderungen werden abgewiesen. Vblank ist ein 16-ms-Software-Yield, keine echte Display-Synchronisation. `yoffset` darf von 0 bis einschließlich Bildhöhe reichen; vollständige Seiten beginnen bei 0 und Bildhöhe.

`kobo_fb.h` definiert die feste 64-Byte-ABI von `fb.meta`: Little-Endian-32-Bit-Felder für Magic `0x4b464231`, Version `1`, Headergröße `64`, Breite, Höhe, Byte-Stride, yoffset, umlaufenden Framezähler, Sequenz und sieben reservierte Nullfelder. Die Pixeldatei enthält ausschließlich zwei dicht gepackte Little-Endian-RGB565-Seiten. Der Header steht **nicht** vor den Pixeln.

Metadaten-Schreiber verwenden `flock(LOCK_EX)` und eine ungerade/gerade Sequenz mit Speicherbarrieren. Leser verwenden den Snapshot-Helfer. Der Framezähler zählt akzeptierte, nicht als Test markierte PUT-/PAN-Aufrufe. Direkte Pixeländerungen müssen den Zähler nicht erhöhen; deshalb vergleicht der Server bei ausstehenden Updates auch den Pixelinhalt.

## RFB und Eingaben

Der RFB-3.8-Server bindet ausschließlich IPv4-Loopback `127.0.0.1`, standardmäßig Port 5963, mit einem aktiven Client. Es gibt keine Option für eine externe Bind-Adresse, keinen Webserver und kein Passwort. Lokalen Prozessen muss vertraut werden; den Port nicht ungeschützt weiterleiten.

Raw-Encoding unterstützt RGB565 sowie 24-/32-bpp-RGB888 mit validierter Kanalreihenfolge und Endianness. Ungültige Pixelformate, überlappende Masken, Koordinaten, Nachrichtentypen oder zu große Daten werden durch Trennen des Clients abgewiesen. Transfer-Timeout: insgesamt fünf Sekunden. Grenzen: 128 Encodings und 64 KiB Clipboarddaten; Clipboard wird verworfen. Ein fehlerhafter Client beendet nicht den Listener.

Inkrementelle Anfragen bleiben bis zur Bildänderung ausstehend. Gleichzeitig werden Eingaben spätestens im nächsten 50-ms-Poll bearbeitet. Übertragen wird der kleinste zusammenhängende Bereich geänderter Zeilen im angefragten Rechteck. Das ist keine Optimierung auf einzelne Spalten. Eine volle Anfrage kann eine ausstehende inkrementelle Anfrage ersetzen. Konkurrierende Zeichenoperationen können erst im nächsten Update sichtbar werden.

Die Eingabe verlangt `/dev/uinput` beziehungsweise `/dev/input/uinput`. Der Server erstellt eigene Legacy-`uinput_user_dev`-Touchscreen- und Tastaturgeräte, sucht ausschließlich deren eindeutige Namen in `/sys/class/input` und legt nur ihre Eventnodes im privaten Ziel an, Modus `0660`, Eigentümer `1000:1004`. Es gibt keine sysfs-Schreibzugriffe und keine Weitergabe echter Kobo-Eingabegeräte. Bei geordnetem Ende werden eigene Nodes und Geräte entfernt.

Touch ist Single-Touch über `EV_ABS`, `ABS_X/Y`, `BTN_TOUCH` und `INPUT_PROP_DIRECT`. Koordinaten werden begrenzt. Escape wird zu Android-Zurück, Home zu Home, F1/Menu zu Menü. Pfeile, Enter, Backspace, Delete, Buchstaben, Zahlen und übliche Modifikatoren werden unterstützt. Beim Clientabbruch werden gehaltene Tasten losgelassen. Unicode-Paste, IME-Komposition und Multitouch sind nicht implementiert.

## Echte Vorprüfung und verbleibende Prüfung

`--check` prüft Binder-Protokoll **7 oder 8** für den KitKat-ARM32-Userspace, Ashmem-Set/Get-Size-ioctls, Erzeugen/Entfernen beider uinput-Geräte und die Erstellung von Mount-/PID-Namespaces in einem Kindprozess. Der Kobo-Kernel kann bei diesem Userspace Protokoll 8 melden; dieses wird deshalb akzeptiert und anschließend durch den echten Android-Frameworkstart validiert. Pfade: `KOBO_BINDER_DEVICE` und `KOBO_ASHMEM_DEVICE`. Unbekannte Binder-Protokolle, fehlende Geräte, verweigerte Operationen oder fehlende Namespaces führen zum Fehler. `--check --no-input` ist ungültig. Die Prüfung lädt keine Module, mountet keine Dateisysteme und beweist keinen Android-Boot.

Die KitKat-Header wurden gezielt geprüft: [fcntl.h] enthält Fortify-Inlines; der Interposer deaktiviert `_FORTIFY_SOURCE` vor den Includes. [ioctl.h] verwendet `int` für den Request und wird über `__BIONIC__` berücksichtigt. [syscall.h] enthält die benötigten `SYS_*`-Aliase. [uinput.h] enthält die Legacy-API, aber kein `UI_SET_PROPBIT`; der Code ergänzt die fehlende Konstante sowie `INPUT_PROP_DIRECT`. Es werden weder `accept4` noch stat-Zeit64-Felder oder libatomic benötigt. Diese Headerprüfung ist **kein ARM32-Bionic-Compiler-/Linkertest**. Der gepinnte API-19-NDK-Build und ein Gerätetest bleiben erforderlich.

[fcntl.h]: https://android.googlesource.com/platform/bionic/+/android-4.4.4_r2/libc/include/fcntl.h
[ioctl.h]: https://android.googlesource.com/platform/bionic/+/android-4.4.4_r2/libc/include/sys/ioctl.h
[syscall.h]: https://android.googlesource.com/platform/bionic/+/android-4.4.4_r2/libc/include/sys/syscall.h
[uinput.h]: https://android.googlesource.com/platform/bionic/+/android-5.0.2_r1/libc/kernel/common/linux/uinput.h
