# Auf dem Kobo verwenden

Dieses Dokument beschreibt das **von GitHub Actions erzeugte Installationspaket**, nicht das Quellcode-ZIP, das in das Repository gehört. Der Betrieb ist experimentell. KOReader muss auf dem Kobo bereits funktionieren und Root-Rechte haben.

## Installation

Android vorher beenden und wichtige Kobo-Daten sichern. Nach dem Download des GitHub-Artefakts `kobo-android-kitkat-arm32` dessen enthaltene Datei `android-kobo.zip` auf dem Computer entpacken und ihren `.adds`-Inhalt nach `/mnt/onboard/.adds` kopieren. Dabei auch versteckte Ordner anzeigen lassen. Das ergibt insbesondere `.adds/android/android.sh` und `.adds/koreader/plugins/android.koplugin/main.lua`. Bei einer abweichenden KOReader-Installation den Plugin-Ordner manuell in deren `plugins`-Verzeichnis legen.

Nach dem sicheren Trennen der USB-Verbindung KOReader neu starten. Das Plugin ergänzt im Werkzeugmenü **Android KitKat 4.4 (Chroot)**. Es ruft denselben Starter auf wie AppDock. Beim ersten Start wird das komprimierte Rootfs geprüft und entpackt. Dafür zusätzlich zum heruntergeladenen Paket Platz für das unkomprimierte Image und mindestens 64 MiB Reserve lassen.

Beim Wechsel vom bisherigen API-21-Testimage auf KitKat/API 19 zuerst Android stoppen und das alte `rootfs.img` sichern. Der Installer überschreibt ein vorhandenes Image absichtlich nicht. Erst nach erfolgreicher Sicherung das alte `rootfs.img` entfernen und `sh install.sh` ausführen; die alten API-21-Appdaten sind nicht automatisch mit dem neuen API-19-System kompatibel.

Alternativ von einer Root-Shell auf dem Kobo aus:

```sh
cd /mnt/onboard/.adds/android
sh install.sh
sh android.sh check
sh android.sh start
```

Danach die KOReader-Ansicht öffnen. Für eine bestehende AppDock-Integration die mitgelieferte `appdock_android.lua` in den Lua-Suchpfad legen und aufrufen:

```lua
require("appdock_android").open()
```

Die Lua-Datei wird außerdem unter `.adds/android/lua/` installiert. Eine bestehende `appdock_geodash`- oder TIC-80-Konfiguration wird nicht weiterverwendet.

## Bedienung

Die Ansicht zeigt das 600 × 800 große Android-Bild ohne teure Hochskalierung zentriert im Hochformat. Tippen und Wischen gehen an Android. Darunter liegen Zurück, Home, Menü und Beenden. Beenden schließt die Ansicht und lässt den Starter Android stoppen. Das Bild wird mit KOReaders normalem UI-Refresh aktualisiert; E-Ink ist nicht für flüssige Android-Animationen geeignet.

Ein VNC-Bild beweist zunächst nur, dass die Brücke läuft. Android kann währenddessen noch booten. Für den tatsächlichen Framework-Bootstatus:

```sh
sh android.sh exec getprop sys.boot_completed
```

Erwartet wird schließlich `1`. Bleibt das aus, ist Android nicht vollständig gebootet. Den Start nicht allein wegen eines schwarzen oder weißen Bildes als erfolgreich ansehen.

## APKs und Android-Daten

Es werden keine APKs automatisch aus dem Internet geladen. Für eine vertrauenswürdige, Android-KitKat 4.4-/API-19-kompatible ARM32-APK kann man sie bei laufendem Android vom Host in das Datenverzeichnis kopieren und lokal installieren:

```sh
cp /mnt/onboard/meine-app.apk /mnt/onboard/.adds/android/run/rootfs/data/local/tmp/app.apk
sh android.sh exec pm install /data/local/tmp/app.apk
```

`pm install` erst nach abgeschlossenem Boot verwenden. Die App muss ARMv7 beziehungsweise `armeabi-v7a` oder eine passende reine Java-APK unterstützen. Aktuelle Apps benötigen häufig neuere Android-Versionen und laufen nicht. Das Image enthält keine Google-Play-Dienste; moderne Browser, DRM, GPU-intensive Apps und aktuelle TLS-Verbindungen werden nicht zugesichert.

