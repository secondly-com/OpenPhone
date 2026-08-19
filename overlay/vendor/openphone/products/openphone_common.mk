# Common OpenPhone product layer.

PRODUCT_BRAND := OpenPhone
PRODUCT_MANUFACTURER := OpenPhoneOS

PRODUCT_PACKAGES += \
    OpenPhoneAssistant

PRODUCT_PACKAGE_OVERLAYS += \
    vendor/openphone/overlay

# Feed OpenPhone's boot animation into Lineage's existing bootanimation.zip
# module, which owns /product/media/bootanimation.zip and the dark symlink.
$(call soong_config_set,lineage_bootanimation,prebuilt_file,vendor/openphone/media/bootanimation.zip)

PRODUCT_COPY_FILES += \
    vendor/openphone/config/privapp-permissions-openphone.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/privapp-permissions-openphone.xml \
    vendor/openphone/config/sysconfig-openphone.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/sysconfig/sysconfig-openphone.xml \
    vendor/openphone/config/openphone_app_policy.json:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/openphone/app_policy.json \
    vendor/openphone/config/openphone_action_registry.json:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/openphone/action_registry.json \
    vendor/openphone/config/openphone_capabilities.json:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/openphone/capabilities.json \
    vendor/openphone/config/openphone_model_tools.json:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/openphone/model_tools.json \
    vendor/openphone/config/openphone_policy.json:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/openphone/policy.json

PRODUCT_SYSTEM_EXT_PROPERTIES += \
    ro.openphone.version=0.1.0-dev \
    ro.openphone.systemui_island=true \
    ro.openphone.source_available=true \
    ro.openphone.commercial_license_required=true
