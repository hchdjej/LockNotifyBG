export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:16.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LockNotifyBGPrefs

LockNotifyBGPrefs_FILES = NGBPrefsRootListController.m
LockNotifyBGPrefs_INSTALL_PATH = /Library/PreferenceBundles
LockNotifyBGPrefs_FRAMEWORKS = UIKit AVFoundation MobileCoreServices UniformTypeIdentifiers
LockNotifyBGPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
LockNotifyBGPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

# 设置入口 plist 通过 layout 目录自动合并，无需手动拷贝
