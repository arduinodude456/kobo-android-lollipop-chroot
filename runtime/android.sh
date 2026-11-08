#!/bin/sh
# SPDX-License-Identifier: MIT
# Invoke with sh: executable permission bits may not survive a FAT/ZIP copy.
set -eu
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
RUN="$BASE/run"
ROOTFS="$RUN/rootfs"
# BASE is normally /mnt/onboard/.adds/android; keep user files in a visible
# Kobo directory instead of hiding them below .adds.
PUBLIC_SHARED="$BASE/../../android-shared"
CONFIG="$BASE/config"
# shellcheck source=/dev/null
[ ! -f "$CONFIG" ] || . "$CONFIG"
KOBO_BINDER_DEVICE=${KOBO_BINDER_DEVICE:-/dev/binder}
KOBO_ASHMEM_DEVICE=${KOBO_ASHMEM_DEVICE:-/dev/ashmem}
KOBO_ALLOW_UNSAFE_NO_NAMESPACES=${KOBO_ALLOW_UNSAFE_NO_NAMESPACES:-1}
export KOBO_BINDER_DEVICE KOBO_ASHMEM_DEVICE KOBO_ALLOW_UNSAFE_NO_NAMESPACES
# Leistungs-Schalter (siehe docs/PERFORMANCE.md); alle standardmaessig an.
KOBO_PERF_CPU=${KOBO_PERF_CPU:-1}            # CPU-Governor "performance" solange Android laeuft
KOBO_PERF_MOUNT=${KOBO_PERF_MOUNT:-1}        # ext4: data=writeback,barrier=0,commit=60
KOBO_NOSYNC=${KOBO_NOSYNC:-1}                # fsync/fdatasync in Android-Prozessen ohne Warten
KOBO_LOG_LEVEL=${KOBO_LOG_LEVEL:-4}          # 3 = Debug (ausfuehrlich, langsamer), 4 = Info, 5 = Warnungen
KOBO_DEXOPT_REBUILD=${KOBO_DEXOPT_REBUILD:-1} # Dalvik-Cache einmalig mit Optimierung neu aufbauen
KOBO_DIAG_INTERVAL=${KOBO_DIAG_INTERVAL:-15} # Sekunden zwischen Diagnose-Schnappschuessen nach dem Boot
mkdir -p "$RUN"
fail() { echo "Android: $*" >&2; exit 1; }
root_required() { [ "$(id -u)" = 0 ] || fail 'Root erforderlich (aus KOReader starten).'; }
mounted() { awk -v p="$1" '$2 == p {found=1} END {exit !found}' /proc/mounts; }
running() {
    [ -r "$RUN/runner.pid" ] || return 1
    pid=$(cat "$RUN/runner.pid")
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$pid/cmdline" | grep -F -x "$BASE/android.sh" >/dev/null 2>&1 || return 1
    kill -0 "$pid" 2>/dev/null
}
orphan_active() {
    for name in container vnc; do
        [ -r "$RUN/$name.pid" ] || continue
        saved_pid=$(cat "$RUN/$name.pid")
        case "$saved_pid" in ''|*[!0-9]*) continue ;; esac
        exe=$(readlink "/proc/$saved_pid/exe" 2>/dev/null || true)
        case "$exe" in "$BASE/bin/kobo-container"|"$BASE/bin/kobo-vnc")
            kill -0 "$saved_pid" 2>/dev/null && return 0 ;;
        esac
    done
    return 1
}
check() {
    root_required
    [ -x "$BASE/bin/kobo-container" ] || fail 'bin/kobo-container fehlt oder ist nicht ausführbar.'
    [ -x "$BASE/bin/kobo-vnc" ] || fail 'bin/kobo-vnc fehlt oder ist nicht ausführbar.'
    "$BASE/bin/kobo-container" --check
    "$BASE/bin/kobo-vnc" --check
    grep -qw ext4 /proc/filesystems || fail 'Kernel unterstützt kein ext4.'
    grep -qw devpts /proc/filesystems || fail 'Kernel unterstützt kein devpts; KitKat logwrapper benötigt PTYs.'
    [ -e /dev/loop-control ] || [ -e /dev/loop0 ] || fail 'Kein Loop-Gerät vorhanden.'
    echo 'Kernel-Vorprüfung erfolgreich; dies ersetzt keinen Android-Gerätetest.'
}
copy_node() {
    src=$1 dst=$2 mode=$3
    [ -c "$src" ] || fail "Zeichengerät fehlt: $src"
    hexmajor=$(stat -c '%t' "$src")
    hexminor=$(stat -c '%T' "$src")
    mknod "$dst" c "$((0x$hexmajor))" "$((0x$hexminor))"
    chmod "$mode" "$dst"
}
dlog() { echo "DIAG: $*"; }
try_mount() {
    desc=$1; shift
    if out=$("$@" 2>&1); then dlog "$desc: OK"; return 0; fi
    dlog "$desc: FEHLER ${out:-unbekannt}"; return 1
}
proc_diag() {
    dlog "Kernel $(uname -r) $(uname -m)"
    dlog "Shell ns: mnt=$(readlink /proc/$$/ns/mnt 2>&1) pid=$(readlink /proc/$$/ns/pid 2>&1)"
    dlog "Dateisysteme: $(grep -w proc /proc/filesystems | tr '\n' ' ')"
    dlog "Ziel: $(ls -ld "$ROOTFS/proc" 2>&1)"
    dlog "Rootfs-Mount: $(grep " $ROOTFS " /proc/mounts | head -n 1)"
    t="$RUN/proctest"; mkdir -p "$t"
    if try_mount "Test proc auf Hostpfad" mount -t proc proc "$t"; then umount "$t" 2>/dev/null || true; fi
    if try_mount "Test bind auf Hostpfad" mount -o bind /proc "$t"; then umount "$t" 2>/dev/null || true; fi
    rmdir "$t" 2>/dev/null || true
    dlog "dmesg: $(dmesg 2>/dev/null | tail -n 3 | tr '\n' '|')"
}
prepare_proc() {
    proc_diag
    try_mount "proc im Rootfs (nosuid,nodev,noexec)" mount -t proc -o nosuid,nodev,noexec proc "$ROOTFS/proc" && return 0
    try_mount "proc im Rootfs" mount -t proc proc "$ROOTFS/proc" && return 0
    try_mount "bind /proc" mount -o bind /proc "$ROOTFS/proc" && return 0
    try_mount "rbind /proc" mount -o rbind /proc "$ROOTFS/proc" && return 0
    return 1
}
kill_rootfs_procs() {
    # Kernel has no PID namespace: init's children would survive init. Kill every
    # process whose root is exactly our rootfs so the unmounts can succeed.
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [ "$pid" != "$$" ] || continue
        r=$(readlink "$d/root" 2>/dev/null || true)
        if [ "$r" = "$ROOTFS" ]; then kill -KILL "$pid" 2>/dev/null || true; fi
    done
    sleep 1
}
watchdog() {
    # Notbremse: Android beenden, bevor der Kobo wegen Speichermangel einfriert.
    min_kb=${KOBO_MIN_FREE_KB:-60000}
    : > "$BASE/watchdog.log"
    while kill -0 "$container_pid" 2>/dev/null; do
        avail=$(awk '/^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Cached:/{c=$2} END{print (a ? a : f + c)}' /proc/meminfo)
        echo "$(date +%T) frei_kb=$avail limit_kb=$min_kb" > "$BASE/watchdog.last"
        case "$avail" in ''|*[!0-9]*) avail=999999 ;; esac
        if [ "$avail" -lt "$min_kb" ]; then
            echo "$(date +%T) WATCHDOG: nur $avail kB frei, Android wird beendet" | tee -a "$BASE/watchdog.log"
            kill_rootfs_procs
            return 0
        fi
        sleep 1
    done
}
unmount_tree() {
    # Android-init (stock) stapelt eigene Mounts (tmpfs auf /dev, proc, sysfs, devpts) auf unsere.
    # Deshalb von oben nach unten und mehrfach aushaengen, bis nichts mehr unter dem Rootfs haengt.
    pass=0
    while [ "$pass" -lt 12 ]; do
        list=$(awk -v r="$ROOTFS" -v s="$RUN/shared" '$2 == r || index($2, r "/") == 1 || $2 == s { print $2 }' /proc/mounts | sort -r)
        [ -n "$list" ] || return 0
        for m in $list; do umount "$m" 2>/dev/null || true; done
        pass=$((pass + 1))
    done
    echo "Android: Mounts bleiben belegt:" >&2
    awk -v r="$ROOTFS" 'index($2, r) == 1 { print "  " $2 }' /proc/mounts >&2
    return 1
}
# ---- Leistung ---------------------------------------------------------------------------------------
# Das Image liegt als ext4-Datei auf FAT32. Standard-Journal (data=ordered, Barrieren) loest bei jedem
# fsync/Commit einen Flush bis zur eMMC aus. Aeltere Kernel/busybox lehnen unbekannte Optionen ab.
rootfs_mount() {
    if [ "${KOBO_PERF_MOUNT:-1}" = 1 ]; then
        if mount -t ext4 -o loop,noatime,nodiratime,nosuid,data=writeback,barrier=0,commit=60 "$BASE/rootfs.img" "$ROOTFS" 2>/dev/null; then
            echo "Rootfs: Performance-Mountoptionen aktiv (writeback, barrier=0, commit=60)"
            return 0
        fi
        echo "Hinweis: Performance-Mountoptionen nicht moeglich, nutze Standardoptionen."
    fi
    mount -t ext4 -o loop,noatime,nosuid "$BASE/rootfs.img" "$ROOTFS"
}
# CPU auf "performance": Der Kobo taktet im Leerlauf/Powersave sehr niedrig, Android ist CPU-gebunden
# (Software-Rendering, Dalvik). Alter Zustand wird gemerkt und beim Beenden wiederhergestellt.
cpu_perf_on() {
    [ "${KOBO_PERF_CPU:-1}" = 1 ] || return 0
    saved="$RUN/cpu.saved"; : > "$saved"
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$c" ] || continue
        if [ -w "$c/online" ]; then { echo 1 > "$c/online"; } 2>/dev/null || true; fi
        gov="$c/cpufreq/scaling_governor"
        [ -w "$gov" ] || continue
        cur=$(cat "$gov" 2>/dev/null) || cur=''
        minf=$(cat "$c/cpufreq/scaling_min_freq" 2>/dev/null) || minf=''
        echo "$c|$cur|$minf" >> "$saved"
        if grep -qw performance "$c/cpufreq/scaling_available_governors" 2>/dev/null; then
            { echo performance > "$gov"; } 2>/dev/null || true
        elif [ -w "$c/cpufreq/scaling_min_freq" ] && [ -r "$c/cpufreq/scaling_max_freq" ]; then
            { cat "$c/cpufreq/scaling_max_freq" > "$c/cpufreq/scaling_min_freq"; } 2>/dev/null || true
        fi
        echo "CPU $(basename "$c"): Governor ${cur:-?} -> $(cat "$gov" 2>/dev/null), min $(cat "$c/cpufreq/scaling_min_freq" 2>/dev/null) kHz"
    done
    return 0
}
cpu_perf_off() {
    saved="$RUN/cpu.saved"
    [ -f "$saved" ] || return 0
    while IFS='|' read -r c gov minf; do
        [ -n "$c" ] || continue
        if [ -n "$minf" ]; then { echo "$minf" > "$c/cpufreq/scaling_min_freq"; } 2>/dev/null || true; fi
        if [ -n "$gov" ]; then { echo "$gov" > "$c/cpufreq/scaling_governor"; } 2>/dev/null || true; fi
    done < "$saved"
    rm -f "$saved"
    return 0
}
# Schluessel=Wert in einer Property-Datei setzen (ersetzt vorhandene, haengt sonst an). Kein Regex noetig.
set_prop_file() {
    f=$1; k=$2; v=$3
    [ -f "$f" ] || return 0
    tmp="$RUN/prop.new"
    awk -v k="$k" -v v="$v" 'BEGIN { l = length(k) + 1 }
        substr($0, 1, l) == k "=" { if (!seen) { print k "=" v; seen = 1 } ; next }
        { print }
        END { if (!seen) print k "=" v }' "$f" > "$tmp" || { rm -f "$tmp"; return 0; }
    cat "$tmp" > "$f"; rm -f "$tmp"
}
# Dalvik: "v=n,o=n" (keine Verifikation, keine Optimierung) macht jede App dauerhaft langsamer, weil der
# Interpreter ohne quickened Opcodes laeuft und Klassen zur Laufzeit verifiziert werden. v=r,o=v ist der
# Standard echter KitKat-Geraete; der Cache bleibt in /data erhalten, die Kosten fallen nur einmal an.
apply_perf_tuning() {
    bp="$ROOTFS/system/build.prop"
    set_prop_file "$bp" dalvik.vm.dexopt-flags 'v=r,o=v'
    set_prop_file "$bp" dalvik.vm.checkjni false
    set_prop_file "$bp" dalvik.vm.heapminfree 1m
    set_prop_file "$bp" dalvik.vm.heapmaxfree 4m
    rc="$ROOTFS/init.rc"
    if [ -f "$rc" ] && grep -q 'dalvik.vm.dexopt-flags' "$rc"; then
        tmp="$RUN/init.rc.perf"
        awk '$1 == "setprop" && $2 == "dalvik.vm.dexopt-flags" { print "    setprop dalvik.vm.dexopt-flags v=r,o=v"; next } { print }' "$rc" > "$tmp" \
            && cat "$tmp" > "$rc"
        rm -f "$tmp"
    fi
    marker="$ROOTFS/data/.kobo-dexopt-v1"
    if [ "${KOBO_DEXOPT_REBUILD:-1}" = 1 ] && [ ! -e "$marker" ]; then
        if [ -d "$ROOTFS/data/dalvik-cache" ]; then
            echo "Dalvik-Cache wird einmalig neu optimiert; der naechste Boot dauert dadurch laenger (Optimizing apps)."
            # Cache-Dateien heissen system@app@Name.apk@classes.dex; Unterordner (profiles) bleiben erhalten.
            rm -f "$ROOTFS/data/dalvik-cache"/*@* 2>/dev/null || true
        fi
        : > "$marker"
    fi
}
# Laufzeitwerte fuer libkobofb.so (liest /dev/kobo/tuning einmal je Prozess).
write_tuning() {
    {
        echo "KOBO_NOSYNC=${KOBO_NOSYNC:-1}"
        echo "KOBO_LOG_LEVEL=${KOBO_LOG_LEVEL:-4}"
    } > "$RUN/shared/tuning"
    chmod 0644 "$RUN/shared/tuning"
}
patch_init_rc() {
    # Das stock-init der Emulator-Ramdisk mountet ein frisches tmpfs auf /dev und versteckt damit
    # alle vom Host vorbereiteten Geraete (binder, ashmem, null, input, kobo). Ohne ueventd gibt es
    # keinen Weg zurueck. Loesung: Knoten liegen zusaetzlich unter /hostdev und werden in /dev verlinkt.
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -q 'KOBO_HOSTDEV_V1' "$rc" && return 0
    links="null zero random urandom tty binder ashmem input kobo"
    [ ! -d /dev/log ] || links="$links log"
    tmp="$RUN/init.rc.new"
    awk -v links="$links" '
        $1 == "mkdir" && ($2 == "/dev/kobo" || $2 == "/dev/input") { next }
        { print }
        $1 == "on" && $2 == "early-init" && NF == 2 && !done {
            print "    # KOBO_HOSTDEV_V1: stock init mounts a fresh tmpfs over /dev; re-expose host-prepared nodes."
            print "    write /dev/.coldboot_done 1"
            n = split(links, a, " ")
            for (i = 1; i <= n; i++) print "    symlink /hostdev/" a[i] " /dev/" a[i]
            done = 1
        }' "$rc" > "$tmp" || { rm -f "$tmp"; fail 'init.rc konnte nicht angepasst werden.'; }
    grep -q 'KOBO_HOSTDEV_V1' "$tmp" || { rm -f "$tmp"; fail 'init.rc: "on early-init" nicht gefunden.'; }
    cat "$tmp" > "$rc" && rm -f "$tmp"
    echo "init.rc angepasst (KOBO_HOSTDEV_V1)"
}
# ---- Diagnose: Stufentest (sh android.sh stages) -> stages.log -------------------------------------
# Prueft einzeln, WO der Chroot scheitert. Startet kein init, kein zygote; alles wird danach wieder abgebaut.
stages_body() {
    set +e
    ok() { echo "ERGEBNIS $1: OK"; }
    bad() { echo "ERGEBNIS $1: FEHLER ($2)"; }
    echo "=== STUFE 0: Umgebung"
    echo "uid=$(id -u) kernel=$(uname -r) $(uname -m)"
    grep -E 'MemTotal|MemAvailable' /proc/meminfo
    ls -l "$BASE/rootfs.img" "$BASE/rootfs.img.gz" 2>&1
    if [ ! -f "$BASE/rootfs.img" ]; then
        echo "rootfs.img fehlt, entpacke ..."
        sh "$BASE/install.sh" 2>&1 || { bad 0 "install.sh"; return 1; }
    fi
    ok 0
    echo "=== STUFE 1: Kernel-Vorpruefung"
    if ( check ) 2>&1; then ok 1; else bad 1 "check"; return 1; fi
    echo "=== STUFE 2: ext4-Image per Loop einbinden"
    mkdir -p "$ROOTFS"
    out=$(mount -t ext4 -o loop,noatime,nosuid "$BASE/rootfs.img" "$ROOTFS" 2>&1) || { bad 2 "$out"; return 1; }
    [ -f "$ROOTFS/kobo-chroot" ] && [ "$(cat "$ROOTFS/kobo-chroot")" = 'android-kitkat_api19' ] || { bad 2 "KitKat/API-19-Rootfs fehlt (altes Image sichern, rootfs.img entfernen und neu installieren)"; return 1; }
    echo "Rootfs-Marker: $(cat "$ROOTFS/kobo-chroot")  Dateien in /system/bin: $(ls "$ROOTFS/system/bin" | wc -l)"
    ok 2
    echo "=== STUFE 3: Android-Shell im Chroot (ARM-Linker, bionic)"
    [ ! -L "$ROOTFS/proc" ] || rm -f "$ROOTFS/proc"
    [ ! -L "$ROOTFS/sys" ] || rm -f "$ROOTFS/sys"
    mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/data/local/tmp"
    prepare_proc >/dev/null 2>&1 || echo "WARNUNG: proc nicht gemountet"
    mount -t tmpfs -o size=8m,mode=0755,nosuid tmpfs "$ROOTFS/dev" 2>&1
    for node in null zero random urandom tty; do copy_node "/dev/$node" "$ROOTFS/dev/$node" 0666; done
    copy_node "$KOBO_BINDER_DEVICE" "$ROOTFS/dev/binder" 0666
    copy_node "$KOBO_ASHMEM_DEVICE" "$ROOTFS/dev/ashmem" 0666
    CHROOT_BIN=$(command -v chroot) || { bad 3 "chroot fehlt"; return 1; }
    # Host-Environment (LD_LIBRARY_PATH von KOReader!) darf nicht in Android-Prozesse: Segfault im bionic-Linker
    ENVB=$(command -v env)
    out=$("$ENVB" -i PATH=/system/bin "$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c 'echo SH_OK; ls /system' 2>&1)
    echo "$out"
    case "$out" in *SH_OK*) ok 3 ;; *) bad 3 "Android-sh startet nicht"; return 1 ;; esac
    echo "=== STUFE 4: Binder-ABI Ende-zu-Ende (servicemanager + 'service list' mit Shim)"
    rm -f "$ROOTFS/data/local/tmp/kobo-binder.log"
    PRE='export LD_PRELOAD=/system/lib/libkobofb.so KOBO_BINDER_LOG=/data/local/tmp/kobo-binder.log'
    "$ENVB" -i PATH=/system/bin "$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c "$PRE; exec /system/bin/servicemanager" > "$RUN/sm.out" 2>&1 &
    smpid=$!
    sleep 3
    if kill -0 "$smpid" 2>/dev/null; then echo "servicemanager laeuft (PID $smpid)"; else echo "servicemanager ist sofort beendet:"; cat "$RUN/sm.out"; fi
    out=$("$ENVB" -i PATH=/system/bin "$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c "$PRE; /system/bin/service list" 2>&1)
    echo "service list: $out"
    kill "$smpid" 2>/dev/null; sleep 1; kill -KILL "$smpid" 2>/dev/null
    echo "--- servicemanager-Ausgabe:"; cat "$RUN/sm.out" 2>/dev/null
    echo "--- Binder-Shim-Log:"; cat "$ROOTFS/data/local/tmp/kobo-binder.log" 2>&1 | tail -n 30
    case "$out" in *"Found"*) ok 4 ;; *) bad 4 "Binder-Kommunikation funktioniert nicht" ;; esac
    echo "=== STUFE 5: Kernel-Meldungen (Binder/Ashmem)"
    dmesg 2>/dev/null | grep -iE 'binder|ashmem|selinux' | tail -n 15
    echo "=== ENDE"
}
stages() {
    root_required
    running && fail 'Android laeuft; erst stop.'
    mkdir "$RUN/lock" 2>/dev/null || fail 'Verwaister Zustand. Erst sh android.sh recover ausfuehren.'
    ( stages_body ) > "$BASE/stages.log" 2>&1 || true
    pkill -f "$ROOTFS" 2>/dev/null || true
    kill_rootfs_procs
    unmount_tree >> "$BASE/stages.log" 2>&1 || echo "WARNUNG: Mounts blieben belegt" >> "$BASE/stages.log"
    rm -f "$RUN/sm.out"
    mounted "$ROOTFS" || rmdir "$RUN/lock" 2>/dev/null || true
    echo "Stufentest fertig: $BASE/stages.log"
}
# ---- Diagnose: Boot-Zeitachse (laeuft waehrend run im Hintergrund) -> bootwatch.log ---------------
bootwatch() {
    set +e
    ENVB=$(command -v env); CHROOTB=$(command -v chroot)
    w="$BASE/bootwatch.log"; : > "$w"; i=0
    gp() { chroot "$ROOTFS" /system/bin/getprop "$1" 2>/dev/null | tr -d '\r'; }
    {
        echo "libkobofb hat Log-Ersatz (neues Build): $(grep -c __android_log_write "$ROOTFS/system/lib/libkobofb.so" 2>&1)"
        echo "--- egl.cfg:"; cat "$ROOTFS/system/lib/egl/egl.cfg" 2>&1
        echo "--- ls -l system/lib/egl:"; ls -l "$ROOTFS/system/lib/egl" 2>&1
        echo "--- ls system/lib/hw:"; ls "$ROOTFS/system/lib/hw" 2>&1 | tr '\n' ' '; echo
        echo "--- libEGL/libGLES*:"; ls -l "$ROOTFS"/system/lib/libEGL.so "$ROOTFS"/system/lib/libGLES* 2>&1
        echo "--- Props:"; grep -E 'ro.hardware|egl|opengl|qemu' "$ROOTFS/system/build.prop" "$ROOTFS/default.prop" 2>&1
    } > "$BASE/egl.txt" 2>&1
    while [ "$i" -lt 60 ] && kill -0 "$container_pid" 2>/dev/null; do
        sleep 10; i=$((i + 1))
        # Ein ls statt je ein readlink-Prozess pro Host-PID (auf dem Kobo sind das hunderte fork/exec).
        n=$(ls -l /proc/[0-9]*/root 2>/dev/null | awk -v r="$ROOTFS" '$NF == r { c++ } END { print c + 0 }')
        echo "$(date +%T) t=${i}0s procs=$n boot=$(gp sys.boot_completed) sm=$(gp init.svc.servicemanager) sf=$(gp init.svc.surfaceflinger) zygote=$(gp init.svc.zygote) netd=$(gp init.svc.netd) healthd=$(gp init.svc.healthd) frei_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" >> "$w"
        # Absturzursache sichtbar machen: logcat (Fehler/Fatal) und neuester Tombstone
        tail -n 150 "$ROOTFS/data/local/tmp/android.log" > "$BASE/logcat.txt" 2>&1
        {
            echo "init.svc.healthd=$(gp init.svc.healthd)"
            echo "--- ps (Android-Prozesse):"
            ls -l /proc/[0-9]*/root 2>/dev/null | awk -v r="$ROOTFS" '$NF == r { split($(NF-2), a, "/"); print a[3] }' | while read -r apid; do echo "$apid $(cat "/proc/$apid/comm" 2>/dev/null)"; done
            echo "--- service check batterypropreg (KitKat-Name):"
            "$ENVB" -i PATH=/system/bin LD_PRELOAD=/system/lib/libkobofb.so "$CHROOTB" "$ROOTFS" /system/bin/service check batterypropreg 2>&1
            echo "--- service check batteryproperties:"
            "$ENVB" -i PATH=/system/bin LD_PRELOAD=/system/lib/libkobofb.so "$CHROOTB" "$ROOTFS" /system/bin/service check batteryproperties 2>&1
            echo "--- dmesg healthd/init:"
            dmesg 2>/dev/null | grep -iE 'healthd|init: (cannot|could not|untracked|service)|init:.*(healthd|exited|killing)' | tail -n 30
        } > "$BASE/healthd.txt" 2>&1
        tail -n 4000 "$ROOTFS/data/local/tmp/android.log" > "$BASE/android-full.log" 2>&1
        t=$(ls -t "$ROOTFS"/data/tombstones 2>/dev/null | head -n 1)
        if [ -n "$t" ]; then head -n 60 "$ROOTFS/data/tombstones/$t" > "$BASE/tombstone.txt" 2>/dev/null; fi
        [ "$(gp sys.boot_completed)" = 1 ] && { echo "BOOT FERTIG nach ${i}0s" >> "$w"; break; }
    done
    # Eingabe-Diagnose (Touch/Tasten) erst nach dem Boot, wenn InputReader die Geraete kennt.
    if [ "$(gp sys.boot_completed)" = 1 ]; then
        sleep 25
        {
            echo "--- Host /proc/bus/input/devices (kobo-vnc):"
            grep -A8 'kobo-vnc' /proc/bus/input/devices 2>&1
            echo "--- ls -l rootfs/dev/input:"; ls -l "$ROOTFS/dev/input" 2>&1
            echo "--- getevent -p (im Android-Chroot):"
            "$ENVB" -i PATH=/system/bin LD_PRELOAD=/system/lib/libkobofb.so "$CHROOTB" "$ROOTFS" /system/bin/getevent -p 2>&1 | head -n 80
            echo "--- dumpsys input (Geraete, Display-Viewport):"
            "$ENVB" -i PATH=/system/bin LD_PRELOAD=/system/lib/libkobofb.so "$CHROOTB" "$ROOTFS" /system/bin/dumpsys input 2>&1 | head -n 120
            echo "--- logcat Input*:"
            grep -E 'InputReader|InputDispatcher|EventHub|InputManager' "$ROOTFS/data/local/tmp/android.log" 2>&1 | tail -n 40
        } > "$BASE/input.txt" 2>&1
    fi
    # Nach dem Boot weiter mitschreiben: sonst enden android-full.log/logcat.txt beim Boot und
    # spaetere Abstuerze (App-Crash, Download, Datei anlegen) stehen nie in den Logs.
    diag_n=0; diag_iv=${KOBO_DIAG_INTERVAL:-15}
    logf="$ROOTFS/data/local/tmp/android.log"
    while kill -0 "$container_pid" 2>/dev/null; do
        sleep "$diag_iv"; diag_n=$((diag_n + 1))
        # android.log wuchs bisher unbegrenzt (Android schreibt mit O_APPEND weiter): ab 4 MB kuerzen.
        sz=$(wc -c < "$logf" 2>/dev/null); sz=${sz:-0}
        if [ "$sz" -gt 4194304 ]; then
            tail -n 6000 "$logf" > "$RUN/log.trim" 2>/dev/null && cat "$RUN/log.trim" > "$logf"
            rm -f "$RUN/log.trim"
        fi
        tail -n 150 "$logf" > "$BASE/logcat.txt" 2>&1
        tail -n 4000 "$logf" > "$BASE/android-full.log" 2>&1
        tail -n 8000 "$logf" 2>/dev/null | grep -E 'FATAL EXCEPTION|AndroidRuntime|Process: |ANR in|has died|SIGSEGV|DEBUG ' -A12 | tail -n 300 > "$BASE/crash.txt"
        t=$(ls -t "$ROOTFS"/data/tombstones 2>/dev/null | head -n 1)
        if [ -n "$t" ]; then head -n 60 "$ROOTFS/data/tombstones/$t" > "$BASE/tombstone.txt" 2>/dev/null; fi
        # Die Minidump-Suche (find ueber /data/data) ist teuer: nur jede 4. Runde.
        if [ $((diag_n % 4)) -eq 1 ]; then
            # Native Minidumps (Firefox/Chrome) nach $BASE/dumps kopieren: der Rootfs ist nur waehrend Android laeuft sichtbar.
            mkdir -p "$BASE/dumps"
            find "$ROOTFS/data/data" -maxdepth 8 \( -name '*.dmp' -o -name '*.extra' \) 2>/dev/null | head -n 20 | while read -r f; do
                cp "$f" "$BASE/dumps/$(echo "${f#$ROOTFS/data/data/}" | tr '/ ' '__')" 2>/dev/null
            done
        fi
    done
}
cleanup() {
    trap - EXIT INT TERM HUP
    if [ -n "${container_pid:-}" ]; then
        kill -TERM "$container_pid" 2>/dev/null || true
        wait "$container_pid" 2>/dev/null || true
    fi
    if [ -n "${watchdog_pid:-}" ]; then kill "$watchdog_pid" 2>/dev/null || true; fi
    if [ -n "${watch_pid:-}" ]; then kill "$watch_pid" 2>/dev/null || true; fi
    if [ -n "${ime_fix_pid:-}" ]; then kill "$ime_fix_pid" 2>/dev/null || true; fi
    if [ -n "${net_pid:-}" ]; then kill "$net_pid" 2>/dev/null || true; fi
    if [ -f "$BASE/android-init.log" ] || [ -n "${container_pid:-}" ]; then
        dmesg 2>/dev/null | grep -E 'init:|<init>|servicemanager|zygote|surfaceflinger|binder' | tail -n 200 >> "$BASE/android-init.log" 2>/dev/null || true
    fi
    if [ -n "${vnc_pid:-}" ]; then
        kill -TERM "$vnc_pid" 2>/dev/null || true
        wait "$vnc_pid" 2>/dev/null || true
    fi
    mounted "$ROOTFS" && kill_rootfs_procs
    cpu_perf_off
    if [ -f "$ROOTFS/dev/kmsg" ]; then
        cat "$ROOTFS/dev/kmsg" >> "$BASE/android-init.log" 2>/dev/null || true
    fi
    sync
    unmount_failed=0
    unmount_tree || unmount_failed=1
    rm -f "$RUN/runner.pid" "$RUN/container.pid" "$RUN/vnc.pid" "$RUN/ready"
    if [ "$unmount_failed" = 0 ]; then rmdir "$RUN/lock" 2>/dev/null || true; fi
}
install_bundled_apps() {
    apps="$BASE/apps"
    [ -d "$apps" ] || return 0
    mkdir -p "$ROOTFS/system/app"
    for apk in "$apps"/*.apk; do
        [ -f "$apk" ] || continue
        target="$ROOTFS/system/app/$(basename "$apk")"
        cp "$apk" "$target"
        chmod 0644 "$target"
        echo "Bundled APK installiert: $(basename "$apk")"
    done
}
# ---- WLAN-Bruecke: Host-WLAN fuer Android sichtbar machen (siehe docs/WLAN.md) ------------------------
# Android teilt den Netzwerkstack mit dem Kobo. kobo-wpa spiegelt den WLAN-Zustand des Hosts in
# Androids Wi-Fi-Stack (wpa_supplicant-/dhcpcd-Attrappe), damit Browser, Downloads und Apps "online" sind.
# Verbinden und Passwort bleiben beim Kobo/KOReader; Android veraendert nie Adressen oder Routen.
net_iface() {
    if [ -n "${KOBO_NET_IFACE:-}" ]; then echo "$KOBO_NET_IFACE"; return 0; fi
    i=$(awk 'NR > 1 && $2 == "00000000" { print $1; exit }' /proc/net/route 2>/dev/null || true)
    [ -n "$i" ] || i=wlan0
    echo "$i"
}
net_ssid() {
    iface=$1; s=''
    command -v iwgetid >/dev/null 2>&1 && s=$(iwgetid -r "$iface" 2>/dev/null || true)
    if [ -z "$s" ] && command -v wpa_cli >/dev/null 2>&1; then
        s=$(wpa_cli -i "$iface" status 2>/dev/null | sed -n 's/^ssid=//p' | head -n 1 || true)
    fi
    if [ -z "$s" ] && command -v iwconfig >/dev/null 2>&1; then
        s=$(iwconfig "$iface" 2>/dev/null | sed -n 's/.*ESSID:"\(.*\)".*/\1/p' | head -n 1 || true)
    fi
    echo "${s:-Kobo-WLAN}"
}
net_write_env() {
    iface=$1; f="$ROOTFS/data/local/tmp/kobo-net.env"
    mkdir -p "$ROOTFS/data/local/tmp" 2>/dev/null || return 0
    {
        echo "IFACE=$iface"
        echo "SSID=$(net_ssid "$iface")"
        n=0
        for ns in $(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null || true); do
            n=$((n + 1)); [ "$n" -le 2 ] && echo "DNS$n=$ns"
        done
    } > "$f.new" 2>/dev/null && mv "$f.new" "$f" && chmod 0644 "$f"
}
patch_net_rc() {
    iface=$1; rc="$ROOTFS/init.rc"; tmp="$RUN/init.rc.net"
    [ -f "$rc" ] || return 0
    awk '/^# KOBO_NET_BEGIN/ { skip = 1 } !skip { print } /^# KOBO_NET_END/ { skip = 0 }' "$rc" > "$tmp" || return 1
    cat >> "$tmp" <<NETRC
# KOBO_NET_BEGIN iface=$iface
on init
    mkdir /data/misc/wifi 0770 wifi wifi
    mkdir /data/misc/wifi/sockets 0770 wifi wifi
    mkdir /data/misc/dhcp 0770 dhcp dhcp
    setprop wifi.interface $iface
    setprop wlan.driver.status ok

service wpa_supplicant /system/bin/kobo-wpa --supplicant $iface
    class main
    disabled
    oneshot

service p2p_supplicant /system/bin/kobo-wpa --supplicant $iface
    class main
    disabled
    oneshot

service dhcpcd_$iface /system/bin/kobo-wpa --dhcp $iface
    class main
    disabled
    oneshot
# KOBO_NET_END
NETRC
    cat "$tmp" > "$rc" && rm -f "$tmp"
}
net_install() {
    iface=$1
    if [ -f "$BASE/bin/kobo-wpa" ]; then
        cp "$BASE/bin/kobo-wpa" "$ROOTFS/system/bin/kobo-wpa" && chmod 0755 "$ROOTFS/system/bin/kobo-wpa"
    fi
    [ -x "$ROOTFS/system/bin/kobo-wpa" ] || { echo 'WLAN-Bruecke: kobo-wpa fehlt (Paket veraltet); Android startet ohne WLAN.' >&2; return 1; }
    # Aktualisierte Shim-Bibliothek (Schutz des Host-Netzwerks); ohne sie bleibt die alte aktiv.
    if [ -f "$BASE/bin/libkobofb.so" ]; then
        cp "$BASE/bin/libkobofb.so" "$ROOTFS/system/lib/libkobofb.so" && chmod 0644 "$ROOTFS/system/lib/libkobofb.so"
    fi
    mkdir -p "$ROOTFS/system/etc/wifi" "$ROOTFS/system/etc/permissions"
    [ -f "$ROOTFS/system/etc/wifi/wpa_supplicant.conf" ] || printf 'update_config=1\nctrl_interface=%s\neapol_version=1\nap_scan=1\nfast_reauth=1\n' "$iface" > "$ROOTFS/system/etc/wifi/wpa_supplicant.conf"
    chmod 0644 "$ROOTFS/system/etc/wifi/wpa_supplicant.conf"
    printf '<?xml version="1.0" encoding="utf-8"?>\n<permissions>\n    <feature name="android.hardware.wifi" />\n</permissions>\n' > "$ROOTFS/system/etc/permissions/kobo-wifi.xml"
    chmod 0644 "$ROOTFS/system/etc/permissions/kobo-wifi.xml"
    mkdir -p "$ROOTFS/data/misc/wifi/sockets" "$ROOTFS/data/misc/dhcp"
    # KitKat sucht den Supplicant-Socket in IFACE_DIR=/data/system/wpa_supplicant (existiert das Verzeichnis)
    # bzw. /dev/socket/<iface>, NICHT in data/misc/wifi/sockets. kobo-wpa lauscht auf allen Pfaden.
    mkdir -p "$ROOTFS/data/system/wpa_supplicant"
    chown 1010:1010 "$ROOTFS/data/system/wpa_supplicant" 2>/dev/null || true
    chmod 0771 "$ROOTFS/data/system/wpa_supplicant" 2>/dev/null || true
    chown 1010:1010 "$ROOTFS/data/misc/wifi" "$ROOTFS/data/misc/wifi/sockets" 2>/dev/null || true
    chmod 0770 "$ROOTFS/data/misc/wifi" "$ROOTFS/data/misc/wifi/sockets" 2>/dev/null || true
    chown 1014:1000 "$ROOTFS/data/misc/dhcp" 2>/dev/null || true
    chmod 0770 "$ROOTFS/data/misc/dhcp" 2>/dev/null || true
    # Aktuelle CA-Wurzeln: KitKat kennt z. B. ISRG Root X1 nicht -> sonst scheitert fast jedes HTTPS.
    if [ -d "$BASE/cacerts" ]; then
        mkdir -p "$ROOTFS/system/etc/security/cacerts"
        for c in "$BASE/cacerts"/*; do
            [ -f "$c" ] || continue
            [ -e "$ROOTFS/system/etc/security/cacerts/$(basename "$c")" ] || { cp "$c" "$ROOTFS/system/etc/security/cacerts/" && chmod 0644 "$ROOTFS/system/etc/security/cacerts/$(basename "$c")"; }
        done
    fi
    patch_net_rc "$iface"
    echo "WLAN-Bruecke bereit (Host-Schnittstelle $iface)"
}
agp() { chroot "$ROOTFS" /system/bin/getprop "$1" 2>/dev/null | tr -d '\r'; }
android_run() {
    bcp=$(sed -n 's/^ *export BOOTCLASSPATH *//p' "$ROOTFS/init.environ.rc" 2>/dev/null | head -n 1)
    "$ENVB" -i PATH=/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data ANDROID_ASSETS=/system/app \
        BOOTCLASSPATH="$bcp" EXTERNAL_STORAGE=/storage/sdcard LD_PRELOAD=/system/lib/libkobofb.so \
        KOBO_LOG_FILE=/data/local/tmp/android.log KOBO_BINDER_LOG=/data/local/tmp/kobo-binder.log \
        "$CHROOT_BIN" "$ROOTFS" "$@"
}
netboot() {
    set +e
    iface=$1; i=0
    while [ "$i" -lt 150 ] && kill -0 "$container_pid" 2>/dev/null; do
        [ "$(agp sys.boot_completed)" = 1 ] && break
        net_write_env "$iface"; sleep 2; i=$((i + 1))
    done
    sleep 10
    # Android-Einstellungen: WLAN an, Installation aus fremden Quellen erlauben (APK aus dem Browser).
    t=0
    while [ "$t" -lt 4 ] && kill -0 "$container_pid" 2>/dev/null; do
        android_run /system/bin/svc wifi enable >> "$BASE/net.log" 2>&1
        sleep 8
        [ "$(agp init.svc.wpa_supplicant)" = running ] && break
        t=$((t + 1))
    done
    android_run /system/bin/settings put secure install_non_market_apps 1 >> "$BASE/net.log" 2>&1
    sleep 25
    {
        echo "=== $(date +%T) Host:"; "$BASE/bin/kobo-wpa" --ipinfo "$iface" 2>&1
        echo "--- resolv.conf:"; cat /etc/resolv.conf 2>&1
        echo "--- Android-Properties:"
        for k in init.svc.wpa_supplicant init.svc.dhcpcd_"$iface" wifi.interface dhcp."$iface".result dhcp."$iface".ipaddress \
                 dhcp."$iface".gateway dhcp."$iface".dns1 net.dns1 net.dns2; do echo "$k=$(agp "$k")"; done
        echo "--- dumpsys connectivity:"; android_run /system/bin/dumpsys connectivity 2>&1 | head -n 40
        echo "--- dumpsys wifi:"; android_run /system/bin/dumpsys wifi 2>&1 | head -n 140
        echo "--- Probe (oeffnet den Kontrollsocket wie system_server, uid 1000):"
        android_run /system/bin/kobo-wpa --probe "$iface" 2>&1
        echo "--- ls -ln Socket-Verzeichnisse:"
        for d in data/system/wpa_supplicant data/misc/wifi data/misc/wifi/sockets dev/socket; do
            echo "[$d]"; ls -ln "$ROOTFS/$d" 2>&1 | head -n 30
        done
        echo "--- ps (kobo-wpa):"; ps 2>/dev/null | grep '[k]obo-wpa'
        echo "--- Android-Log (wifi/wpa/dhcp/netd), letzte 100 Zeilen:"
        grep -i 'wifi\|wpa\|supplicant\|dhcp\|WifiHW\|NetworkManagement' "$ROOTFS/data/local/tmp/android.log" 2>&1 | tail -n 100
        echo "--- kobo-wpa.log:"; tail -n 60 "$ROOTFS/data/local/tmp/kobo-wpa.log" 2>&1
        echo "--- kobo-net-guard.log:"; tail -n 20 "$ROOTFS/data/local/tmp/kobo-net-guard.log" 2>&1
    } > "$BASE/net.txt" 2>&1
    while kill -0 "$container_pid" 2>/dev/null; do net_write_env "$iface"; sleep 5; done
}
netinfo() {
    iface=$(net_iface)
    echo "Host-Schnittstelle: $iface"
    [ ! -x "$BASE/bin/kobo-wpa" ] || "$BASE/bin/kobo-wpa" --ipinfo "$iface" || true
    echo "DNS (Host): $(awk '$1 == "nameserver" { printf "%s ", $2 }' /etc/resolv.conf 2>/dev/null)"
    echo "SSID (Host): $(net_ssid "$iface")"
    if [ -f "$BASE/net.txt" ]; then echo "--- net.txt (Android-Seite, nach dem Boot):"; cat "$BASE/net.txt"; fi
}
start_ime_fix() {
    [ -f "$BASE/ime-fix.sh" ] || return 0
    mkdir -p "$ROOTFS/system/etc"
    cp "$BASE/ime-fix.sh" "$ROOTFS/system/etc/kobo-ime-fix.sh"
    chmod 0755 "$ROOTFS/system/etc/kobo-ime-fix.sh"
    # Run after Android has booted; this also repairs an existing /data and
    # does not require rebuilding the ext4 image.
    "$ENVB" -i PATH=/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data \
        "$CHROOT_BIN" "$ROOTFS" /system/etc/kobo-ime-fix.sh >/dev/null 2>&1 &
    ime_fix_pid=$!
}
run() {
    root_required
    mkdir "$RUN/lock" 2>/dev/null || fail 'Schon gestartet oder alte Mounts vorhanden; status/recover prüfen.'
    container_pid='' vnc_pid='' watchdog_pid='' watch_pid='' ime_fix_pid='' net_pid='' NET_IFACE=''
    trap cleanup EXIT
    trap 'exit 0' INT TERM HUP
    echo $$ > "$RUN/runner.pid"
    check
    [ -f "$BASE/rootfs.img" ] || sh "$BASE/install.sh"
    mkdir -p "$ROOTFS" "$RUN/shared"
    mounted "$ROOTFS" && fail 'Rootfs ist bereits gemountet.'
    rootfs_mount
    [ -f "$ROOTFS/kobo-chroot" ] && [ "$(cat "$ROOTFS/kobo-chroot")" = 'android-kitkat_api19' ] || fail 'Falsches Rootfs: KitKat/API-19-Image erforderlich. Altes rootfs.img sichern, entfernen und neu installieren.'
    install_bundled_apps
    CHROOT_BIN=$(command -v chroot) || fail 'chroot nicht gefunden.'
    ENV_BIN=$(command -v env) || fail 'env nicht gefunden.'
    ENVB="$ENV_BIN"
    start_ime_fix
    patch_init_rc
    apply_perf_tuning
    # Statisches /sbin/healthd ignoriert LD_PRELOAD (Binder-Shim) -> batteryproperties fehlt -> Boot-Schleife.
    grep -aq '/system/bin/linker' "$ROOTFS/sbin/healthd" 2>/dev/null || fail 'Rootfs veraltet: /sbin/healthd ist statisch (kein kobo-healthd). Neues Paket installieren.'
    mkdir -p "$ROOTFS/data/local/tmp"
    chmod 0777 "$ROOTFS/data/local/tmp"
    # Shim-Log vorab anlegen und fuer alle uids beschreibbar machen (SurfaceFlinger laeuft als system)
    : > "$ROOTFS/data/local/tmp/kobo-binder.log"; chmod 0666 "$ROOTFS/data/local/tmp/kobo-binder.log"
    : > "$ROOTFS/data/local/tmp/android.log"; chmod 0666 "$ROOTFS/data/local/tmp/android.log"
    if [ "${KOBO_NET:-1}" = 1 ]; then
        NET_IFACE=$(net_iface)
        net_install "$NET_IFACE" || NET_IFACE=''
        [ -z "$NET_IFACE" ] || net_write_env "$NET_IFACE"
    fi
    rm -rf "$ROOTFS/data/tombstones" 2>/dev/null || true; rm -f "$BASE/logcat.txt" "$BASE/tombstone.txt"
    # Replace image-provided dangling proc/sys symlinks with mountpoint dirs.
    # The official image may inherit these links from its emulator product.
    [ ! -L "$ROOTFS/proc" ] || rm -f "$ROOTFS/proc"
    [ ! -L "$ROOTFS/sys" ] || rm -f "$ROOTFS/sys"
    mkdir -p "$ROOTFS/proc" "$ROOTFS/sys"
    [ -d "$ROOTFS/proc" ] || fail "Mountpoint fehlt: $ROOTFS/proc"
    proc_ready=0
    if prepare_proc; then proc_ready=1; else echo "WARNING: proc konnte nicht per Shell gemountet werden; kobo-container versucht es selbst"; fi
    mount -t tmpfs -o size=16m,mode=0755,nosuid tmpfs "$ROOTFS/dev"
    mkdir -p "$ROOTFS/dev/input" "$ROOTFS/dev/socket" "$ROOTFS/dev/graphics" "$ROOTFS/dev/kobo" "$ROOTFS/dev/pts"
    chmod 0755 "$ROOTFS/dev/input" "$ROOTFS/dev/socket"
    for node in null zero random urandom tty; do copy_node "/dev/$node" "$ROOTFS/dev/$node" 0666; done
    copy_node "$KOBO_BINDER_DEVICE" "$ROOTFS/dev/binder" 0666
    copy_node "$KOBO_ASHMEM_DEVICE" "$ROOTFS/dev/ashmem" 0666
    # Android legacy logger devices are optional. Never bind the host /dev tree.
    if [ -d /dev/log ]; then
        mkdir -p "$ROOTFS/dev/log"
        for node in main system events radio; do
            [ ! -c "/dev/log/$node" ] || copy_node "/dev/log/$node" "$ROOTFS/dev/log/$node" 0666
        done
    fi
    # init's klog output stays in this private regular file, not the host kernel log.
    : > "$ROOTFS/dev/kmsg"
    chmod 0600 "$ROOTFS/dev/kmsg"
    mount -t tmpfs -o size=4m,mode=0755,nosuid,nodev tmpfs "$RUN/shared"
    mount -o bind "$RUN/shared" "$ROOTFS/dev/kobo"
    write_tuning
    # Persistent shared storage: visible on the Kobo as $BASE/shared and in
    # Android through /sdcard and /storage/emulated/0.
    mkdir -p "$PUBLIC_SHARED" "$ROOTFS/storage/emulated/0"
    chmod 0777 "$PUBLIC_SHARED"
    mount -o bind "$PUBLIC_SHARED" "$ROOTFS/storage/emulated/0" || fail "Gemeinsamer Speicher konnte nicht gemountet werden: $PUBLIC_SHARED"
    # Das KitKat-SDK-Image (storage_list.xml, goldfish) kennt als Primaerspeicher /storage/sdcard = EXTERNAL_STORAGE.
    # /storage/sdcard liegt auf dem ext4-Rootfs (echte Unix-Rechte). Der FAT-Ordner $PUBLIC_SHARED
    # laesst Android-Apps (uid != root) nicht schreiben -> Amaze/Browser/Editor stuerzten ab.
    mkdir -p "$ROOTFS/storage/sdcard"
    chmod 0777 "$ROOTFS/storage/sdcard"
    # Der Kobo-Ordner bleibt als Unterordner erreichbar (best effort, Schreibrechte haengen vom FAT-Mount ab).
    mkdir -p "$ROOTFS/storage/sdcard/KoboShared"
    mount -o bind "$PUBLIC_SHARED" "$ROOTFS/storage/sdcard/KoboShared" 2>/dev/null || echo "Hinweis: KoboShared nicht eingebunden."
    # TEST: /sys war im Chroot ein leeres Verzeichnis. Chromium/Gecko lesen CPU-Anzahl und -Infos aus
    # /sys/devices/system/cpu; Chrome/Opera/Firefox stuerzten beim Start der nativen Engine ab.
    # Nur lesend einbinden (ro), damit Android nichts am Host-sysfs veraendern kann.
    if mount -o bind /sys "$ROOTFS/sys" 2>/dev/null; then
        mount -o remount,bind,ro "$ROOTFS/sys" 2>/dev/null || echo "Hinweis: /sys konnte nicht auf ro gesetzt werden."
        echo "sys: Host-/sys (ro) im Chroot eingebunden"
    else
        echo "Hinweis: /sys nicht eingebunden."
    fi
    if [ "${KOBO_PROBE:-0}" = 1 ]; then
        # Harmloser Test: nur ein Android-Shell-Befehl im Chroot, KEIN init, kein zygote.
        echo "PROBE: chroot + /system/bin/sh (ohne init)"
        CHROOT_BIN=$(command -v chroot) || fail 'chroot nicht gefunden.'
        "$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c 'echo PROBE: Android-sh OK; ls /system | head -n 5; head -n 2 /proc/meminfo' 2>&1 || echo "PROBE: FEHLER Code $?"
        echo "PROBE: fertig"
        return 0
    fi
    ifconfig lo 127.0.0.1 up 2>/dev/null || ip link set lo up
    cpu_perf_on
    "$BASE/bin/kobo-vnc" --shared "$RUN/shared" --input-dir "$ROOTFS/dev/input" --port 5963 &
    vnc_pid=$!
    echo "$vnc_pid" > "$RUN/vnc.pid"
    tries=0
    while [ ! -f "$RUN/shared/fb.meta" ] || [ ! -f "$RUN/shared/fb.bin" ] || ! ls "$ROOTFS/dev/input"/event* >/dev/null 2>&1; do
        kill -0 "$vnc_pid" 2>/dev/null || fail 'VNC-/Eingabebrücke beendet; siehe android.log.'
        tries=$((tries + 1)); [ "$tries" -le 15 ] || fail 'VNC-/uinput-Initialisierung dauert zu lange.'
        sleep 1
    done
    chown 1000:1003 "$RUN/shared/fb.bin" "$RUN/shared/fb.meta"
    chmod 0660 "$RUN/shared/fb.bin" "$RUN/shared/fb.meta"
    chmod 0660 "$ROOTFS/dev/input"/event*
    chown 1000:1004 "$ROOTFS/dev/input"/event*
    # Zweiter Zugang zu den Geraeteknoten, der nicht von init's tmpfs auf /dev verdeckt wird.
    mkdir -p "$ROOTFS/hostdev"
    if ! mount -o rbind "$ROOTFS/dev" "$ROOTFS/hostdev" 2>/dev/null; then
        mount -o bind "$ROOTFS/dev" "$ROOTFS/hostdev" || fail 'hostdev-Bind fehlgeschlagen.'
        mount -o bind "$RUN/shared" "$ROOTFS/hostdev/kobo" || fail 'hostdev/kobo-Bind fehlgeschlagen.'
    fi
    [ -c "$ROOTFS/hostdev/binder" ] && [ -d "$ROOTFS/hostdev/kobo" ] || fail 'hostdev unvollstaendig.'
    echo "hostdev bereit: $(ls "$ROOTFS/hostdev" | tr '\n' ' ')"
    if [ "$proc_ready" = 1 ]; then
        echo "Start per Shell-chroot (kobo-container umgangen)"
        # env -i replaces PATH, so resolve host binaries to absolute paths first.
        CHROOT_BIN=$(command -v chroot) || fail 'chroot nicht gefunden.'
        ENV_BIN=$(command -v env) || fail 'env nicht gefunden.'
        SH_BIN=$(command -v sh)
        # Android soll bei Speicherknappheit zuerst vom OOM-Killer beendet werden, nicht der Kobo.
        "$SH_BIN" -c 'echo 1000 > /proc/self/oom_score_adj 2>/dev/null; exec "$@"' sh \
            "$ENV_BIN" -i PATH=/sbin:/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data \
            "$CHROOT_BIN" "$ROOTFS" /init &
    else
        "$BASE/bin/kobo-container" --root "$ROOTFS" &
    fi
    container_pid=$!
    echo "$container_pid" > "$RUN/container.pid"
    watchdog & watchdog_pid=$!
    bootwatch & watch_pid=$!
    if [ -n "$NET_IFACE" ]; then netboot "$NET_IFACE" & net_pid=$!; fi
    touch "$RUN/ready"
    while kill -0 "$container_pid" 2>/dev/null && kill -0 "$vnc_pid" 2>/dev/null; do sleep 1; done
    echo 'Android oder die VNC-Brücke wurde beendet.'
}
# ---- Optional: Google-Apps (Core) in das Android-Image installieren -----------------------------
# Die ZIP (gapps-kern.zip) liegt NICHT im Repo; der Nutzer legt sie selbst auf den Kobo.
# KitKat (API 19) scannt nur FLACHE APKs: /system/priv-app/Name.apk (Ordner pro App gibt es erst ab Android 5).
GAPPS_APKS="priv-app/SetupWizard.apk priv-app/GoogleFeedback.apk priv-app/GoogleOneTimeInitializer.apk priv-app/GoogleLoginService.apk priv-app/GooglePartnerSetup.apk priv-app/PrebuiltGmsCore.apk priv-app/Phonesky.apk priv-app/GoogleServicesFramework.apk priv-app/GoogleBackupTransport.apk app/GoogleContactsSyncAdapter.apk"
# Frühere Version dieses Pakets legte fälschlich Ordner an; diese werden beim Installieren entfernt.
GAPPS_LEGACY_DIRS="priv-app/SetupWizard priv-app/GoogleFeedback priv-app/GoogleOneTimeInitializer priv-app/GoogleLoginService priv-app/GooglePartnerSetup priv-app/PrebuiltGmsCore priv-app/Phonesky priv-app/GoogleServicesFramework priv-app/GoogleBackupTransport app/GoogleContactsSyncAdapter"
GAPPS_LIBS="lib/libAppDataSearch.so lib/libWhisper.so lib/libbrotli.so lib/libbrotli_native.so lib/libconscrypt_gmscore_jni.so lib/libconscrypt_jni.so lib/libcronet.98.0.4758.34.so lib/libempty_armeabi-v7a.so lib/libgame_sdk_device_info_jni.so lib/libgcastv2_base.so lib/libgcastv2_support.so lib/libgeller_jni_lite_lib.so lib/libgmscore.so lib/libgoogle-ocrclient-v3.so lib/libinertial-anchor-jni.so lib/libjgcastservice.so lib/libjingle_peerconnection_so.so lib/libleveldbjni.so lib/libmappedcountercacheversionjni.so lib/libmatching.so lib/libnnapi_device_enumeration_minimal.so lib/libphonesky_data_loader.so lib/libsemanticlocation_inference_jni.so lib/libtensorflowlite_jni.so lib/libvcdiffjni.so lib/libwearable-selector.so"
GAPPS_FILES="etc/permissions/com.google.android.maps.xml etc/permissions/com.google.android.media.effects.xml etc/permissions/com.google.widevine.software.drm.xml etc/preferred-apps/google.xml framework/com.google.android.maps.jar framework/com.google.android.media.effects.jar framework/com.google.widevine.software.drm.jar etc/kobo-gapps-core"
gapps_find_zip() {
    for c in "$1" "$BASE/gapps-kern.zip" "$PUBLIC_SHARED/gapps-kern.zip" "$BASE/../../gapps-kern.zip" /mnt/onboard/gapps-kern.zip /mnt/onboard/Download/gapps-kern.zip; do
        [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}
gapps_mount() {
    running && fail 'Android läuft. Erst beenden, dann Google-Apps installieren.'
    orphan_active && fail 'Verwaiste Android-Prozesse aktiv. Kobo sauber neu starten.'
    mounted "$ROOTFS" && fail "Rootfs ist bereits gemountet ($ROOTFS). Erst 'recover' ausführen."
    [ -f "$BASE/rootfs.img" ] || { echo 'rootfs.img fehlt, entpacke ...'; sh "$BASE/install.sh" || fail 'install.sh fehlgeschlagen.'; }
    mkdir -p "$ROOTFS"
    mount -t ext4 -o loop,noatime,nosuid "$BASE/rootfs.img" "$ROOTFS" || fail 'Image konnte nicht gemountet werden.'
    [ -f "$ROOTFS/kobo-chroot" ] || { umount "$ROOTFS" 2>/dev/null; fail 'Kein Android-Rootfs im Image.'; }
}
gapps_install() {
    root_required
    zip=$(gapps_find_zip "${1:-}") || fail 'gapps-kern.zip nicht gefunden. Lege sie nach /mnt/onboard/gapps-kern.zip.'
    command -v unzip >/dev/null 2>&1 || fail 'unzip fehlt auf dem Kobo (busybox unzip erforderlich).'
    echo "ZIP: $zip"
    # Inhalt prüfen: nur system/-Pfade ohne '..' zulassen.
    unzip -l "$zip" > "$RUN/gapps.list" 2>&1 || fail 'ZIP ist beschädigt oder kein ZIP.'
    awk '$NF ~ /^system\// {print $NF}' "$RUN/gapps.list" > "$RUN/gapps.names"
    grep -q '^system/priv-app/Phonesky.apk$' "$RUN/gapps.names" || fail 'Falsche ZIP: system/priv-app/Phonesky.apk fehlt (alte Ordner-Version? Neue gapps-kern.zip verwenden).'
    if grep -q '\.\.' "$RUN/gapps.names"; then fail 'Unsicherer Pfad im ZIP.'; fi
    gapps_mount
    trap 'sync; umount "$ROOTFS" 2>/dev/null || true' EXIT
    free_kb=$(df -k "$ROOTFS" | awk 'NR==2 {print $4}')
    echo "Freier Platz im Android-Image: ${free_kb} kB (benötigt ca. 100000 kB)"
    case "$free_kb" in ''|*[!0-9]*) fail 'Freier Platz unbekannt.' ;; esac
    [ "$free_kb" -ge 100000 ] || fail 'Zu wenig Platz im Android-Image. Image vergrößern oder Daten löschen.'
    for d in $GAPPS_LEGACY_DIRS; do rm -rf "$ROOTFS/system/$d"; done
    echo 'Entpacke Google-Apps (kann einige Minuten dauern) ...'
    unzip -o -q "$zip" 'system/*' -d "$ROOTFS" || fail 'Entpacken fehlgeschlagen (Image voll?).'
    # Rechte: root:root, Ordner 755, Dateien 644
    while read -r n; do
        [ -n "$n" ] || continue
        case "$n" in
            */) chown 0:0 "$ROOTFS/${n%/}"; chmod 755 "$ROOTFS/${n%/}" ;;
            *)  chown 0:0 "$ROOTFS/$n";    chmod 644 "$ROOTFS/$n" ;;
        esac
    done < "$RUN/gapps.names"
    echo 'gapps-core 20220215 nano' > "$ROOTFS/system/etc/kobo-gapps-core"
    chmod 644 "$ROOTFS/system/etc/kobo-gapps-core"
    rm -f "$RUN/gapps.list" "$RUN/gapps.names"
    sync
    echo 'Google-Apps (Core) installiert. Android jetzt starten. Der erste Start ist langsam.'
}
gapps_remove() {
    root_required
    gapps_mount
    trap 'sync; umount "$ROOTFS" 2>/dev/null || true' EXIT
    for d in $GAPPS_LEGACY_DIRS; do rm -rf "$ROOTFS/system/$d"; done
    for f in $GAPPS_APKS $GAPPS_LIBS $GAPPS_FILES; do rm -f "$ROOTFS/system/$f"; done
    sync
    echo 'Google-Apps (Core) entfernt. App-Daten unter /data bleiben bestehen.'
}
gapps_diag() {
    root_required
    out="$BASE/gapps-diag.txt"
    own=0
    if ! mounted "$ROOTFS"; then gapps_mount; own=1; fi
    if [ "$own" = 1 ]; then trap 'umount "$ROOTFS" 2>/dev/null || true' EXIT; fi
    {
        echo "=== Google-Apps Diagnose $(date '+%F %T')"
        if running; then echo 'Android läuft: ja'; else echo 'Android läuft: nein (Image wurde nur für die Prüfung eingebunden)'; fi
        echo "Marker: $(cat "$ROOTFS/system/etc/kobo-gapps-core" 2>/dev/null || echo 'FEHLT (Installation nicht im verwendeten Image)')"
        echo "Android-SDK im Image: $(sed -n 's/^ro.build.version.sdk=//p' "$ROOTFS/system/build.prop" 2>/dev/null | head -n 1)"
        echo "Freier Platz im Image (kB): $(df -k "$ROOTFS" 2>/dev/null | awk 'NR==2 {print $4}')"
        echo '--- Dateien im Image (priv-app)'
        for f in priv-app/Phonesky.apk priv-app/PrebuiltGmsCore.apk priv-app/GoogleServicesFramework.apk priv-app/GoogleLoginService.apk priv-app/SetupWizard.apk lib/libgmscore.so; do
            ls -l "$ROOTFS/system/$f" 2>&1 | sed "s#^#$f: #"
        done
        [ ! -d "$ROOTFS/system/priv-app/Phonesky" ] || echo 'WARNUNG: alter Ordner priv-app/Phonesky vorhanden (KitKat ignoriert Ordner). Neu installieren.'
        echo '--- In Android registriert (packages.xml)'
        if [ -f "$ROOTFS/data/system/packages.xml" ]; then
            ls -l "$ROOTFS/data/system/packages.xml"
            grep -o '<package name="[^"]*"' "$ROOTFS/data/system/packages.xml" | grep -i -E 'google|vending|gsf' || echo 'KEINE Google-Pakete registriert.'
        else
            echo 'keine packages.xml (Android ist noch nie vollständig gebootet).'
        fi
        echo '--- Fehler im Android-Log (PackageManager/Installation)'
        grep -i -E 'PackageManager.*(google|vending|gsf|gms|setupwizard)|INSTALL_FAILED|requires newer|Failed to parse|no certificates|Package .* (has|was) |Skipping' "$ROOTFS/data/local/tmp/android.log" 2>/dev/null | tail -n 30 || true
        echo '--- Ende'
    } > "$out" 2>&1
    cat "$out"
}
gapps_status() {
    root_required
    gapps_mount
    trap 'umount "$ROOTFS" 2>/dev/null || true' EXIT
    if [ -f "$ROOTFS/system/etc/kobo-gapps-core" ]; then echo "Google-Apps Core installiert: $(cat "$ROOTFS/system/etc/kobo-gapps-core")"; else echo 'Google-Apps Core nicht installiert.'; fi
}
# ---- Alle Android-Daten löschen: "reset" = frisches Image, "wipe" = Image entfernen (Platz freigeben) ----
data_reset() {
    mode=$1
    root_required
    running && fail 'Android läuft. Erst beenden.'
    orphan_active && fail 'Verwaiste Android-Prozesse aktiv. Kobo sauber neu starten.'
    if [ "$mode" = reset ]; then
        # Vor dem Löschen prüfen, damit nie ein Android ohne Ersatz zurückbleibt.
        [ -f "$BASE/rootfs.img.gz" ] && [ -f "$BASE/rootfs.img.gz.sha256" ] && [ -f "$BASE/rootfs.size" ] \
            || fail 'rootfs.img.gz fehlt: Zurücksetzen würde Android ohne Ersatz löschen. Nichts geändert.'
    fi
    unmount_tree || fail 'Mounts belegt. Nichts gelöscht. Kobo sauber neu starten.'
    mounted "$ROOTFS" && fail 'Rootfs noch gemountet. Nichts gelöscht.'
    echo 'Lösche Android-Image und Laufzeitdaten ...'
    rm -f "$BASE/rootfs.img" "$BASE"/rootfs.img.new.*
    rm -f "$RUN/runner.pid" "$RUN/container.pid" "$RUN/vnc.pid" "$RUN/ready" "$RUN/gapps.list" "$RUN/gapps.names"
    rmdir "$RUN/lock" 2>/dev/null || true
    for f in android.log android-init.log bootwatch.log watchdog.log watchdog.last stages.log logcat.txt tombstone.txt healthd.txt egl.txt; do
        rm -f "$BASE/$f"
    done
    sync
    if [ "$mode" = reset ]; then
        echo 'Installiere frisches Android-Image (dauert einige Minuten) ...'
        sh "$BASE/install.sh" || fail 'Neuinstallation fehlgeschlagen. Erneut versuchen: sh android.sh reset'
        echo 'Android ist zurückgesetzt (Werkszustand, ohne Google-Apps).'
    else
        echo 'Android-Image entfernt, Speicher ist frei. Neu installieren: sh install.sh'
    fi
    echo "Geteilter Ordner bleibt erhalten: $PUBLIC_SHARED"
}
case "${1:-status}" in
    check) check ;;
    start)
        root_required
        if running; then echo 'Android läuft bereits.'; exit 0; fi
        orphan_active && fail 'Verwaiste Android-Prozesse aktiv. Kobo sauber neu starten.'
        if [ -d "$RUN/lock" ]; then fail 'Verwaister Zustand. Erst sh android.sh recover ausführen.'; fi
        nohup sh "$BASE/android.sh" run >> "$BASE/android.log" 2>&1 < /dev/null &
        echo 'Android startet; Details: android.log'
        ;;
    run) run ;;
    stages) stages ;;
    probe) KOBO_PROBE=1; export KOBO_PROBE; run ;;
    stop)
        root_required
        if running; then
            # Stop important writers before terminating the private PID namespace.
            for service in zygote surfaceflinger installd; do
                chroot "$ROOTFS" /system/bin/setprop ctl.stop "$service" 2>/dev/null || true
            done
            sleep 1; sync
            pid=$(cat "$RUN/runner.pid")
            kill -TERM "$pid"
            i=0
            while running; do i=$((i + 1)); [ "$i" -le 20 ] || fail 'Stopp hängt; keine erzwungenen Unmounts vorgenommen.'; sleep 1; done
        else echo 'Android läuft nicht.'; fi
        ;;
    netinfo) netinfo ;;
    gapps) gapps_install "${2:-}" ;;
    gapps-remove) gapps_remove ;;
    gapps-status) gapps_status ;;
    gapps-diag) gapps_diag ;;
    reset) data_reset reset ;;
    wipe) data_reset wipe ;;
    status)
        if running; then echo 'Android-Prozess läuft (Bootstatus separat prüfen).'; else echo 'Android gestoppt.'; fi
        if mounted "$ROOTFS"; then echo "Rootfs gemountet: $ROOTFS"; fi
        ;;
    diag) root_required; mkdir -p "$ROOTFS/proc" 2>/dev/null || true; proc_diag ;;
    exec)
        root_required; shift
        running && [ -f "$RUN/ready" ] || fail 'Android läuft nicht.'
        [ "$#" -gt 0 ] || fail 'Befehl fehlt.'
        unset LD_PRELOAD LD_LIBRARY_PATH
        exec chroot "$ROOTFS" /system/bin/sh -c 'export PATH=/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data; exec "$@"' android-command "$@"
        ;;
    recover)
        root_required
        running && fail 'Android läuft noch. Erst stop verwenden.'
        orphan_active && fail 'Verwaiste Android-Prozesse noch aktiv. Keine Mounts entfernt; Kobo sauber neu starten.'
        # Never kill arbitrary PIDs or lazy-unmount potentially active filesystems.
        unmount_tree || fail 'Mounts belegt. Gerät sauber neu starten.'
        cpu_perf_off
        rm -f "$RUN/runner.pid" "$RUN/container.pid" "$RUN/vnc.pid" "$RUN/ready"
        rmdir "$RUN/lock" 2>/dev/null || true
        echo 'Laufzeitzustand bereinigt.'
        ;;
    *) echo 'Aufruf: sh android.sh {check|stages|start|stop|status|netinfo|gapps [ZIP]|gapps-remove|gapps-status|gapps-diag|reset|wipe|exec BEFEHL...|recover}' >&2; exit 2 ;;
esac
