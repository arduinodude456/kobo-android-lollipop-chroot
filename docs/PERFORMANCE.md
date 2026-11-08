# Geschwindigkeit

Android läuft auf dem Kobo als Chroot mit reinem Software-Rendering. Bremsen waren nicht die Rechenleistung
allein, sondern vor allem Dinge, die auf dem Image-auf-FAT32-Aufbau und im Diagnosecode unnötig Arbeit
kosteten. Alle Maßnahmen sind in `runtime/config` einzeln abschaltbar und wirken **auch ohne neues
`rootfs.img`** (das Startskript passt das vorhandene Image bei jedem Start an).

| Maßnahme | Wirkung | Schalter |
| --- | --- | --- |
| `fsync`/`fdatasync` ohne Warten (`libkobofb.so`) | Android ruft sie ständig auf (SQLite, `AtomicFile` in system_server, Settings, Package-Dateien). Jeder Aufruf löste ext4-Journal-Commit und Flush über Loop-Device und FAT32 bis zur eMMC aus. Das war vermutlich die größte Einzelbremse bei App-Start, Einstellungen, Installation. | `KOBO_NOSYNC` |
| ext4 `data=writeback,barrier=0,commit=60` | Weniger Journal-Schreibvorgänge und keine Flushes; fällt bei abgelehnten Optionen automatisch auf die alten Optionen zurück. | `KOBO_PERF_MOUNT` |
| CPU-Governor `performance` | Der Kobo taktet im Leerlauf sehr niedrig; Android (Dalvik, Software-GL) ist CPU-gebunden. Alter Governor/Min-Takt werden gemerkt und beim Beenden wiederhergestellt. | `KOBO_PERF_CPU` |
| Dalvik `dexopt-flags v=r,o=v` | Vorher `v=n,o=n`: keine Optimierung (quickened Opcodes, Inline-Natives) und Verifikation erst zur Laufzeit bei jedem Klassenladen. Der Cache bleibt in `/data`, die Kosten fallen einmal an. Dazu `heapminfree 1m`, `heapmaxfree 4m` (weniger GC-Läufe) und `checkjni=false`. | `KOBO_DEXOPT_REBUILD` |
| Logging (`kobo_log.c`) | Statt `getenv`+`open`+`write`+`close` je Logzeile bleibt der Deskriptor offen; Debug-Zeilen entfallen standardmäßig. | `KOBO_LOG_LEVEL` |
| `ioctl`-Hotpath | Jeder fremde `ioctl` (ashmem, FIONREAD, …) kostete zwei Zusatz-Syscalls (`fstat`+`stat`), obwohl nur Framebuffer-ioctls (Typ `F`) sie brauchen. | – |
| `kobo-vnc` im Leerlauf | Ohne Seitenwechsel seit 400 ms wird nur noch alle 12 ms gepollt und höchstens alle 80 ms ein Vollbildvergleich gemacht (vorher 2 ms / 10 ms). | – |
| Lua-Plugin | Adaptiver Takt statt fester 30 ms: bei Bildwechsel/Eingabe 10–30 ms, im Leerlauf 120 ms; Eingabe zieht den nächsten Tick sofort vor. | – |
| Diagnose-Schleifen | Nach dem Boot lief alle 5 s ein `find` über `/data/data`, `tail`/`grep` über die ganze Logdatei und ein Prozess pro Host-PID (`readlink`). Jetzt: 15 s Takt, `find` nur jede 4. Runde, `grep` nur über die letzten 8000 Zeilen, `android.log` wird bei 4 MB gekürzt. | `KOBO_DIAG_INTERVAL` |

## Erster Start nach dem Update

Der Dalvik-Cache wird einmalig verworfen (Marker `/data/.kobo-dexopt-v1`), damit alle System-Apps mit
Optimierung neu gebaut werden. **Dieser erste Boot dauert mehrere Minuten** („Optimizing apps“ auf dem
Bildschirm); danach ist jeder Start schneller als vorher. Mit `KOBO_DEXOPT_REBUILD=0` wird der alte Cache
behalten (dann profitieren nur neu installierte Apps).

## Nebenwirkungen und Grenzen

* **Stromausfall/Absturz des Kobo:** Mit `KOBO_NOSYNC=1` und `commit=60` können die letzten Sekunden an
  Android-Daten verloren gehen; ext4 selbst bleibt konsistent (Journal), nach hartem Ausschalten kann eine
  Prüfung nötig sein. Vor USB-Modus oder Firmware-Update weiter `android.sh stop` ausführen.
* **Akku/Wärme:** Der `performance`-Governor hält die CPU auf hohem Takt, solange Android läuft.
  `KOBO_PERF_CPU=0` schaltet das ab.
* **Log:** Standard ist jetzt Info (`KOBO_LOG_LEVEL=4`). Zur Fehlersuche `KOBO_LOG_LEVEL=3` setzen und neu starten.
* **E-Ink:** Die Bildwiederholrate des Panels bleibt die harte Grenze der wahrgenommenen Flüssigkeit.
* Alles hier ist auf dem Host getestet (Shim-Verhalten, Skriptlogik, Syntax), **nicht** auf dem Gerät gemessen.
