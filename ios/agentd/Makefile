TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

ifeq ($(THEOS),)
  ifneq ($(wildcard $(HOME)/theos/makefiles/common.mk),)
    THEOS := $(HOME)/theos
  else ifneq ($(wildcard /opt/theos/makefiles/common.mk),)
    THEOS := /opt/theos
  else ifneq ($(wildcard /var/theos/makefiles/common.mk),)
    THEOS := /var/theos
  else
    $(error THEOS is not set. Install Theos or run with THEOS=/path/to/theos)
  endif
endif

include $(THEOS)/makefiles/common.mk

INSTALL_TARGET_PROCESSES = SpringBoard MobileSafari Preferences MobileNotes MobileSMS MobileCal com.apple.WebKit.WebContent

TOOL_NAME = openphone-agentd openphone-protected-data-helper openphone-agentctl openphone-screencap-helper
TWEAK_NAME = OpenPhoneVolumeTrigger OpenPhoneAppIntrospector
BUNDLE_NAME = OpenPhoneAgentPrefs

openphone-agentd_FILES = src/main.m
openphone-agentd_CFLAGS = -fobjc-arc -Wall -Wextra
openphone-agentd_FRAMEWORKS = Foundation AVFoundation AudioToolbox Speech
openphone-agentd_LIBRARIES = compression sqlite3
openphone-agentd_INSTALL_PATH = /usr/local/bin
openphone-agentd_CODESIGN_FLAGS = -Sentitlements.plist

openphone-protected-data-helper_FILES = src/main.m
openphone-protected-data-helper_CFLAGS = -fobjc-arc -Wall -Wextra
openphone-protected-data-helper_FRAMEWORKS = Foundation AVFoundation AudioToolbox Speech
openphone-protected-data-helper_LIBRARIES = compression sqlite3
openphone-protected-data-helper_INSTALL_PATH = /usr/local/bin

openphone-agentctl_FILES = src/agentctl.m
openphone-agentctl_CFLAGS = -fobjc-arc -Wall -Wextra
openphone-agentctl_FRAMEWORKS = Foundation
openphone-agentctl_INSTALL_PATH = /usr/local/bin

openphone-screencap-helper_FILES = src/screencap_helper.m
openphone-screencap-helper_CFLAGS = -fobjc-arc -Wall -Wextra
openphone-screencap-helper_FRAMEWORKS = Foundation CoreGraphics ImageIO
openphone-screencap-helper_INSTALL_PATH = /usr/local/bin

OpenPhoneVolumeTrigger_FILES = src/volume_trigger.xm
OpenPhoneVolumeTrigger_CFLAGS = -fobjc-arc -Wall -Wextra
OpenPhoneVolumeTrigger_FRAMEWORKS = Foundation UIKit QuartzCore AudioToolbox
OpenPhoneVolumeTrigger_INSTALL_PATH = /usr/lib/TweakInject

OpenPhoneAppIntrospector_FILES = src/app_introspector.xm
OpenPhoneAppIntrospector_CFLAGS = -fobjc-arc -Wall -Wextra
OpenPhoneAppIntrospector_FRAMEWORKS = Foundation UIKit
OpenPhoneAppIntrospector_INSTALL_PATH = /usr/lib/TweakInject

OpenPhoneAgentPrefs_FILES = src/prefs/OpenPhoneAgentPrefsRootListController.m
OpenPhoneAgentPrefs_CFLAGS = -fobjc-arc -Wall -Wextra
OpenPhoneAgentPrefs_FRAMEWORKS = Foundation UIKit
OpenPhoneAgentPrefs_LDFLAGS = -undefined dynamic_lookup
OpenPhoneAgentPrefs_INSTALL_PATH = /Library/PreferenceBundles
OpenPhoneAgentPrefs_RESOURCE_DIRS = prefs/OpenPhoneAgentPrefsResources

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	chmod 4755 $(THEOS_STAGING_DIR)/usr/local/bin/openphone-protected-data-helper
	chmod 0755 $(THEOS_STAGING_DIR)/usr/local/bin/openphone-helper-wrapper.sh
