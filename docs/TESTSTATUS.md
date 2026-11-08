# KitKat-API-19-Chroot: Prüfstand

## Auswertung der Kobo-Logs

Die bereitgestellten Logs enthalten den Rootfs-Marker `android-5.0.2_api21`; sie stammen damit von einem Lollipop/API-21-Rootfs und **nicht** von dem hier gewünschten KitKat/API-19-Build. Die Logs dokumentieren dennoch konkrete Fehler im gemeinsamen Startpfad:

- `logcat` zeigt `BatteryService.<init>` mit `NullPointerException` und anschließend `BOOT FAILURE making display ready`. `healthd.txt` meldet `Service batteryproperties: not found`; `bootwatch.log` zeigt `healthd=restarting`. Das belegt, dass der Akku-Properties-Binder-Dienst nicht verfügbar war.
- `logcat` enthält wiederholt `logwrapper: Cannot create parent ptty`. Die angepasste Init hatte `/dev/pts` erzeugt, aber nicht `devpts` gemountet. Netd-/iptables-Aufrufe scheiterten ebenfalls.
- `stages.log` zeigt zusätzlich einen Segfault beim direkten `/system/bin/sh`-Probe. Der spätere normale Start lief aber deutlich weiter bis Zygote und SystemServer; der Probe-Fehler darf daher nicht mit dem dokumentierten Framework-Bootfehler gleichgesetzt werden.

## Ursache der Bootschleife (Nachtrag)

`/sbin/healthd` ist in KitKat **statisch** gelinkt. `LD_PRELOAD=libkobofb.so` (Binder-32→64-Bit-Übersetzung) wirkt auf statische Programme nicht. Der Kobo-Kernel 4.9.77 spricht Binder-Protokoll 8 (64 Bit); healthd scheitert bei `BINDER_VERSION` und beendet sich, `batteryproperties` wird nie registriert, `BatteryService.<init>` wirft die NPE, system_server stirbt, zygote startet endlos neu. Die QEMU-Variante hat einen Kernel mit `CONFIG_ANDROID_BINDER_IPC_32BIT` und braucht keine Übersetzung. Die Reihenfolge-/Trigger-Änderungen unten beseitigen diese Ursache nicht. Fix: `native/kobo_healthd.c` (dynamisch, bionic) ersetzt `/sbin/healthd`, registriert `batteryproperties` und meldet einen festen Akkustand. Gerätetest 1: `batteryproperties` wird registriert (`service check` = found), system_server stirbt aber weiter in `BatteryService.<init>` (Zeile 167, NPE). Gegenmaßnahmen in `kobo-healthd`: Quittierung von BR_INCREFS/BR_ACQUIRE während `addService`, Zeitstempel-Log nach `/data/local/tmp/kobo-healthd.log` und `/dev/kmsg`, und `init.rc` startet `class main` erst über `on property:kobo.healthd.ready=1`, nachdem der Dienst registriert ist. Noch nicht auf Gerät verifiziert.

## Umgesetzte Änderungen

1. Der erste veröffentlichte Fix schob `healthd` hinter `servicemanager`; das wich von QEMUs erfolgreicher Reihenfolge ab. Der aktuelle Init startet `healthd` wieder als `core`-Dienst vor `servicemanager`.
2. Der QEMU-Vergleich deckte eine fehlende Boot-Eventkette auf: `on fs` setzt nun `ro.crypto.state=unencrypted` und triggert `nonencrypted`; dieser Event startet `late_start`. `post-fs-data` setzt wie QEMU `vold.post_fs_data_done=1`.
3. `devpts` bleibt für die in den Kobo-Logs sichtbaren PTY-Fehler eingebunden. Der Build ist auf Android KitKat/API 19 festgelegt; das SDK-Archiv ist mit SHA-256 `ca7440cade53d829a8cace857cfad9afaa174c286d1b7a5d139e73cfcfde45d7` gepinnt.

## Verifikation und offene Punkte

