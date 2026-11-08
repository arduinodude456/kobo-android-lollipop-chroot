LOCAL_PATH := device/kobo/libra_colour
# core_base retains framework/service boot jars needed by SystemServer. Unlike
# full_base it does not add the full consumer, wallpaper and demo app set.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_base.mk)

# Inherited packages are merged by the product machinery, not immediately.
# Their unwanted entries are filtered by the hash-checked source patch instead
# of pretending that a local filter-out can remove inherited product tokens.
PRODUCT_PACKAGES += \
    Settings SystemUI Launcher2 LatinIME \
    PackageInstaller SettingsProvider DownloadProvider MediaProvider \
    servicemanager surfaceflinger installd \
    mediaserver audio.primary.default audio_policy.default \
    gralloc.default libGLES_android libkobofb kobo-vnc kobo-container
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/init.rc:root/init.rc \
    $(LOCAL_PATH)/egl.cfg:system/lib/egl/egl.cfg \
    $(LOCAL_PATH)/kobo.idc:system/usr/idc/Kobo_Android_Touch.idc \
    $(LOCAL_PATH)/prebuilt/AmazeFileManager-3.8.apk:system/app/AmazeFileManager.apk \
    $(LOCAL_PATH)/prebuilt/Editor-1.71.apk:system/app/Editor.apk
DEVICE_PACKAGE_OVERLAYS := $(LOCAL_PATH)/overlay
PRODUCT_AAPT_CONFIG := normal mdpi
PRODUCT_AAPT_PREF_CONFIG := mdpi
PRODUCT_CHARACTERISTICS := tablet,nosdcard
PRODUCT_LOCALES := en_US
PRODUCT_PROPERTY_OVERRIDES += \
    ro.config.low_ram=true \
    ro.sf.lcd_density=160 \
    ro.hardware=kobo_libra_colour \
    ro.opengles.version=65536 \
    debug.sf.hw=0 \
    debug.egl.hw=0 \
    debug.hwui.render_dirty_regions=false \
    dalvik.vm.heapsize=96m \
    dalvik.vm.heapstartsize=8m \
    dalvik.vm.heapgrowthlimit=48m \
    dalvik.vm.heaptargetutilization=0.75 \
    dalvik.vm.heapminfree=512k \
    dalvik.vm.heapmaxfree=2m \
    dalvik.vm.execution-mode=int:jit \
    persist.sys.dalvik.vm.lib=libdvm.so \
    ro.kernel.android.checkjni=0 \
    ro.kernel.qemu=1 \
    ro.kernel.qemu.gles=0 \
    ro.hardware.egl=android \
    ro.radio.noril=yes \
    ro.telephony.default_network=0 \
    ro.setupwizard.mode=DISABLED \
    ro.carrier=unknown \
    ro.build.selinux=0 \
    config.disable_bluetooth=true \
    config.disable_location=true \
    config.disable_telephony=true \
    config.disable_network=true \
    config.disable_noncore=true \
    config.disable_systemui=false \
    config.disable_media=false \
    config.disable_storage=true \
    persist.sys.usb.config=none \
    debug.sf.nobootanimation=0
PRODUCT_NAME := kobo_libra_colour
PRODUCT_DEVICE := libra_colour
PRODUCT_BRAND := KoboChroot
PRODUCT_MODEL := Libra Colour Android Chroot
PRODUCT_MANUFACTURER := community
