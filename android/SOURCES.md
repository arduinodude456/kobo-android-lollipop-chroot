# Vorgefertigte Android-Quellen und Anpassungen

Die schnelle Pipeline kompiliert **nicht** den vollständigen AOSP-Quellbaum. Sie lädt das offizielle Google-SDK-Systemimage `armeabi-v7a-19_r05.zip` für **Android KitKat/API 19, ARM EABI v7a** herunter. Die SHA-256-Prüfsumme des Archivs ist `ca7440cade53d829a8cace857cfad9afaa174c286d1b7a5d139e73cfcfde45d7`. Das Archiv enthält die Systempartition und Emulator-Ramdisk; der QEMU-Kernel wird nicht in das Kobo-Paket übernommen.

Die Pipeline übernimmt `/system` einschließlich Eigentümern, Modi, Symlinks und Dateisystemrechten. Aus der Ramdisk werden init, Properties und der erzeugte `BOOTCLASSPATH` übernommen. Die Emulator-Init-Konfiguration wird durch die isolierte Kobo-Chroot-Konfiguration ersetzt. Emulator-EGL/GLES-Emulationsbibliotheken werden entfernt und Software-EGL aktiviert.

Die nativen Helfer werden mit dem offiziellen Android-NDK r10e für Android API 19 gebaut. NDK-URL: `https://dl.google.com/android/repository/android-ndk-r10e-linux-x86_64.zip`; SHA-256: `ee5f405f3b57c4f5c3b3b8b5d495ae12b660e03d2112e4ed5c728d349f1e520c`. Es entstehen `libkobofb.so` sowie die statischen ARM32-Helfer `kobo-vnc` und `kobo-container`.

## Bootkorrekturen aus Kobo-Logs

Der direkte Vergleich mit der bootenden QEMU-Version zeigte den ausgelassenen Framework-Trigger: QEMU setzt bei `on fs` `ro.crypto.state=unencrypted` und führt `trigger nonencrypted` aus. Das originale KitKat-Init startet darüber `late_start`; der Chroot ersetzte das Original-Init, ließ aber diesen Eventpfad weg. Der Chroot bildet den Ablauf jetzt explizit nach und setzt zusätzlich bei `post-fs-data` `vold.post_fs_data_done=1`, wie QEMUs `init.goldfish.rc`.

QEMU startet `healthd` innerhalb der `core`-Klasse vor der Deklaration von `servicemanager`. Die Chroot spiegelt nun diese Reihenfolge, statt `healthd` bis nach dem `servicemanager`-Property aufzuschieben. Außerdem bindet sie `devpts` ein, weil die Kobo-Logs `logwrapper: Cannot create parent ptty` zeigen. Die bereitgestellten Logs stammen allerdings vom alten API-21-Rootfs; sie verifizieren diese Korrektur für KitKat noch nicht.

## Hardwaregrenze

Das Image ist ein **ARM-Emulator-Systemimage**, kein Kobo-Produktimage. Es liefert KitKat-Framework, Apps, Dalvik und generische Software-Gralloc-Treiber, aber keinen Kobo-Kernel und keinen passenden Hersteller-HAL. Ein erfolgreicher Build oder QEMU-Boot belegt nicht, dass Android auf dem Kobo-Kernel startet. Binder/Ashmem, Namespaces, Loop/ext4, Software-Gralloc, Touch und E-Ink-Rendering sind auf der Ziel-Firmware zu prüfen.

## Workflow und Artefakte

Der Workflow heißt **Android KitKat API-19 ARM chroot for Kobo (experimental)**. Pushes und Pull Requests führen Hosttests aus. Nur `workflow_dispatch` lädt die gepinnten SDK-/NDK-Archive, baut die nativen Helfer, erstellt das Rootfs und erzeugt das Installationspaket. Der Build-Job hat ein Zeitlimit von 45 Minuten.

Das Artefakt `kobo-android-kitkat-arm32` enthält `android-kobo.zip` und `kobo-android-kitkat.tar.gz`, jeweils mit Prüfsummen. `android-build-provenance-and-logs` enthält Buildmodus und Diagnoseprotokolle, auch im Fehlerfall.

## Quellen

[1]: https://dl.google.com/android/repository/sys-img/android/armeabi-v7a-19_r05.zip "Offizielles Android-KitKat-API-19-ARMv7a-SDK-Systemimage"
[2]: https://dl.google.com/android/repository/android-ndk-r10e-linux-x86_64.zip "Offizielles Android-NDK r10e für Linux x86-64"
[3]: https://developer.android.com/studio/run/managing-avds "Android-Entwicklerdokumentation zu Emulator-Systemimages und AVDs"
[4]: https://source.android.com/docs/setup/start/older-versions "Historische AOSP-Hostanforderungen"
