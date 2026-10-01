export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:16.0
export SDKVERSION = 16.5

# Dopamine / palera1n rootless 越狱必须开启 rootless 打包方案
# 如果你的多巴胺版本使用 roothide，请改成 roothide
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LockNotifyBG
LockNotifyBG_FILES = Tweak.xm
LockNotifyBG_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-arc-performSelector-leaks
LockNotifyBG_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia QuartzCore
LockNotifyBG_PRIVATE_FRAMEWORKS = BulletinBoard

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
