#!/system/bin/sh
# KitKat can retain an old/empty IME selection in /data. Re-enable LatinIME
# after framework boot and select it explicitly.
IME='com.android.inputmethod.latin/.LatinIME'
i=0
while [ "$(getprop sys.boot_completed)" != '1' ] && [ "$i" -lt 90 ]; do
    sleep 1
    i=$((i + 1))
done
settings put secure enabled_input_methods "$IME"
settings put secure default_input_method "$IME"
# The Kobo uinput touchscreen can make KitKat believe a hardware input device
# is present. Explicitly allow the soft keyboard in that situation.
settings put secure show_ime_with_hard_keyboard 1
# ime is present on the KitKat framework; tolerate builds without the helper.
ime enable "$IME" >/dev/null 2>&1 || true
ime set "$IME" >/dev/null 2>&1 || true
settings get secure enabled_input_methods > /data/local/tmp/kobo-ime-state 2>&1 || true
settings get secure default_input_method >> /data/local/tmp/kobo-ime-state 2>&1 || true
settings get secure show_ime_with_hard_keyboard >> /data/local/tmp/kobo-ime-state 2>&1 || true
ime list -a >> /data/local/tmp/kobo-ime-state 2>&1 || true