Die Android-Daten liegen im ext4-Image. Vor einem Update `sh android.sh stop` ausführen und `rootfs.img` auf dem Computer sichern. Den Installer nicht zum Zurücksetzen benutzen: Ein vorhandenes Image wird absichtlich nicht überschrieben. Ein frisches Image bedeutet ein frisches Android einschließlich Verlust bisheriger App-Daten, wenn das alte Image nicht gesichert ist.

## Fehler verstehen

Das Hauptlog ist `/mnt/onboard/.adds/android/android.log`. Ein erfolgreicher `check` ist nur eine Kernel-Vorprüfung. Ein Fehler bei Binder, Ashmem, `uinput`, ext4 oder Loop ist ein echter Blocker, kein fehlendes Lua-Modul. Fehlen PID-/Mount-Namespaces, verwendet der Starter standardmäßig einen ausdrücklich weniger isolierten Chroot-Fallback; das Log weist darauf hin. Das Projekt lädt keine passenden Treiber nach und ersetzt keinen Kobo-Kernel. Ein Fake-Framebuffer löst diese fehlenden Voraussetzungen nicht.

`config` enthält nur die vertrauenswürdigen Shell-Einstellungen für bereits vorhandene Binder-/Ashmem-Gerätepfade. Nicht einfach Nodes mit geratenen Major-/Minor-Nummern erzeugen. Auch ein vorhandener Binder-Node kann eine unpassende ABI haben. Die Gerätekonfiguration kann je nach Kobo-Firmware unterschiedlich sein.

Weitere Diagnose:

```sh
sh android.sh status
sh android.sh exec getprop
sh android.sh exec service list
sh android.sh stop
```

KitKat verwendet gegebenenfalls Kernel-Logger-Geräte unter `/dev/log`. Wenn der Kobo diese nicht hat, kann `logcat` leer bleiben. Der private init-Ausgabekanal kann bei noch gemountetem Rootfs unter `run/rootfs/dev/kmsg` liegen. Der reguläre Starter versucht, ihn vor dem Unmount nach `android-init.log` zu sichern. Bei einem hart abgebrochenen Starter kann diese Sicherung fehlen; für eine laufende Diagnose die Datei direkt sichern.

Nach einem abgebrochenen Starter kann `sh android.sh recover` verwaiste Mounts entfernen. Es beendet keine beliebigen Prozesse und erzwingt keine belegten Unmounts. Erkennt es noch aktive verwaiste Android-Prozesse, den Kobo kontrolliert neu starten. Eine Rootfs-Reparatur mit `e2fsck` ausschließlich bei vollständig gestopptem, nicht mehr gemountetem Image durchführen und vorher eine Kopie sichern.

## Sicherheitsregeln

Android vor dem USB-Datenträgermodus beenden. Während des Betriebs das Image nicht kopieren, austauschen oder verschieben. Keine persönlichen Konten und keine untrusted APKs verwenden. KitKat ist ein historisches, nicht mehr zeitgemäß abgesichertes Betriebssystem. Wenn der Kernel keine Namespaces unterstützt, teilt Android zusätzlich Mount- und PID-Namespace mit dem Kobo-Host; nur mit vertrauenswürdigen Apps und besonders vorsichtig experimentieren. Das Android teilt sich den Host-Netzwerkstack; fehlende Android-Netzwerkeinstellungen sind **keine** Netzwerksperre. Mit der WLAN-Brücke (siehe [WLAN.md](WLAN.md)) nutzt Android das WLAN des Kobo; die Brücke ändert nie Adressen oder Routen des Hosts. Wer das nicht möchte, setzt `KOBO_NET=0` in `config`.

Die Anwendung schreibt nicht in `.kobo/upgrade`, nicht auf rohe eMMC-/SD-Geräte und nicht in Bootloader- oder Kernel-Partitionen. Trotzdem können ein Absturz, ein voller Datenträger oder unpassende Root-Software Daten beschädigen. Das ist kein Ersatz für ein Backup.