Nach Ergänzung der QEMU-Eventkette laufen **42 Hosttests: 38 erfolgreich, 4 übersprungen**; Bash-Syntax, ShellCheck und `git diff --check` sind sauber. Der vollständige API-19-Build war in der ARM64-Sandbox beim x86-64-Compiler des NDK r10e blockiert.

Der aktuelle Satz Kobo-Logs stammt laut Rootfs-Marker von API 21 und kann die KitKat-Änderungen nicht validieren. Ein echter Libra-Colour-Boot mit API 19 ist ebenfalls noch nicht nachgewiesen. Nach Aktualisierung muss auf dem Gerät `getprop sys.boot_completed` schließlich `1` liefern; außerdem müssen `batteryproperties` im ServiceManager erscheinen und die PTY-/iptables-Fehler verschwinden.

Hosttests starten Android nicht und beweisen keinen Geräteboot. Kein Firmware- oder Kernelimage wird geschrieben. Die zusätzlichen Init-Mounts liegen unter dem Android-Rootfs, sollten aber wegen des auf älteren Kobo-Kerneln verwendeten, weniger isolierten Chroot-Fallbacks auf dem Zielgerät kontrolliert geprüft werden.

## Ursache der verbleibenden NPE (BatteryService.java:167) – gefunden
KitKat 4.4.x ruft in `BatteryService.<init>` `ServiceManager.getService("batterypropreg")` auf (verifiziert gegen android-4.4.4_r2). `kobo-healthd` registrierte nur `"batteryproperties"` (Name ab Android 5). `service check batteryproperties` meldete deshalb „found“, das Framework bekam aber `null` → NPE bei `registerListener`. Fix: `kobo-healthd` registriert jetzt beide Namen. Noch nicht auf Gerät verifiziert.

## Ursache von „Power off / Shutting down…“ direkt nach dem Boot – gefunden
`BatteryProperties` hat in KitKat 4.4.2 und 4.4.4 zwei Felder mehr als zuvor angenommen: nach `batteryVoltage` folgen `batteryCurrentNow` und `batteryChargeCounter`, erst dann `batteryTemperature` (verifiziert gegen android-4.4.2_r1 und android-4.4.4_r2). `kobo-healthd` ließ sie aus. Android las dadurch als Temperatur die Zeichen „Li“ des Technologie-Strings (0x0069004C = 6881356) und löste in `BatteryService.shutdownIfOverTempLocked` `ACTION_REQUEST_SHUTDOWN` (`confirm=false`) aus. Fix: beide Felder mit 0 senden; Host-Test prüft die Reihenfolge. Noch nicht auf Gerät verifiziert.

## Touch reagierte nicht – Ursache (Lua-Overlay)
`input.txt` zeigte: Android erkennt das Touchgerät korrekt (touchScreen, Viewport 600x800), aber `getevent -p` meldete `KEY 014a*` – `BTN_TOUCH` war dauerhaft **gedrückt**. Der Lua-Code ließ den Zeiger nur bei den Gesten `release`/`pan_release` los; ein normaler Fingertipp liefert in KOReader aber `touch` → `tap` (keine rohe `release`-Geste). Die „tap“-Verzweigung war durch `now-last_touch>0.6` gesperrt. Folge: Android sah einen Dauer-Druck ohne Loslassen. Fix: `pointer_action()` – `tap`, `swipe`, `hold_release`, `double_tap`, `release`, `pan_release` lösen den Zeiger; zusätzlich ein 6-s-Watchdog als Sicherheitsnetz. Noch nicht auf Gerät verifiziert.

## Geschwindigkeits-Änderungen (siehe PERFORMANCE.md)

Neu getestet auf dem Host: `fsync`/`fdatasync` als No-Op samt `EBADF`, Log-Level-Filter und offener Log-Deskriptor
im Preload-Shim (`tests/test_native.py`), Idempotenz der Property-/`init.rc`-Anpassung und des einmaligen
Dalvik-Cache-Reset (Simulation der Shell-Funktionen), `sh -n` und ShellCheck, Lua-Syntax. **Nicht auf dem Gerät
gemessen**: tatsächliche Beschleunigung, Verhalten der Mountoptionen und des Governors auf dem Kobo-Kernel 4.9.77.
