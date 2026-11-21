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
KOBO_DEXOPT_REBUILD=${KOBO_DEXOPT_REBUILD:-1} # ART-Cache einmalig mit Optimierung neu aufbauen
KOBO_DIAG_INTERVAL=${KOBO_DIAG_INTERVAL:-15} # Sekunden zwischen Diagnose-Schnappschuessen nach dem Boot
mkdir -p "$RUN"
fail() { echo "Android: $*" >&2; exit 1; }
# Schlaf-Ersatz. Wenn "sleep" nicht startbar ist (z. B. exec auf dem Host schlaegt fehl), darf keine
# Warteschleife auf Vollgas weiterlaufen: das fror den Kobo komplett ein. Nach 3 Fehlschlaegen in Folge: Abbruch.
SLEEP_BIN=$(command -v sleep 2>/dev/null || true)
NAP_FAILS=0
nap() {
    if [ -n "$SLEEP_BIN" ] && "$SLEEP_BIN" "$1" 2>/dev/null; then NAP_FAILS=0; return 0; fi
    NAP_FAILS=$((NAP_FAILS + 1))
    if [ "$NAP_FAILS" -ge 3 ]; then
        echo 'Android: sleep ist auf dem Host nicht ausfuehrbar; Schleife wird beendet (verhindert Einfrieren).' >&2
        exit 1
    fi
    return 0
}
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
    grep -qw devpts /proc/filesystems || fail 'Kernel unterstützt kein devpts; Lollipop logwrapper benötigt PTYs.'
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
    nap 1
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
        nap 1
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
# ART verwendet auf API 21 den Compiler-Filter balanced; der Cache bleibt in /data erhalten und wird
# nach dem ersten Start wiederverwendet. Der Schalter vermeidet die unoptimierte verify-only Variante.
apply_perf_tuning() {
    bp="$ROOTFS/system/build.prop"
    set_prop_file "$bp" dalvik.vm.dex2oat-filter balanced
    set_prop_file "$bp" dalvik.vm.checkjni false
    set_prop_file "$bp" dalvik.vm.heapminfree 1m
    set_prop_file "$bp" dalvik.vm.heapmaxfree 4m
    rc="$ROOTFS/init.rc"
    if [ -f "$rc" ] && grep -q 'dalvik.vm.dex2oat-filter' "$rc"; then
        tmp="$RUN/init.rc.perf"
        awk '$1 == "setprop" && $2 == "dalvik.vm.dex2oat-filter" { print "    setprop dalvik.vm.dex2oat-filter balanced"; next } { print }' "$rc" > "$tmp" \
            && cat "$tmp" > "$rc"
        rm -f "$tmp"
    fi
    marker="$ROOTFS/data/.kobo-dexopt-v1"
    if [ "${KOBO_DEXOPT_REBUILD:-1}" = 1 ] && [ ! -e "$marker" ]; then
        if [ -d "$ROOTFS/data/dalvik-cache" ]; then
            echo "ART-Cache wird einmalig neu optimiert; der naechste Boot dauert dadurch laenger (Optimizing apps)."
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
# tmo SEKUNDEN BEFEHL...: Befehl hoechstens SEKUNDEN laufen lassen. Android-Werkzeuge wie "service check"
# warten ohne servicemanager ewig (Binder-Schleife) und blockierten bisher alle Diagnose-Dateien.
tmo() {
    tmo_s=$1; shift
    "$@" &
    tmo_p=$!
    ( nap "$tmo_s"; kill -KILL "$tmo_p" 2>/dev/null ) >/dev/null 2>&1 &
    tmo_k=$!
    wait "$tmo_p" 2>/dev/null
    tmo_rc=$?
    kill "$tmo_k" 2>/dev/null
    return "$tmo_rc"
}
# Zustand des Android-init festhalten (wo haengt er?) -> initstate.txt, init-dmesg.txt
init_snapshot() {
    ip=''
    for d in /proc/[0-9]*; do
        [ "$(readlink "$d/root" 2>/dev/null)" = "$ROOTFS" ] || continue
        [ "$(cat "$d/comm" 2>/dev/null)" = init ] && { ip=${d#/proc/}; break; }
    done
    {
        echo "=== $(date +%T) init-pid=${ip:-keiner}"
        if [ -n "$ip" ]; then
            echo "--- stat:";    cat "/proc/$ip/stat" 2>&1
            echo "--- wchan:";   cat "/proc/$ip/wchan" 2>&1; echo
            echo "--- syscall:"; cat "/proc/$ip/syscall" 2>&1
            echo "--- stack:";   cat "/proc/$ip/stack" 2>&1
            echo "--- fd:";      ls -l "/proc/$ip/fd" 2>&1
            echo "--- Kinder:"
            for d in /proc/[0-9]*; do
                pp=$(sed -n 's/^PPid:[[:space:]]*//p' "$d/status" 2>/dev/null)
                [ "$pp" = "$ip" ] && echo "${d#/proc/} $(cat "$d/comm" 2>/dev/null)"
            done
        fi
        echo "--- /dev im Rootfs:"; ls -l "$ROOTFS/dev" 2>&1 | head -n 40
        echo "--- /dev/__properties__:"; ls -l "$ROOTFS/dev/__properties__" 2>&1 | head -n 5
    } >> "$BASE/initstate.txt" 2>&1
    dmesg 2>/dev/null | grep -F ':init]' | tail -n 400 > "$BASE/init-dmesg.txt" 2>&1
}
# ---- SELinux-Schutz des Kobo-Kernels ----------------------------------------------------------------
# Chroot und Host teilen sich denselben Kernel. Das stock-/init der SDK-Ramdisk laedt beim Start seine
# /sepolicy in den Kernel (selinuxfs). Danach passen die Labels aller Kobo-Prozesse nicht mehr zur Policy:
# jedes exec auf dem Host scheitert mit "Permission denied" (sleep, tr, cat, ls ... in android.log) und
# der eReader haengt sich auf. Abhilfe: init so veraendern, dass er SELinux als "nicht vorhanden" sieht
# (selinux_is_disabled() prueft access("/sys/fs/selinux")); die Policy des Kobo bleibt dann unberuehrt.
host_has_selinux() {
    [ -e /sys/fs/selinux/enforce ] || [ -e /sys/fs/selinux/policyvers ] || grep -qs selinuxfs /proc/filesystems 2>/dev/null
}
patch_init_selinux() {
    init="$ROOTFS/init"
    [ -f "$init" ] || return 0
    grep -aq '/sys/fs/selinux' "$init" || return 0      # bereits umgebaut (oder kein SELinux-Code)
    if ! grep -aq 'ro.boot.selinux' "$init"; then
        host_has_selinux && fail 'Android-init kann SELinux nicht abschalten und wuerde die Kobo-Policy ersetzen. Start abgebrochen (Kobo wuerde einfrieren).'
        return 0
    fi
    n=$(grep -ao '/sys/fs/selinux' "$init" | wc -l)
    tmp="$RUN/init.selinux.new"
    rm -f "$tmp"
    sed 's|/sys/fs/selinux|/sys/fs/selinuX|g' "$init" > "$tmp" 2>/dev/null || true
    ok=0
    if [ -s "$tmp" ] && [ "$(wc -c < "$init")" = "$(wc -c < "$tmp")" ] && ! grep -aq '/sys/fs/selinux' "$tmp"; then
        ok=1
        # Nur die erwarteten Bytes duerfen sich geaendert haben (sed auf Binaerdateien pruefen).
        if command -v cmp >/dev/null 2>&1; then
            [ "$(cmp -l "$init" "$tmp" 2>/dev/null | wc -l)" = "$n" ] || ok=0
        fi
    fi
    if [ "$ok" = 1 ]; then
        cat "$tmp" > "$init" && sync
        rm -f "$tmp"
        if grep -aq '/sys/fs/selinux' "$init"; then ok=0; fi
    fi
    rm -f "$tmp"
    if [ "$ok" = 1 ]; then
        echo "init: SELinux-Policy-Laden abgeschaltet (Kobo-Policy bleibt unberuehrt)"
    else
        host_has_selinux && fail 'init konnte nicht gegen SELinux-Laden abgesichert werden. Start abgebrochen (Kobo wuerde einfrieren). Neues Paket installieren.'
        echo "Hinweis: init-SELinux-Patch uebersprungen (Host ohne SELinux)."
    fi
}
# Stock-init meldet im Kernel-Log nur Fehler. Mit "loglevel" erscheinen seine INFO-Meldungen (Befehle, Dienststarts)
# in dmesg -> init-dmesg.txt. Abschaltbar mit KOBO_INIT_LOGLEVEL=3 in der config.
# KOBO_NICE_V1: Stock-init.rc setzt "setrlimit 13 40 40" (RLIMIT_NICE). Ohne das Limit (hier 0) wirft
# Process.setThreadPriority() fuer App-Threads "SecurityException: No permission to set to given priority"
# -> Launcher2 (LoaderTask, LauncherModel.java:1155) stirbt als "launcher-loader" kurz nach dem Start.
patch_init_nice() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -q 'KOBO_NICE_V1' "$rc" && return 0
    tmp="$RUN/init.rc.nice"
    awk '{ print }
        $1 == "on" && $2 == "init" && NF == 2 && !done {
            print "    # KOBO_NICE_V1"
            print "    setrlimit 13 40 40"
            done = 1 }' "$rc" > "$tmp" || { rm -f "$tmp"; return 0; }
    if grep -q 'KOBO_NICE_V1' "$tmp"; then cat "$tmp" > "$rc"; echo "init.rc angepasst (KOBO_NICE_V1: RLIMIT_NICE 40)"
    else echo "WARNUNG: KOBO_NICE_V1 nicht eingefuegt (keine Zeile 'on init' in init.rc)"; fi
    rm -f "$tmp"
}
# KOBO_LMKD_V1: ActivityManager schreibt jede oom_adj-Aenderung an den Socket "lmkd". Fehlt er, wartet
# ProcessList.writeLmkd() 3 x 1 s ("SLOW OOM ADJ: 3002ms", "lowmemorykiller daemon socket open failed") und haelt dabei
# das AMS-Lock -> System/UI haengt minutenlang (im Log 117 x). Stock-init.rc startet dafuer den Dienst lmkd.
patch_init_lmkd() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -Eq '^service lmkd ' "$rc" && return 0
    if [ ! -x "$ROOTFS/system/bin/lmkd" ]; then
        echo "WARNUNG: $ROOTFS/system/bin/lmkd fehlt -> AMS blockiert weiter je 3 s pro oom_adj-Aenderung"
        return 0
    fi
    {
        echo ''
        echo '# KOBO_LMKD_V1'
        echo 'service lmkd /system/bin/lmkd'
        echo '    class core'
        echo '    socket lmkd seqpacket 0660 system system'
    } >> "$rc"
    echo "init.rc angepasst (KOBO_LMKD_V1: Dienst lmkd)"
}
patch_init_loglevel() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    lvl=${KOBO_INIT_LOGLEVEL:-6}
    tmp="$RUN/init.rc.ll"
    awk -v lvl="$lvl" '
        /KOBO_LOGLEVEL_V1/ { getline; next }
        { print }
        $1 == "on" && $2 == "early-init" && NF == 2 && !done {
            print "    # KOBO_LOGLEVEL_V1"
            print "    loglevel " lvl
            done = 1
        }' "$rc" > "$tmp" || { rm -f "$tmp"; return 0; }
    grep -q 'KOBO_LOGLEVEL_V1' "$tmp" && cat "$tmp" > "$rc"
    rm -f "$tmp"
}
# Lollipop-init loest nach "init" nur "late-init" aus. Fehlt dieser Abschnitt in der init.rc, laufen fs, post-fs-data
# und boot nie: kein einziger Dienst startet, kein servicemanager, kein Bootbild. Idempotent, auch fuer alte Rootfs.
patch_init_lateinit() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -q 'KOBO_LATEINIT_V1' "$rc" && return 0
    grep -Eq '^on[[:space:]]+late-init[[:space:]]*$' "$rc" && return 0
    {
        echo ''
        echo '# KOBO_LATEINIT_V1: Lollipop-init triggert nur late-init; Boot-Kette hier nachziehen.'
        echo 'on late-init'
        echo '    trigger early-fs'
        echo '    trigger fs'
        echo '    trigger post-fs'
        echo '    trigger post-fs-data'
        echo '    trigger early-boot'
        echo '    trigger boot'
    } >> "$rc" || fail 'init.rc: late-init-Abschnitt konnte nicht angehaengt werden.'
    echo "init.rc angepasst (KOBO_LATEINIT_V1)"
}
# init.environ.rc laeuft NACH der init.rc und ueberschreibt LD_PRELOAD (libsigchain.so statt Binder-Shim). Dienste
# (servicemanager, healthd, installd ...) beenden sich dann sofort. Export in "on late-init" nachziehen (idempotent).
patch_init_preload() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -q 'KOBO_PRELOAD_V1' "$rc" && return 0
    grep -q 'export LD_PRELOAD /system/lib/libkobofb.so:libsigchain.so' "$rc" && return 0
    tmp="$RUN/init.rc.preload"
    awk '{ print }
        $1 == "on" && $2 == "late-init" && NF == 2 && !done {
            print "    # KOBO_PRELOAD_V1: Binder-Shim nach init.environ.rc erneut setzen."
            print "    export LD_PRELOAD /system/lib/libkobofb.so:libsigchain.so"
            done = 1
        }' "$rc" > "$tmp" || { rm -f "$tmp"; fail 'init.rc: LD_PRELOAD-Patch fehlgeschlagen.'; }
    grep -q 'KOBO_PRELOAD_V1' "$tmp" || { rm -f "$tmp"; fail 'init.rc: "on late-init" fehlt fuer LD_PRELOAD-Patch.'; }
    cat "$tmp" > "$rc" && rm -f "$tmp"
    echo "init.rc angepasst (KOBO_PRELOAD_V1)"
}
# installd bricht ohne /data/misc/user ab ("Failed to mkdir(/data/misc/user/0)"); das Stock-init legt es in "on post-fs-data" an.
# Fehlende Datenverzeichnisse in "on late-init" nachziehen (idempotent, auch fuer alte Rootfs).
patch_init_datadirs() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -q 'KOBO_DATADIRS_V1' "$rc" && return 0
    grep -Eq '^[[:space:]]+mkdir /data/misc/user ' "$rc" && return 0
    tmp="$RUN/init.rc.datadirs"
    awk '{ print }
        $1 == "on" && $2 == "late-init" && NF == 2 && !done {
            print "    # KOBO_DATADIRS_V1: Verzeichnisse, die installd/system_server voraussetzen."
            print "    mkdir /data/misc/user 0771 system system"
            print "    mkdir /data/misc/sms 0770 system radio"
            print "    mkdir /data/misc/zoneinfo 0775 system system"
            print "    mkdir /data/user 0711 system system"
            print "    mkdir /data/media 0770 media_rw media_rw"
            done = 1
        }' "$rc" > "$tmp" || { rm -f "$tmp"; fail 'init.rc: Datenverzeichnis-Patch fehlgeschlagen.'; }
    grep -q 'KOBO_DATADIRS_V1' "$tmp" || { rm -f "$tmp"; fail 'init.rc: "on late-init" fehlt fuer Datenverzeichnis-Patch.'; }
    cat "$tmp" > "$rc" && rm -f "$tmp"
    echo "init.rc angepasst (KOBO_DATADIRS_V1)"
}
# KOBO_STORAGE_ENV_V1: Ursache des Zygote-Neustarts (zygote.err): Environment.getLegacyExternalStorageDirectory() ruft
# new File(System.getenv("EXTERNAL_STORAGE")) -> NPE in Debug.<clinit> -> ExceptionInInitializerError im Klassen-Preload.
# Das eigene init.rc exportiert die Speicher-Variablen des Stock-init nicht.
patch_init_storage_env() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -q 'KOBO_STORAGE_ENV_V1' "$rc" && return 0
    tmp="$RUN/init.rc.storenv"
    awk '{ print }
        $1 == "on" && $2 == "late-init" && NF == 2 && !done {
            print "    # KOBO_STORAGE_ENV_V1: Speicher-Variablen fuer zygote/system_server."
            print "    export EXTERNAL_STORAGE /storage/sdcard"
            print "    export ANDROID_STORAGE /storage"
            print "    export ASEC_MOUNTPOINT /mnt/asec"
            print "    export LOOP_MOUNTPOINT /mnt/obb"
            done = 1
        }' "$rc" > "$tmp" || { rm -f "$tmp"; fail 'init.rc: Storage-Env-Patch fehlgeschlagen.'; }
    grep -q 'KOBO_STORAGE_ENV_V1' "$tmp" || { rm -f "$tmp"; fail 'init.rc: "on late-init" fehlt fuer Storage-Env-Patch.'; }
    cat "$tmp" > "$rc" && rm -f "$tmp"
    echo "init.rc angepasst (KOBO_STORAGE_ENV_V1)"
}
# KOBO_NOPERSIST_V1: Ursache des Absturzes waehrend der Bootanimation (init-Log endet ~0,4 s nach dem Start von system_server):
# Sobald "load_persist_props" gelaufen ist, schreibt init jede gesetzte persist.*-Property zusaetzlich nach /data/property
# (write_persistent_property). Genau dabei stirbt der Android-init in diesem Chroot - reproduzierbar:
#  - KOBO_PROPS_V2 mit 69 Eintraegen: init-Log endete direkt hinter der Zeile nach ro.config.alarm_alert, dort steht in
#    build.prop persist.sys.dalvik.vm.lib.2 (deshalb wurden persist.* dort ausgefiltert);
#  - load_all_props (V1): init starb sofort, weil build.prop dieselbe Property enthaelt;
#  - jetzt, wo zygote nicht mehr abbricht: system_server setzt als allererstes SystemProperties.set("persist.sys.dalvik.vm.lib.2")
#    -> init stirbt -> android.sh beendet Container + VNC -> das Plugin verliert das Bild.
# Ohne "load_persist_props" bleibt persistent_properties_loaded=0: persist.*-Properties gelten nur im Speicher (init schreibt
# nichts nach /data/property). Android-Einstellungen liegen in /data/system und /data/data und bleiben erhalten.
patch_init_nopersist() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -Eq '^[[:space:]]*load_persist_props[[:space:]]*$' "$rc" || return 0
    tmp="$RUN/init.rc.nopersist"
    awk '$1 == "load_persist_props" && NF == 1 {
            print "    # KOBO_NOPERSIST_V1: load_persist_props abgeschaltet (init stirbt beim Schreiben von persist.*-Properties)"
            next
        }
        { print }' "$rc" > "$tmp" || { rm -f "$tmp"; fail 'init.rc: NoPersist-Patch fehlgeschlagen.'; }
    grep -q 'KOBO_NOPERSIST_V1' "$tmp" || { rm -f "$tmp"; fail 'init.rc: load_persist_props nicht ersetzt.'; }
    cat "$tmp" > "$rc" && rm -f "$tmp"
    # Bereits vorhandene Dateien aus frueheren Laeufen entfernen: ohne Ladevorgang werden sie ohnehin nie gelesen.
    rm -rf "$ROOTFS/data/property" 2>/dev/null || true
    mkdir -p "$ROOTFS/data/property" 2>/dev/null || true
    chmod 0700 "$ROOTFS/data/property" 2>/dev/null || true
    echo "init.rc angepasst (KOBO_NOPERSIST_V1: persist.*-Properties nur im Speicher)"
}
# Kernel drosselt /dev/kmsg-Schreiber (10 Zeilen/5 s je offener Datei): init-Meldungen gingen verloren.
devkmsg_unlimit() {
    f=/proc/sys/kernel/printk_devkmsg
    [ -w "$f" ] || return 0
    DEVKMSG_OLD=$(cat "$f" 2>/dev/null)
    echo on > "$f" 2>/dev/null || true
}
devkmsg_restore() {
    [ -n "${DEVKMSG_OLD:-}" ] && echo "$DEVKMSG_OLD" > /proc/sys/kernel/printk_devkmsg 2>/dev/null || true
}
# KOBO_ZYGOTE_FIX_V1: zygote (app_process) bricht mit "Unable to determine ABI list from property
# ro.product.cpu.abilist32" ab, netd ohne /data/misc/net (rt_tables, fwmarkd), installd ohne .layout_version.
# Idempotent bei jedem Start: Props setzen und Verzeichnisse direkt im gemounteten Rootfs anlegen.
fix_zygote_netd() {
    bp="$ROOTFS/system/build.prop"
    set_prop_file "$bp" ro.product.cpu.abi armeabi-v7a
    set_prop_file "$bp" ro.product.cpu.abi2 ""
    set_prop_file "$bp" ro.product.cpu.abilist armeabi-v7a,armeabi
    set_prop_file "$bp" ro.product.cpu.abilist32 armeabi-v7a,armeabi
    set_prop_file "$bp" ro.product.cpu.abilist64 ""
    set_prop_file "$bp" ro.zygote default
    [ -f "$ROOTFS/default.prop" ] && {
        set_prop_file "$ROOTFS/default.prop" ro.product.cpu.abilist32 armeabi-v7a,armeabi
        set_prop_file "$ROOTFS/default.prop" ro.product.cpu.abilist armeabi-v7a,armeabi
    }
    mkdir -p "$ROOTFS/data/misc/net" "$ROOTFS/data/misc/wifi/sockets" "$ROOTFS/data/misc/user/0" \
        "$ROOTFS/data/system" "$ROOTFS/data/dalvik-cache" "$ROOTFS/data/app" "$ROOTFS/data/data"
    chmod 0750 "$ROOTFS/data/misc/net"
    [ -f "$ROOTFS/data/.layout_version" ] || echo 2 > "$ROOTFS/data/.layout_version"
    chown 1000:1000 "$ROOTFS/data/system" "$ROOTFS/data/app" "$ROOTFS/data/data" "$ROOTFS/data/dalvik-cache" \
        "$ROOTFS/data/misc/user" "$ROOTFS/data/misc/user/0" "$ROOTFS/data/.layout_version" 2>/dev/null || true
    echo "zygote/netd-Fix angepasst (KOBO_ZYGOTE_FIX_V1)"
}
# KOBO_PMFIX_V1: logcat zeigt "Error reading package manager settings ... Unexpected EOF" in /data/system/packages.xml
# (Dateiende = Muell/NUL-Bytes, mitten in einem <cert>-Eintrag abgeschnitten) -> PackageManagerService.<init> stirbt mit
# NullPointerException in compareSignatures -> system_server -> zygote-Neustart. Ursache: ext4 data=writeback + barrier=0 +
# commit=60 auf einer Image-Datei; nach hartem Kobo-Neustart/Absturz bleiben halb geschriebene Dateien zurueck.
# Ist die massgebliche Datei (packages-backup.xml, falls vorhanden, sonst packages.xml) beschaedigt, wird die Paketdatenbank
# verworfen; Android scannt /system und /data/app beim naechsten Start neu (erster Boot dauert dann laenger).
fix_pm_settings() {
    d="$ROOTFS/data/system"
    [ -d "$d" ] || return 0
    eff=packages.xml
    [ ! -e "$d/packages-backup.xml" ] || eff=packages-backup.xml
    [ -e "$d/$eff" ] || return 0
    total=$(wc -c < "$d/$eff")
    clean=$(tr -d '\000' < "$d/$eff" | wc -c)
    if [ "$total" != "$clean" ] || ! tail -c 64 "$d/$eff" | grep -q '</packages>'; then
        rm -f "$d/packages.xml" "$d/packages-backup.xml" "$d/packages.list" "$d/packages-stopped.xml" "$d/packages-stopped-backup.xml"
        echo "KOBO_PMFIX_V1: beschaedigte $eff entfernt ($total Bytes, $((total - clean)) NUL-Bytes); Paketdatenbank wird neu aufgebaut."
    fi
}
# KOBO_BOOTFIX_V2: (1) ART relokiert boot.art per patchoat, das hier abstuerzt ("gap between the image
# space and the main space") -> zygote faellt auf imageless zurueck und stirbt. -Xnorelocate nutzt das
# Original-Image. (2) netd braucht den Socket fwmarkd (sonst "Unable to start FwmarkServer" -> Neustart).
# (3) Ohne "service bootanim" in init.rc startet surfaceflinger (ctl.start bootanim) keine Bootanimation.
fix_boot_v2() {
    set_prop_file "$ROOTFS/system/build.prop" dalvik.vm.extra-opts -Xnorelocate
    rm -f "$ROOTFS"/data/dalvik-cache/arm/system@framework@boot.* 2>/dev/null || true
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    tmp="$RUN/init.rc.bootv2"
    if ! grep -q 'socket fwmarkd' "$rc"; then
        awk '{ print }
            $1 == "service" && $2 == "netd" { print "    socket fwmarkd stream 0660 root inet" }' "$rc" > "$tmp" \
            && cat "$tmp" > "$rc"; rm -f "$tmp"
    fi
    if ! grep -Eq '^service bootanim ' "$rc"; then
        {
            echo ''
            echo '# KOBO_BOOTFIX_V2'
            echo 'service bootanim /system/bin/bootanimation'
            echo '    class core'
            echo '    user graphics'
            echo '    group graphics audio'
            echo '    disabled'
            echo '    oneshot'
        } >> "$rc"
    fi
    # KOBO_BOOTFIX_V3: Property dalvik.vm.extra-opts wird nicht ausgewertet -> Option direkt an app_process.
    if ! grep -E '^service zygote ' "$rc" | grep -q -- '-Xnorelocate'; then
        awk '$1 == "service" && $2 == "zygote" && index($0, "-Xnorelocate") == 0 { sub(/-Xzygote/, "-Xzygote -Xnorelocate") } { print }' "$rc" > "$tmp" \
            && cat "$tmp" > "$rc"; rm -f "$tmp"
    fi
    # KOBO_BOOTFIX_V4: svc/settings/am/pm/... starten app_process ohne -Xnorelocate -> patchoat-relokiertes Image ->
    # "gap between the image space and the main space" (SIGABRT). Option in die Wrapper-Skripte eintragen.
    # KOBO_BOOTFIX_V5: Muster verallgemeinert (auch "app_process $base/bin", ohne "exec"), plus dex2oat-Wrapper:
    # installd ruft /system/bin/dex2oat ohne -Xnorelocate -> "Only the zygote can create the global boot image"
    # -> imageless -> Heap-Abbruch. Der Wrapper setzt die Option; dex2oat.real ist das Original.
    for w in "$ROOTFS"/system/bin/*; do
        [ -f "$w" ] && [ ! -L "$w" ] || continue
        # Die AOSP-Wrapper (svc, settings, pm, ime, input ...) haben KEINE #!-Zeile (sh startet sie per ENOEXEC-Fallback);
        # deshalb nur ELF-Binaerdateien ueberspringen (KOBO_BOOTFIX_V6).
        head -c 4 "$w" 2>/dev/null | grep -aq 'ELF' && continue
        grep -aq 'app_process ' "$w" 2>/dev/null || continue
        grep -aq -- '-Xnorelocate' "$w" 2>/dev/null && continue
        sed 's#app_process \([^-]\)#app_process -Xnorelocate \1#' "$w" > "$RUN/wrap.new" && cat "$RUN/wrap.new" > "$w"
    done
    rm -f "$RUN/wrap.new"
    # KOBO_HEAPGAP_V1: "gap between the image space and the main space": ART legt den Hauptheap direkt hinter boot.oat
    # (0x73a74000) an. Dort ist bis zum PIE-Binary (app_process32/dex2oat bei ~0x7f5e3000) nur ca. 190 MB frei. Ist der
    # reservierte Heap (-Xmx) groesser, weicht der Kernel aus -> Luecke -> Abbruch. Tools brauchen wenig: Obergrenze 96 MB.
    for w in "$ROOTFS"/system/bin/*; do
        [ -f "$w" ] && [ ! -L "$w" ] || continue
        head -c 4 "$w" 2>/dev/null | grep -aq 'ELF' && continue
        grep -aq 'app_process -Xnorelocate ' "$w" 2>/dev/null || continue
        grep -aq -- '-Xmx' "$w" 2>/dev/null && continue
        grep -aq -- '-Xzygote' "$w" 2>/dev/null && continue   # Zygote behaelt seinen grossen Heap
        case "$w" in *zygote*) continue ;; esac
        sed 's#app_process -Xnorelocate #app_process -Xnorelocate -Xmx96m -XX:HeapGrowthLimit=96m #' "$w" > "$RUN/wrap.new" && cat "$RUN/wrap.new" > "$w"
    done
    rm -f "$RUN/wrap.new"
    # KOBO_DEX2OAT_V2: mit -Xnorelocate laeuft das Image, aber dex2oat scheitert an der 512-MB-Heap-Reservierung
    # ("heap.cc:274 Failed anonymous mmap(0x0, 536870912 ...): Out of memory"). Wrapper kappt -Xmx/-Xms
    # (KOBO_DEX2OAT_XMX in MB, Standard 256). Wird bei jedem Start neu geschrieben.
    d2="$ROOTFS/system/bin/dex2oat"
    if [ -f "$d2" ] && ! head -c 2 "$d2" | grep -aq '^#!'; then
        cp "$d2" "$ROOTFS/system/bin/dex2oat.real" && chmod 0755 "$ROOTFS/system/bin/dex2oat.real"
    fi
    if [ -f "$ROOTFS/system/bin/dex2oat.real" ]; then
        cat > "$d2" <<'D2EOF'
#!/system/bin/sh
# Heap schrittweise verkleinern, wenn die Reservierung (Out of memory / Abort) scheitert.
conv() {
    mx=$1; shift; flt=$1; shift
    n=$#
    while [ "$n" -gt 0 ]; do
        a=$1; shift
        case "$a" in
            -Xmx*) a=-Xmx${mx}m ;;
            -Xms*) a=-Xms32m ;;
            --compiler-filter=*) [ -n "$flt" ] && a=--compiler-filter=$flt ;;
        esac
        set -- "$@" "$a"
        n=$((n - 1))
    done
    /system/bin/dex2oat.real --runtime-arg -Xnorelocate --runtime-arg -Xmx${mx}m "$@"
}
conv 128 "" "$@"; rc=$?
[ "$rc" -eq 0 ] && exit 0
echo "dex2oat rc=$rc bei 128m: $*" >> /data/local/tmp/dex2oat-wrap.log
conv 96 interpret-only "$@"; rc=$?
[ "$rc" -eq 0 ] && exit 0
echo "dex2oat rc=$rc bei 96m: $*" >> /data/local/tmp/dex2oat-wrap.log
conv 64 interpret-only "$@"; rc=$?
echo "dex2oat rc=$rc bei 64m" >> /data/local/tmp/dex2oat-wrap.log
exit $rc
D2EOF
        chmod 0755 "$d2"
    fi
    [ -f "$ROOTFS/system/media/bootanimation.zip" ] || echo "WARNUNG: /system/media/bootanimation.zip fehlt im Rootfs"
    echo "Boot-Fix V2 angewendet (norelocate, fwmarkd, bootanim)"
}
# KOBO_PROPS_V1: Das eigene init.rc triggert nie "load_(all|system)_props" -> /system/build.prop wird NIE geladen
# (im Log: zygote startet mit -Xmx16m/-Xms4m, ohne HeapMinFree/dex2oat-filter; dalvik.vm.extra-opts wirkte nie).
# (1) Heap-Properties zusaetzlich in /default.prop (wird von init immer geladen).
# (2) build.prop wird bei jedem Start als Liste von "setprop"-Zeilen in eine eigene init.rc-Action uebersetzt.
#     Der init-Builtin "load_all_props" ist KEINE Option: er hat init beim Start abstuerzen lassen (Container beendet).
fix_props_v1() {
    for f in "$ROOTFS/system/build.prop" "$ROOTFS/default.prop"; do
        [ -f "$f" ] || continue
        set_prop_file "$f" dalvik.vm.heapstartsize 8m
        set_prop_file "$f" dalvik.vm.heapgrowthlimit 128m
        set_prop_file "$f" dalvik.vm.heapsize 256m
        set_prop_file "$f" dalvik.vm.heaptargetutilization 0.75
        set_prop_file "$f" dalvik.vm.heapminfree 1m
        set_prop_file "$f" dalvik.vm.heapmaxfree 4m
    done
    rc="$ROOTFS/init.rc"; bp="$ROOTFS/system/build.prop"
    [ -f "$rc" ] && [ -f "$bp" ] || return 0
    tmp="$RUN/init.rc.props"
    # Alte Action (auch die fruehere mit "load_all_props") entfernen; fehlenden Trigger vor early-boot einfuegen.
    awk 'BEGIN { skip = 0 }
        $1 == "on" && $2 == "kobo_load_props" { skip = 1; next }
        skip && ($0 ~ /^[ \t]/ || $0 ~ /^[ \t]*$/) { next }
        { skip = 0; print }' "$rc" > "$tmp" || { rm -f "$tmp"; fail 'init.rc: Props-Patch fehlgeschlagen.'; }
    if ! grep -q 'trigger kobo_load_props' "$tmp"; then
        awk '$1 == "trigger" && $2 == "early-boot" && !done { print "    # KOBO_PROPS_V2: build.prop laden"; print "    trigger kobo_load_props"; done = 1 } { print }' "$tmp" > "$tmp.2" \
            && cat "$tmp.2" > "$tmp"; rm -f "$tmp.2"
        grep -q 'trigger kobo_load_props' "$tmp" || { rm -f "$tmp"; fail 'init.rc: "trigger early-boot" fehlt fuer Props-Patch.'; }
    fi
    {
        cat "$tmp"
        echo ''
        echo 'on kobo_load_props'
        awk 'BEGIN { FS = "=" }
            /^[A-Za-z]/ && index($0, "=") > 1 {
                k = $1; v = substr($0, length(k) + 2)
                sub(/\r$/, "", v)
                if (length(k) > 31 || length(v) > 91) next
                if (k ~ /[ \t"]/ || v ~ /["\\$]/) next
                # init stirbt mitten in der Action (Log endet nach ca. der 36. Zeile): riskante Schluessel auslassen.
                if (k ~ /^(persist\.|ro\.kernel\.|debug\.|ro\.hardware)/) next
                print "    setprop " k " \"" v "\""
            }' "$bp"
        # KOBO_NOGLES_V3: ro.kernel.* wird oben uebersprungen, HardwareRenderer.isAvailable() (API 21) braucht aber
        # ro.kernel.qemu=1 UND qemu.gles=0, sonst startet libhwui und der Launcher bricht mit "Failed to choose config" ab.
        if [ "${KOBO_NOGLES:-1}" = 1 ]; then
            echo '    # KOBO_NOGLES_V3: Apps ohne Hardwarebeschleunigung (kein GLES2)'
            echo '    setprop ro.kernel.qemu "1"'
            echo '    setprop qemu.gles "0"'
        fi
    } > "$rc"
    rm -f "$tmp"
    # Mit init.rc-Zeilennummern ablegen: die erste NICHT im init-Log stehende Zeile ist der Ausloeser, falls init wieder stirbt.
    awk '/^on kobo_load_props/ { f = 1 } f { print NR ": " $0 }' "$rc" > "$BASE/props-block.txt" 2>/dev/null
    echo "init.rc angepasst (KOBO_PROPS_V2: build.prop als setprop-Liste, $(grep -c '^    setprop .* "' "$rc") Eintraege)"
}
# KOBO_ZYGOTE_LOG_V2: stdout/stderr von app_process gehen sonst nach /dev/null; ein unbehandelter Java-Fehler im zygote
# (Exit-Status 0, kein Logeintrag) bleibt damit unsichtbar. Start-Skript (kein exec): schreibt Ausgabe und Exit-Code
# nach /data/local/tmp/zygote.err. (init.rc darf kein "$" ausser "${prop}" enthalten, deshalb ein eigenes Skript.)
fix_zygote_log() {
    [ "${KOBO_ZYGOTE_LOG:-1}" = 1 ] || return 0
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    mkdir -p "$ROOTFS/data/local/tmp"
    : > "$ROOTFS/data/local/tmp/zygote.err" 2>/dev/null; chmod 0666 "$ROOTFS/data/local/tmp/zygote.err" 2>/dev/null
    cat > "$ROOTFS/system/bin/kobo-zygote.sh" <<'ZYG'
#!/system/bin/sh
E=/data/local/tmp/zygote.err
[ -n "$EXTERNAL_STORAGE" ] || export EXTERNAL_STORAGE=/storage/sdcard
[ -n "$ANDROID_STORAGE" ] || export ANDROID_STORAGE=/storage
[ -n "$ASEC_MOUNTPOINT" ] || export ASEC_MOUNTPOINT=/mnt/asec
[ -n "$LOOP_MOUNTPOINT" ] || export LOOP_MOUNTPOINT=/mnt/obb
echo "=== zygote start $(date) uid=$(id)" >> $E
# Lollipop-Toolbox kennt weder grep noch tail/head/cut/env (sonst Exit 127): nur printenv, ls, read, case.
printenv | while read -r l; do
    case "$l" in ANDROID_*|BOOTCLASSPATH*|LD_*|EXTERNAL*) echo "$l" >> $E ;; esac
done
ls -l /data/anr /data/dalvik-cache /data/dalvik-cache/arm >> $E 2>&1
/system/bin/app_process -Xzygote -Xnorelocate /system/bin --zygote --start-system-server >> $E 2>&1
rc=$?
echo "=== app_process exit=$rc $(date)" >> $E
exit $rc
ZYG
    chmod 0755 "$ROOTFS/system/bin/kobo-zygote.sh"
    mkdir -p "$ROOTFS/data/anr"; chmod 0775 "$ROOTFS/data/anr"; chown 1000:1000 "$ROOTFS/data/anr" 2>/dev/null || true
    grep -q 'kobo-zygote.sh' "$rc" && return 0
    tmp="$RUN/init.rc.zlog"
    awk '$1 == "service" && $2 == "zygote" { print "service zygote /system/bin/sh /system/bin/kobo-zygote.sh"; next } { print }' "$rc" > "$tmp" || { rm -f "$tmp"; return 0; }
    grep -q 'kobo-zygote.sh' "$tmp" && cat "$tmp" > "$rc"
    rm -f "$tmp"
    echo "init.rc angepasst (KOBO_ZYGOTE_LOG_V2)"
}
# KOBO_INSTALLD_LOG_V1: installd wird im init-Log jedes Mal ~7 ms nach dem Start mit Status 9 (SIGKILL) beendet; system_server
# kann deshalb keine App-Datenverzeichnisse anlegen ("Unable to create data dirs [errorCode=-1]" fuer ALLE Pakete).
# Wrapper (kein exec; Socket-Deskriptor und ANDROID_SOCKET_installd werden vererbt) schreibt Umgebung, Ausgabe und Exit-Code
# nach /data/local/tmp/installd.err (-> $BASE/installd.err).
fix_installd_log() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    mkdir -p "$ROOTFS/data/local/tmp"
    : > "$ROOTFS/data/local/tmp/installd.err" 2>/dev/null; chmod 0666 "$ROOTFS/data/local/tmp/installd.err" 2>/dev/null
    cat > "$ROOTFS/system/bin/kobo-installd.sh" <<'INS'
#!/system/bin/sh
# KOBO_INSTALLD_LOG_V2: Lollipop-toolbox hat kein head/grep/cut -> die V1-Diagnose war leer. Nur Builtins/toolbox-Befehle verwenden.
E=/data/local/tmp/installd.err
{
echo "=== installd start $(date) $(id) umask=$(umask)"
echo "ANDROID_SOCKET_installd=$ANDROID_SOCKET_installd LD_PRELOAD=$LD_PRELOAD ANDROID_DATA=$ANDROID_DATA ANDROID_ROOT=$ANDROID_ROOT"
ls -l /dev/null /dev/urandom /dev/random 2>&1
ls -l /system/bin/installd /system/bin/linker /system/lib/libkobofb.so /data /data/.layout_version /data/misc/user /data/user /data/media 2>&1
ls -l /proc/self/fd 2>&1
cat /proc/self/limits 2>&1
cat /proc/self/oom_score_adj 2>&1
cat /proc/meminfo 2>&1 | while read k v; do case "$k" in MemFree:|MemAvailable:|Cached:) echo "$k $v";; esac; done
} >> $E 2>&1
# Startet das Kommando im Hintergrund und merkt sich bis zum Tod den letzten Stand aus /proc (nur Shell-Builtins, kein fork).
probe() {
    name=$1; shift
    echo "--- Versuch $name" >> $E
    "$@" >> $E 2>&1 &
    p=$!
    sc=; wc=; st=; n=0; maps=
    while [ -e /proc/$p/stat ]; do
        read a < /proc/$p/syscall 2>/dev/null && sc=$a
        read b < /proc/$p/wchan 2>/dev/null && wc=$b
        read c < /proc/$p/stat 2>/dev/null && st=$c
        n=$((n + 1))
        if [ $((n % 20)) -eq 0 ]; then
            while read l; do maps=$l; done < /proc/$p/maps 2>/dev/null
        fi
        case "$st" in *" Z "*) break;; esac
    done
    wait $p; rc=$?
    echo "last syscall: $sc" >> $E
    echo "last wchan:   $wc" >> $E
    echo "last stat:    $st" >> $E
    echo "last maps:    $maps (Polls: $n)" >> $E
    echo "--- Ende $name rc=$rc (137=SIGKILL, 139=SIGSEGV, 134=SIGABRT)" >> $E
    return $rc
}
# T: unter dem ptrace-Tracer (zeigt die letzten Systemaufrufe samt Pfad vor dem Tod) -> /data/local/tmp/sctrace.out
if [ -x /system/bin/sctrace ]; then
    probe T-sctrace /system/bin/sctrace /data/local/tmp/sctrace.out /system/bin/installd
fi
# A: unveraendert
probe A-normal /system/bin/installd
# B: oom_score_adj 0 (der Container erbt 1000 von android.sh; Kernel-LMK/OOM-Killer waehlt solche Prozesse zuerst)
( echo 0 > /proc/self/oom_score_adj; probe B-oom0 /system/bin/installd )
# C: ohne Preload und ohne Control-Socket: stirbt es hier auch, liegt es vor main() bzw. am Loader/Kernel, nicht an Socket/Verzeichnissen
( unset ANDROID_SOCKET_installd; LD_PRELOAD=; export LD_PRELOAD; probe C-nosocket /system/bin/installd )
echo "=== installd exit=$? $(date)" >> $E
INS
    chmod 0755 "$ROOTFS/system/bin/kobo-installd.sh"
    # KOBO_SCTRACE_V1: optionaler ptrace-Tracer (liegt neben android.sh als "sctrace"); Ausgabe -> $BASE/sctrace.out
    if [ -f "$BASE/sctrace" ]; then
        cp "$BASE/sctrace" "$ROOTFS/system/bin/sctrace" 2>/dev/null && chmod 0755 "$ROOTFS/system/bin/sctrace" || true
        : > "$ROOTFS/data/local/tmp/sctrace.out" 2>/dev/null; chmod 0666 "$ROOTFS/data/local/tmp/sctrace.out" 2>/dev/null || true
    fi
    grep -q 'kobo-installd.sh' "$rc" && return 0
    tmp="$RUN/init.rc.ilog"
    awk '$1 == "service" && $2 == "installd" { print "service installd /system/bin/sh /system/bin/kobo-installd.sh"; next } { print }' "$rc" > "$tmp" || { rm -f "$tmp"; return 0; }
    grep -q 'kobo-installd.sh' "$tmp" && cat "$tmp" > "$rc"
    rm -f "$tmp"
    echo "init.rc angepasst (KOBO_INSTALLD_LOG_V1)"
}
# KOBO_SIGTRACE_V1: installd wird sofort per SIGKILL beendet, ohne OOM-/Kernel-Meldung und unabhaengig von Preload/oom_score_adj.
# Der Kernel-Tracepoint signal_generate nennt Absender (comm/pid), Ziel und Ergebnis jedes SIGKILL -> $BASE/sigtrace.txt.
sigtrace_start() {
    TRACE_DIR=
    for d in /sys/kernel/tracing /sys/kernel/debug/tracing; do
        [ -d "$d/events/signal" ] && { TRACE_DIR=$d; break; }
    done
    if [ -z "$TRACE_DIR" ]; then
        mkdir -p /sys/kernel/debug 2>/dev/null || true
        mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
        [ -d /sys/kernel/debug/tracing/events/signal ] && TRACE_DIR=/sys/kernel/debug/tracing
    fi
    if [ -z "$TRACE_DIR" ]; then
        mount -t tracefs none /sys/kernel/tracing 2>/dev/null || true
        [ -d /sys/kernel/tracing/events/signal ] && TRACE_DIR=/sys/kernel/tracing
    fi
    [ -n "$TRACE_DIR" ] || { echo "sigtrace: kein Kernel-Tracing verfuegbar"; return 0; }
    echo 0 > "$TRACE_DIR/tracing_on" 2>/dev/null || true
    echo > "$TRACE_DIR/trace" 2>/dev/null || true
    echo 'sig == 9' > "$TRACE_DIR/events/signal/signal_generate/filter" 2>/dev/null || true
    echo 1 > "$TRACE_DIR/events/signal/signal_generate/enable" 2>/dev/null || true
    echo 1 > "$TRACE_DIR/tracing_on" 2>/dev/null || true
    echo "sigtrace: aktiv ($TRACE_DIR, signal_generate sig==9)"
}
sigtrace_dump() {
    [ -n "${TRACE_DIR:-}" ] || { echo "kein Kernel-Tracing verfuegbar (weder tracefs noch debugfs mit events/signal)" > "$BASE/sigtrace.txt"; return 0; }
    tail -n 120 "$TRACE_DIR/trace" > "$BASE/sigtrace.txt" 2>&1
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
# KOBO_URANDOM_V1: Ursache der installd-Abstuerze (sctrace.out): installd -> bionic arc4random oeffnet /dev/urandom mit
# O_NOFOLLOW (openat-Flags 0xa8000). /dev/urandom ist hier ein Symlink nach /hostdev/urandom -> open() liefert -40 (ELOOP)
# -> arc4random bricht per tgkill(self, SIGKILL) ab ("Killed", Exit 137, wenige ms nach dem Start).
# Fix: /dev/urandom und /dev/random als echte Dateien anlegen und das Host-Geraet per bind-Mount darueberlegen.
patch_init_urandom() {
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] || return 0
    grep -q 'KOBO_URANDOM_V1' "$rc" && return 0
    grep -Eq '^[[:space:]]*symlink /hostdev/(urandom|random) /dev/(urandom|random)' "$rc" || return 0
    tmp="$RUN/init.rc.urandom"
    awk '
        $1 == "symlink" && ($2 == "/hostdev/urandom" || $2 == "/hostdev/random") {
            dev = $2; sub("/hostdev/", "", dev)
            if (!shown) { print "    # KOBO_URANDOM_V1: echte Datei + bind-Mount statt Symlink (bionic oeffnet /dev/urandom mit O_NOFOLLOW)"; shown = 1 }
            print "    write /dev/" dev " 0"
            print "    mount none /hostdev/" dev " /dev/" dev " bind"
            next
        }
        { print }' "$rc" > "$tmp" || { rm -f "$tmp"; fail 'init.rc: urandom-Patch fehlgeschlagen.'; }
    grep -q 'KOBO_URANDOM_V1' "$tmp" || { rm -f "$tmp"; return 0; }
    cat "$tmp" > "$rc" && rm -f "$tmp"
    echo "init.rc angepasst (KOBO_URANDOM_V1: /dev/urandom per bind-Mount statt Symlink)"
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
    [ -f "$ROOTFS/kobo-chroot" ] && [ "$(cat "$ROOTFS/kobo-chroot")" = 'android-lollipop_api21' ] || { bad 2 "Lollipop/API-21-Rootfs fehlt (altes Image sichern, rootfs.img entfernen und neu installieren)"; return 1; }
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
    nap 3
    if kill -0 "$smpid" 2>/dev/null; then echo "servicemanager laeuft (PID $smpid)"; else echo "servicemanager ist sofort beendet:"; cat "$RUN/sm.out"; fi
    out=$("$ENVB" -i PATH=/system/bin "$CHROOT_BIN" "$ROOTFS" /system/bin/sh -c "$PRE; /system/bin/service list" 2>&1)
    echo "service list: $out"
    kill "$smpid" 2>/dev/null; nap 1; kill -KILL "$smpid" 2>/dev/null
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
# KOBO_NOGLES_V1: Es gibt kein OpenGL ES 2 (nur libGLES_android = GLES 1.x). libhwui in SystemUI/Launcher bricht sonst mit
# "F/OpenGLRenderer: Failed to choose config" per SIGABRT ab -> Neustartschleife. Im QEMU-Modus (ro.kernel.qemu=1) liest
# HardwareRenderer.isAvailable() die Property qemu.gles: 0 = keine Hardwarebeschleunigung, Apps zeichnen per Software.
# Wird in "on init" direkt hinter ro.kernel.qemu.gles eingefuegt; zusaetzlich als Sicherheitsnetz in build.prop.
fix_nogles() {
    [ "${KOBO_NOGLES:-1}" = 1 ] || return 0
    # Die init.rc-Zeilen (ro.kernel.qemu 1, qemu.gles 0) setzt fix_props_v1 (KOBO_NOGLES_V3) im Props-Block;
    # der fruehere awk-Anker "setprop ro.kernel.qemu.gles" existierte in der init.rc nie.
    set_prop_file "$ROOTFS/system/build.prop" qemu.gles 0
}
# KOBO_CRASHWATCH_V1: eigener Hintergrundprozess, unabhaengig von bootwatch (der haengt/stirbt beim healthd-Probelauf).
# Schreibt alle 3 s $BASE/android-full.log und $BASE/crash.txt und haelt in $BASE/deaths.txt fest, was ueber jede
# beendete system_server-Instanz im Log steht. Hintergrund: im Chroot laufen weder logd noch debuggerd, ein nativer
# Absturz hinterlaesst sonst keine Spur; Zygote meldet aber "Process N exited due to signal (X)" im Log.
crashwatch() {
    set +e
    logf="$ROOTFS/data/local/tmp/android.log"
    : > "$BASE/deaths.txt"; : > "$BASE/crash.txt"; : > "$BASE/android-full.log"
    last=''; deaths=0; propsdone=''
    while kill -0 "$container_pid" 2>/dev/null; do
        nap "${KOBO_CRASHWATCH_SEC:-20}"
        [ -f "$logf" ] || continue
        tail -n 4000 "$logf" > "$BASE/android-full.log" 2>/dev/null
        tail -n 8000 "$logf" 2>/dev/null | grep -E 'FATAL|AndroidRuntime|Process: |ANR in|has died|SIGSEGV|SIGABRT|Fatal signal|DEBUG|Zygote|system server|exited (due|cleanly)|WATCHDOG|Watchdog|WTF|Failure starting|BOOT FAILURE|Error starting|Exception' | tail -n 300 > "$BASE/crash.txt" 2>/dev/null
        if [ -z "$propsdone" ] && grep -q 'System now ready' "$logf" 2>/dev/null; then
            propsdone=1
            (
                nap 15
                {
                    echo "--- init.rc (qemu/gles):"; grep -n -E 'qemu|gles|NOGLES|disable_hw' "$ROOTFS/init.rc" 2>&1
                    echo "--- build.prop (qemu/gles):"; grep -E 'qemu|gles' "$ROOTFS/system/build.prop" 2>&1
                    echo "--- getprop (Laufzeitwerte):"
                    tmo 8 "$(command -v env)" -i PATH=/system/bin "$(command -v chroot)" "$ROOTFS" /system/bin/sh -c 'export LD_PRELOAD=/system/lib/libkobofb.so; exec /system/bin/getprop' 2>&1 | grep -E 'qemu|gles|low_ram|egl|hardware|opengl|sf\.'
                } > "$BASE/props.txt" 2>&1
            ) &
        fi
        cur=$(tail -n 3000 "$logf" 2>/dev/null | grep -o 'SystemServer([0-9]*)' | tail -n 1 | tr -dc '0-9')
        [ -n "$cur" ] || continue
        if [ -n "$last" ] && [ "$cur" != "$last" ]; then
            deaths=$((deaths + 1))
            {
                echo "=== $(date +%T) system_server $last beendet (neue Instanz $cur), Tod Nr. $deaths"
                echo "--- letzte Zeilen von $last:"
                grep "($last)" "$logf" 2>/dev/null | tail -n 40
                echo "--- Zygote/Signal/Fatal im Log:"
                grep -E 'Zygote|system server|exited (due|cleanly)|Fatal signal|FATAL|WATCHDOG|Watchdog|SIGSEGV|SIGABRT' "$logf" 2>/dev/null | tail -n 15
                echo "--- Kernel (dmesg):"
                dmesg 2>/dev/null | grep -E 'system_server|zygote|no vma|killed|oom|Out of memory|segfault|unhandled|[Ss]ignal' | tail -n 12
                tn=$(ls -t "$ROOTFS"/data/tombstones 2>/dev/null | head -n 1)
                [ -z "$tn" ] || { echo "--- Tombstone $tn:"; head -n 40 "$ROOTFS/data/tombstones/$tn" 2>/dev/null; }
                echo
            } >> "$BASE/deaths.txt" 2>&1
            # Datei klein halten (Schleife laeuft alle ~12 s)
            if [ "$(wc -l < "$BASE/deaths.txt" 2>/dev/null)" -gt 900 ]; then
                tail -n 600 "$BASE/deaths.txt" > "$RUN/deaths.trim" 2>/dev/null && cat "$RUN/deaths.trim" > "$BASE/deaths.txt"; rm -f "$RUN/deaths.trim"
            fi
        fi
        last=$cur
    done
}
# KOBO_DEBUGGERD_V1: Ohne debuggerd gibt es bei nativen Abstuerzen weder Tombstone noch "Fatal signal"-Zeile.
# Nur wenn /system/bin/debuggerd im Rootfs existiert; abschaltbar mit KOBO_DEBUGGERD=0.
fix_debuggerd() {
    [ "${KOBO_DEBUGGERD:-1}" = 1 ] || return 0
    rc="$ROOTFS/init.rc"
    [ -f "$rc" ] && [ -x "$ROOTFS/system/bin/debuggerd" ] || return 0
    mkdir -p "$ROOTFS/data/tombstones"; chmod 0771 "$ROOTFS/data/tombstones"; chown 1000:1000 "$ROOTFS/data/tombstones" 2>/dev/null || true
    grep -q '^service debuggerd ' "$rc" && return 0
    printf '\nservice debuggerd /system/bin/debuggerd\n    class main\n' >> "$rc"
    echo "init.rc angepasst (KOBO_DEBUGGERD_V1)"
}
# ---- Diagnose: Boot-Zeitachse (laeuft waehrend run im Hintergrund) -> bootwatch.log ---------------
bootwatch() {
    set +e
    ENVB=$(command -v env); CHROOTB=$(command -v chroot)
    w="$BASE/bootwatch.log"; : > "$w"; : > "$BASE/initstate.txt"; i=0
    gp() { tmo 3 chroot "$ROOTFS" /system/bin/getprop "$1" 2>/dev/null | tr -d '\r'; }
    {
        echo "libkobofb hat Log-Ersatz (neues Build): $(grep -c __android_log_write "$ROOTFS/system/lib/libkobofb.so" 2>&1)"
        echo "--- egl.cfg:"; cat "$ROOTFS/system/lib/egl/egl.cfg" 2>&1
        echo "--- ls -l system/lib/egl:"; ls -l "$ROOTFS/system/lib/egl" 2>&1
        echo "--- ls system/lib/hw:"; ls "$ROOTFS/system/lib/hw" 2>&1 | tr '\n' ' '; echo
        echo "--- libEGL/libGLES*:"; ls -l "$ROOTFS"/system/lib/libEGL.so "$ROOTFS"/system/lib/libGLES* 2>&1
        echo "--- Props:"; grep -E 'ro.hardware|egl|opengl|qemu' "$ROOTFS/system/build.prop" "$ROOTFS/default.prop" 2>&1
        echo "--- /proc/cmdline (androidboot.mode=charger?):"; cat /proc/cmdline 2>&1
    } > "$BASE/egl.txt" 2>&1
    while [ "$i" -lt 60 ] && kill -0 "$container_pid" 2>/dev/null; do
        nap 10; i=$((i + 1))
        # Ein ls statt je ein readlink-Prozess pro Host-PID (auf dem Kobo sind das hunderte fork/exec).
        n=$(ls -l /proc/[0-9]*/root 2>/dev/null | awk -v r="$ROOTFS" '$NF == r { c++ } END { print c + 0 }')
        echo "$(date +%T) t=${i}0s procs=$n boot=$(gp sys.boot_completed) sm=$(gp init.svc.servicemanager) sf=$(gp init.svc.surfaceflinger) zygote=$(gp init.svc.zygote) netd=$(gp init.svc.netd) healthd=$(gp init.svc.healthd) frei_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" >> "$w"
        init_snapshot
        # Absturzursache sichtbar machen: logcat (Fehler/Fatal) und neuester Tombstone
        tail -n 4000 "$ROOTFS/data/local/tmp/android.log" > "$BASE/android-full.log" 2>&1
        tail -n 150 "$ROOTFS/data/local/tmp/android.log" > "$BASE/logcat.txt" 2>&1
        tail -n 120 "$ROOTFS/data/local/tmp/zygote.err" > "$BASE/zygote.err" 2>/dev/null
        tail -n 80 "$ROOTFS/data/local/tmp/installd.err" > "$BASE/installd.err" 2>/dev/null; sigtrace_dump || true; tail -n 200 "$ROOTFS/data/local/tmp/sctrace.out" > "$BASE/sctrace.out" 2>/dev/null || true
        {
            echo "init.svc.healthd=$(gp init.svc.healthd)"
            echo "--- ps (Android-Prozesse):"
            ls -l /proc/[0-9]*/root 2>/dev/null | awk -v r="$ROOTFS" '$NF == r { split($(NF-2), a, "/"); print a[3] }' | while read -r apid; do echo "$apid $(cat "/proc/$apid/comm" 2>/dev/null)"; done
            echo "--- service check batteryproperties:"
            tmo 5 "$ENVB" -i PATH=/system/bin "$CHROOTB" "$ROOTFS" /system/bin/sh -c 'export LD_PRELOAD=/system/lib/libkobofb.so; exec /system/bin/service check batteryproperties' 2>&1
            echo "--- getprop (alle):"
            tmo 5 "$ENVB" -i PATH=/system/bin "$CHROOTB" "$ROOTFS" /system/bin/getprop 2>&1 | grep -E 'init.svc|ro.bootmode|ro.boot\.|sys.boot|kobo'
            echo "--- kobo-healthd.log:"; tail -n 40 "$ROOTFS/data/local/tmp/kobo-healthd.log" 2>&1
            echo "--- kobo-binder.log:"; tail -n 40 "$ROOTFS/data/local/tmp/kobo-binder.log" 2>&1
            echo "--- rootfs /dev/kmsg:"; tail -n 40 "$ROOTFS/dev/kmsg" 2>&1
            echo "--- healthd Datei:"; ls -l "$ROOTFS/sbin/healthd" 2>&1
            echo "--- ELF-Typ /sbin/healthd (Bytes 16-17: 02 00 = nicht PIE -> Lollipop-Linker lehnt ab, 03 00 = PIE):"
            dd if="$ROOTFS/sbin/healthd" bs=1 skip=16 count=2 2>/dev/null | od -An -tx1
            echo "--- healthd Probelauf (Linker-Meldung auf stderr):"
            tmo 2 "$ENVB" -i PATH=/system/bin ANDROID_ROOT=/system ANDROID_DATA=/data "$CHROOTB" "$ROOTFS" /system/bin/sh -c 'export LD_PRELOAD=/system/lib/libkobofb.so; /sbin/healthd; echo "Exit: $?"' 2>&1 | head -n 10
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
        nap 25
        {
            echo "--- Host /proc/bus/input/devices (kobo-vnc):"
            grep -A8 'kobo-vnc' /proc/bus/input/devices 2>&1
            echo "--- ls -l rootfs/dev/input:"; ls -l "$ROOTFS/dev/input" 2>&1
            echo "--- getevent -p (im Android-Chroot):"
            tmo 8 "$ENVB" -i PATH=/system/bin "$CHROOTB" "$ROOTFS" /system/bin/sh -c 'export LD_PRELOAD=/system/lib/libkobofb.so; exec /system/bin/getevent -p' 2>&1 | head -n 80
            echo "--- dumpsys input (Geraete, Display-Viewport):"
            tmo 10 "$ENVB" -i PATH=/system/bin "$CHROOTB" "$ROOTFS" /system/bin/sh -c 'export LD_PRELOAD=/system/lib/libkobofb.so; exec /system/bin/dumpsys input' 2>&1 | head -n 120
            echo "--- logcat Input*:"
            grep -E 'InputReader|InputDispatcher|EventHub|InputManager' "$ROOTFS/data/local/tmp/android.log" 2>&1 | tail -n 40
        } > "$BASE/input.txt" 2>&1
    fi
    # Nach dem Boot weiter mitschreiben: sonst enden android-full.log/logcat.txt beim Boot und
    # spaetere Abstuerze (App-Crash, Download, Datei anlegen) stehen nie in den Logs.
    diag_n=0; diag_iv=${KOBO_DIAG_INTERVAL:-15}
    logf="$ROOTFS/data/local/tmp/android.log"
    while kill -0 "$container_pid" 2>/dev/null; do
        nap "$diag_iv"; diag_n=$((diag_n + 1))
        # android.log wuchs bisher unbegrenzt (Android schreibt mit O_APPEND weiter): ab 4 MB kuerzen.
        sz=$(wc -c < "$logf" 2>/dev/null); sz=${sz:-0}
        if [ "$sz" -gt 4194304 ]; then
            tail -n 6000 "$logf" > "$RUN/log.trim" 2>/dev/null && cat "$RUN/log.trim" > "$logf"
            rm -f "$RUN/log.trim"
        fi
        tail -n 150 "$logf" > "$BASE/logcat.txt" 2>&1
        tail -n 80 "$ROOTFS/data/local/tmp/zygote.err" > "$BASE/zygote.err" 2>/dev/null
        tail -n 80 "$ROOTFS/data/local/tmp/installd.err" > "$BASE/installd.err" 2>/dev/null; sigtrace_dump || true; tail -n 200 "$ROOTFS/data/local/tmp/sctrace.out" > "$BASE/sctrace.out" 2>/dev/null || true
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
    if [ -n "${crash_pid:-}" ]; then kill "$crash_pid" 2>/dev/null || true; fi
    if [ -n "${ime_fix_pid:-}" ]; then kill "$ime_fix_pid" 2>/dev/null || true; fi
    if [ -n "${net_pid:-}" ]; then kill "$net_pid" 2>/dev/null || true; fi
    if [ -f "$BASE/android-init.log" ] || [ -n "${container_pid:-}" ]; then
        dmesg 2>/dev/null | grep -E 'init:|<init>|servicemanager|zygote|surfaceflinger|binder' | tail -n 200 >> "$BASE/android-init.log" 2>/dev/null || true
        # Kernel-seitige Ursachen, die der Filter oben nicht zeigt (OOM/LMK-Kills, Oops, Panic, Watchdog).
        {
            echo "--- Kernel-Ereignisse (OOM/LMK/Oops/Panic) $(date +%T):"
            dmesg 2>/dev/null | grep -iE 'lowmemorykiller|out of memory|killed process|kill process|oom-killer|panic|oops|BUG:|segfault|unhandled|watchdog|avc:' | tail -n 40
            echo "--- Ende Kernel-Ereignisse"
        } >> "$BASE/android-init.log" 2>/dev/null || true
    fi
    if [ -n "${vnc_pid:-}" ]; then
        kill -TERM "$vnc_pid" 2>/dev/null || true
        wait "$vnc_pid" 2>/dev/null || true
    fi
    mounted "$ROOTFS" && kill_rootfs_procs
    cpu_perf_off
    devkmsg_restore
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
# Keep the bootstrap components in an already-created rootfs current when a
# newer .adds/android directory is installed.  These files run before Android
# can update itself, so leaving them only in rootfs.img would force users to
# erase /data for a boot-loop fix.  Each source file is optional to retain
# compatibility with older installation packages.
refresh_rootfs_bootstrap() {
    if [ -f "$BASE/init.rc" ]; then
        cp "$BASE/init.rc" "$ROOTFS/init.rc" || fail 'init.rc konnte nicht aktualisiert werden.'
        chmod 0644 "$ROOTFS/init.rc" || fail 'Rechte für init.rc konnten nicht gesetzt werden.'
    fi
    if [ -f "$BASE/bin/kobo-healthd" ]; then
        cp "$BASE/bin/kobo-healthd" "$ROOTFS/sbin/healthd" || fail 'kobo-healthd konnte nicht aktualisiert werden.'
        chmod 0755 "$ROOTFS/sbin/healthd" || fail 'Rechte für kobo-healthd konnten nicht gesetzt werden.'
    fi
    if [ -f "$BASE/bin/kobo-vold" ]; then
        cp "$BASE/bin/kobo-vold" "$ROOTFS/system/bin/vold" || fail 'kobo-vold konnte nicht aktualisiert werden.'
        chmod 0755 "$ROOTFS/system/bin/vold" || fail 'Rechte für kobo-vold konnten nicht gesetzt werden.'
    fi
    gles_alias=''
    if [ -f "$BASE/bin/libGLES.so" ]; then
        gles_alias="$BASE/bin/libGLES.so"
    elif [ -f "$ROOTFS/system/lib/egl/libGLES_android.so" ]; then
        # Existing rootfs images already contain the software driver. Reuse it
        # so this boot fix can be installed without rebuilding the image.
        gles_alias="$ROOTFS/system/lib/egl/libGLES_android.so"
    fi
    if [ -n "$gles_alias" ]; then
        mkdir -p "$ROOTFS/system/lib/egl"
        cp "$gles_alias" "$ROOTFS/system/lib/egl/libGLES.so" || fail 'libGLES.so konnte nicht aktualisiert werden.'
        chmod 0644 "$ROOTFS/system/lib/egl/libGLES.so" || fail 'Rechte für libGLES.so konnten nicht gesetzt werden.'
    fi
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

# KOBO_WIFIBRIDGE_V1: Die Supplicant-Attrappe laeuft dauerhaft ab Boot, damit /dev/socket/wpa_$iface existiert,
# bevor system_server verbindet (sonst: "Unable to open connection to supplicant" -> WifiMonitor tot -> WLAN
# bleibt bei "wird aktiviert"). wpa_supplicant/p2p_supplicant sind nur noch Platzhalter fuer ctl.start/ctl.stop.
service kobo_wpa_bridge /system/bin/kobo-wpa-run --supplicant $iface
    class main

service wpa_supplicant /system/bin/kobo-wpa --idle
    class main
    disabled
    oneshot

service p2p_supplicant /system/bin/kobo-wpa --idle
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
    # Lollipop sucht den Supplicant-Socket in IFACE_DIR=/data/system/wpa_supplicant (existiert das Verzeichnis)
    # bzw. /dev/socket/<iface>, NICHT in data/misc/wifi/sockets. kobo-wpa lauscht auf allen Pfaden.
    # KOBO_WIFIPATH_V1: Zweiter Pfad. Mit KOBO_WIFI_PATHMODE=android (Standard) fehlt IFACE_DIR; Lollipop nimmt dann
    # "@android:wpa_<iface>" und verbindet per socket_local_client_connect auf /dev/socket/wpa_<iface>.
    # KOBO_WIFI_PATHMODE=iface stellt das alte Verhalten (IFACE_DIR/<iface>) wieder her.
    if [ "${KOBO_WIFI_PATHMODE:-android}" = iface ]; then
        mkdir -p "$ROOTFS/data/system/wpa_supplicant"
        chown 1010:1010 "$ROOTFS/data/system/wpa_supplicant" 2>/dev/null || true
        chmod 0771 "$ROOTFS/data/system/wpa_supplicant" 2>/dev/null || true
        printf '#!/system/bin/sh\nexec /system/bin/kobo-wpa "$@"\n' > "$ROOTFS/system/bin/kobo-wpa-run"
    else
        rm -rf "$ROOTFS/data/system/wpa_supplicant" 2>/dev/null || true
        printf '#!/system/bin/sh\nKOBO_WPA_ALT_DIR= exec /system/bin/kobo-wpa "$@"\n' > "$ROOTFS/system/bin/kobo-wpa-run"
    fi
    chmod 0755 "$ROOTFS/system/bin/kobo-wpa-run"
    chown 1010:1010 "$ROOTFS/data/misc/wifi" "$ROOTFS/data/misc/wifi/sockets" 2>/dev/null || true
    chmod 0770 "$ROOTFS/data/misc/wifi" "$ROOTFS/data/misc/wifi/sockets" 2>/dev/null || true
    chown 1014:1000 "$ROOTFS/data/misc/dhcp" 2>/dev/null || true
    chmod 0770 "$ROOTFS/data/misc/dhcp" 2>/dev/null || true
    # Aktuelle CA-Wurzeln: Lollipop kennt z. B. ISRG Root X1 nicht -> sonst scheitert fast jedes HTTPS.
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
agp() { tmo 3 chroot "$ROOTFS" /system/bin/getprop "$1" 2>/dev/null | tr -d '\r'; }
android_run() {
    bcp=$(sed -n 's/^ *export BOOTCLASSPATH *//p' "$ROOTFS/init.environ.rc" 2>/dev/null | head -n 1)
    "$ENVB" -i PATH=/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data ANDROID_ASSETS=/system/app \
        BOOTCLASSPATH="$bcp" EXTERNAL_STORAGE=/storage/sdcard LD_PRELOAD=/system/lib/libkobofb.so \
        KOBO_LOG_FILE=/data/local/tmp/android.log KOBO_BINDER_LOG=/data/local/tmp/kobo-binder.log \
        "$CHROOT_BIN" "$ROOTFS" "$@"
}
# KOBO_WIFIPERM_V1: Falls system_server die Gruppe wifi (1010) nicht wirksam hat, scheitert wpa_ctrl_open an
# Verzeichnis-/Socket-Rechten. Alles fuer alle zugaenglich machen (Chroot, kein Sicherheitsgewinn durch 0770).
net_open_perms() {
    for d in data/system/wpa_supplicant data/misc/wifi data/misc/wifi/sockets; do
        [ -d "$ROOTFS/$d" ] && chmod 0777 "$ROOTFS/$d" 2>/dev/null
    done
    for f in "$ROOTFS"/data/system/wpa_supplicant/* "$ROOTFS"/data/misc/wifi/sockets/* "$ROOTFS"/dev/socket/wlan0 "$ROOTFS"/dev/socket/wpa_*; do
        [ -S "$f" ] && chmod 0666 "$f" 2>/dev/null
    done
    return 0
}
netboot() {
    set +e
    : > "$BASE/net.log"
    iface=$1; i=0
    while [ "$i" -lt 150 ] && kill -0 "$container_pid" 2>/dev/null; do
        [ "$(agp sys.boot_completed)" = 1 ] && break
        net_write_env "$iface"; net_open_perms; nap 2; i=$((i + 1))
    done
    nap 10
    # Android-Einstellungen: WLAN an, Installation aus fremden Quellen erlauben (APK aus dem Browser).
    t=0
    while [ "$t" -lt 4 ] && kill -0 "$container_pid" 2>/dev/null; do
        net_open_perms
        echo "=== $(date +%T) svc wifi enable (Versuch $t)" >> "$BASE/net.log"
        android_run /system/bin/svc wifi enable >> "$BASE/net.log" 2>&1
        echo "rc=$?" >> "$BASE/net.log"
        grep -E 'F/|Abort message|Check failed|art/runtime|VM exiting|FATAL' "$ROOTFS/data/local/tmp/android.log" 2>/dev/null | tail -n 12 | cut -c1-240 >> "$BASE/net.log"
        net_open_perms
        nap 8
        [ "$(agp init.svc.wpa_supplicant)" = running ] && break
        t=$((t + 1))
    done
    echo "=== $(date +%T) settings put" >> "$BASE/net.log"
    android_run /system/bin/settings put secure install_non_market_apps 1 >> "$BASE/net.log" 2>&1
    echo "rc=$?" >> "$BASE/net.log"
        grep -E 'F/|Abort message|Check failed|art/runtime|VM exiting|FATAL' "$ROOTFS/data/local/tmp/android.log" 2>/dev/null | tail -n 12 | cut -c1-240 >> "$BASE/net.log"
    nap 25
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
        echo "--- system_server Rechte (KOBO_WIFIPERM_V1):"
        sp=$(agp sys.system_server_pid); [ -n "$sp" ] || sp=$(ps 2>/dev/null | awk '/system_server/ {print $1; exit}')
        grep -E '^(Uid|Gid|Groups|Cap[A-Za-z]*):' "/proc/$sp/status" 2>&1
        ls -ldn "$ROOTFS/data/misc/wifi" "$ROOTFS/data/misc/wifi/sockets" "$ROOTFS/data/system/wpa_supplicant" 2>&1
        echo "--- dalvik-cache/arm:"; ls -ln "$ROOTFS/data/dalvik-cache/arm" 2>&1 | head -n 20
        echo "--- Wrapper (norelocate):"; grep -l -- '-Xnorelocate' "$ROOTFS"/system/bin/* 2>/dev/null
        echo "--- svc/settings/pm/ime/input im Rootfs:"
        for t in svc settings pm ime input; do ls -l "$ROOTFS/system/bin/$t" 2>&1; head -n 4 "$ROOTFS/system/bin/$t" 2>&1 | cut -c1-160; done
        echo "--- system_server fd/limits:"
        ls "/proc/$sp/fd" 2>/dev/null | wc -l; grep -E 'open files|address space' "/proc/$sp/limits" 2>&1
        echo "--- dex2oat-wrap.log:"; tail -n 12 "$ROOTFS/data/local/tmp/dex2oat-wrap.log" 2>&1
        echo "--- Speicher:"; grep -E '^(MemTotal|MemAvailable|CommitLimit|Committed_AS):' /proc/meminfo; cat /proc/sys/vm/overcommit_memory 2>&1
        echo "--- strace system_server (wpa_ctrl_open), 25 s:"
        stb=""; for c in /system/xbin/strace /system/bin/strace; do [ -x "$ROOTFS$c" ] && stb=$c && break; done
        if [ -n "$stb" ] && [ -n "$sp" ]; then
            rm -f "$ROOTFS/data/local/tmp/strace-wifi.txt"
            android_run "$stb" -f -tt -s 96 -e trace=socket,bind,connect,chown,chmod,unlink,sendto -o /data/local/tmp/strace-wifi.txt -p "$sp" >/dev/null 2>&1 &
            st_pid=$!; nap 25; kill "$st_pid" 2>/dev/null; pkill -f "$stb -f" 2>/dev/null
            ls -l "$ROOTFS/data/local/tmp/strace-wifi.txt" 2>&1
            grep -E 'wpa|wlan|sockets|= -1' "$ROOTFS/data/local/tmp/strace-wifi.txt" 2>&1 | head -n 60
            echo "(erste Zeilen ungefiltert:)"; head -n 15 "$ROOTFS/data/local/tmp/strace-wifi.txt" 2>&1 | cut -c1-200
        else
            echo "kein strace im Rootfs oder system_server-PID unbekannt (stb=$stb sp=$sp)"
        fi
        echo "--- ps (kobo-wpa):"; ps 2>/dev/null | grep '[k]obo-wpa'
        echo "--- Android-Log (wifi/wpa/dhcp/netd), letzte 100 Zeilen:"
        grep -i 'wifi\|wpa\|supplicant\|dhcp\|WifiHW\|NetworkManagement' "$ROOTFS/data/local/tmp/android.log" 2>&1 | tail -n 100
        echo "--- kobo-wpa.log:"; tail -n 60 "$ROOTFS/data/local/tmp/kobo-wpa.log" 2>&1
        echo "--- kobo-net-guard.log:"; tail -n 20 "$ROOTFS/data/local/tmp/kobo-net-guard.log" 2>&1
    } > "$BASE/net.txt" 2>&1
    while kill -0 "$container_pid" 2>/dev/null; do net_write_env "$iface"; nap 5; done
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
    container_pid='' vnc_pid='' watchdog_pid='' watch_pid='' crash_pid='' ime_fix_pid='' net_pid='' NET_IFACE=''
    trap cleanup EXIT
    trap 'exit 0' INT TERM HUP
    echo $$ > "$RUN/runner.pid"
    check
    [ -f "$BASE/rootfs.img" ] || sh "$BASE/install.sh"
    mkdir -p "$ROOTFS" "$RUN/shared"
    mounted "$ROOTFS" && fail 'Rootfs ist bereits gemountet.'
    rootfs_mount
    [ -f "$ROOTFS/kobo-chroot" ] && [ "$(cat "$ROOTFS/kobo-chroot")" = 'android-lollipop_api21' ] || fail 'Falsches Rootfs: Lollipop/API-21-Image erforderlich. Altes rootfs.img sichern, entfernen und neu installieren.'
    refresh_rootfs_bootstrap
    install_bundled_apps
    CHROOT_BIN=$(command -v chroot) || fail 'chroot nicht gefunden.'
    ENV_BIN=$(command -v env) || fail 'env nicht gefunden.'
    ENVB="$ENV_BIN"
    start_ime_fix
    patch_init_rc
    patch_init_urandom
    patch_init_lateinit
    patch_init_preload
    patch_init_datadirs
    patch_init_storage_env
    patch_init_nopersist
    patch_init_loglevel
    patch_init_nice
    patch_init_lmkd
    patch_init_selinux
    apply_perf_tuning
    fix_zygote_netd
    fix_pm_settings
    fix_boot_v2
    fix_props_v1
    fix_nogles
    mkdir -p "$ROOTFS/data/local/tmp"
    fix_zygote_log
    fix_installd_log
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
    fix_debuggerd
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
    # Das Lollipop-SDK-Image (storage_list.xml, goldfish) kennt als Primaerspeicher /storage/sdcard = EXTERNAL_STORAGE.
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
        # Android oeffnet /sys/power/wake_lock lesend+schreibend (libcutils power.c, PowerManagerService): auf dem ro-Mount
        # scheitert das ("fatal error opening /sys/power/wake_lock" in zygote.err). Attrappen-Dateien darueber legen:
        # Android bekommt Erfolg, der Host-Kernel erhaelt nie echte Wakelocks.
        for wl in wake_lock wake_unlock; do
            if [ -e "/sys/power/$wl" ] && [ -e "$ROOTFS/sys/power/$wl" ]; then
                : > "$RUN/shared/fake_$wl"; chmod 0666 "$RUN/shared/fake_$wl"
                mount -o bind "$RUN/shared/fake_$wl" "$ROOTFS/sys/power/$wl" 2>/dev/null && echo "sys: /sys/power/$wl durch Attrappe ersetzt" || echo "Hinweis: /sys/power/$wl nicht ersetzbar."
            fi
        done
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
    devkmsg_unlimit
    "$BASE/bin/kobo-vnc" --shared "$RUN/shared" --input-dir "$ROOTFS/dev/input" --port 5963 &
    vnc_pid=$!
    echo "$vnc_pid" > "$RUN/vnc.pid"
    tries=0
    while [ ! -f "$RUN/shared/fb.meta" ] || [ ! -f "$RUN/shared/fb.bin" ] || ! ls "$ROOTFS/dev/input"/event* >/dev/null 2>&1; do
        kill -0 "$vnc_pid" 2>/dev/null || fail 'VNC-/Eingabebrücke beendet; siehe android.log.'
        tries=$((tries + 1)); [ "$tries" -le 15 ] || fail 'VNC-/uinput-Initialisierung dauert zu lange.'
        nap 1
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
    sigtrace_start || true
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
    # KOBO_DIAG=0 schaltet die Hintergrund-Diagnose ab (crashwatch fuellt sonst android-full.log/crash.txt und kostet CPU).
    if [ "${KOBO_DIAG:-1}" = 0 ]; then watch_pid=''; crash_pid=''
    else
        bootwatch & watch_pid=$!
        crashwatch & crash_pid=$!
    fi
    if [ -n "$NET_IFACE" ]; then netboot "$NET_IFACE" & net_pid=$!; fi
    touch "$RUN/ready"
    while kill -0 "$container_pid" 2>/dev/null && kill -0 "$vnc_pid" 2>/dev/null; do nap 1; done
    # Wer ist gestorben, und wie? (Exit-Status 128+N = Signal N: 137 = SIGKILL, 139 = SIGSEGV, 134 = SIGABRT)
    if ! kill -0 "$container_pid" 2>/dev/null; then
        c_rc=0; wait "$container_pid" 2>/dev/null || c_rc=$?
        echo "Android-init (PID $container_pid) beendet, Exit-Status $c_rc."
    fi
    kill -0 "$vnc_pid" 2>/dev/null || echo "kobo-vnc (PID $vnc_pid) beendet."
    echo 'Android oder die VNC-Brücke wurde beendet.'
}
# ---- Optional: Google-Apps (Core) in das Android-Image installieren -----------------------------
# Die ZIP (gapps-kern.zip) liegt NICHT im Repo; der Nutzer legt sie selbst auf den Kobo.
# Lollipop (API 21) scannt nur FLACHE APKs: /system/priv-app/Name.apk (Ordner pro App gibt es erst ab Android 5).
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
        [ ! -d "$ROOTFS/system/priv-app/Phonesky" ] || echo 'WARNUNG: alter Ordner priv-app/Phonesky vorhanden (Lollipop ignoriert Ordner). Neu installieren.'
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
    for f in android.log android-init.log bootwatch.log watchdog.log watchdog.last installd.err sigtrace.txt sctrace.out zygote.err stages.log logcat.txt tombstone.txt healthd.txt egl.txt crash.txt android-full.log deaths.txt props.txt; do
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
            nap 1; sync
            pid=$(cat "$RUN/runner.pid")
            kill -TERM "$pid"
            i=0
            while running; do i=$((i + 1)); [ "$i" -le 20 ] || fail 'Stopp hängt; keine erzwungenen Unmounts vorgenommen.'; nap 1; done
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
