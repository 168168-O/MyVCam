#
# MyVCamTweak — single tweak target.
#
# Compiles the local-file reader, sample-buffer builder, injector, and the
# C1-C manager feed into one dylib. INSTALL_TARGET_PROCESSES is empty on
# purpose. The filter plist matches Camera, SpringBoard, and Preferences.
# SpringBoard and Preferences are load witnesses. Hooks stay in Camera.
#

# iPhone 12 is arm64e. dyld does not map an arm64 dylib into an arm64e
# process, so an arm64-only tweak never runs a constructor. ElleKit dlopens
# this file and ignores the architecture error. arm64e must be the versioned
# pointer-auth ABI (cpusubtype 0x80000002). The 2023 Linux clang emitted an
# ABI that crashed on the first authenticated call; Actions pins the current
# Theos clang, and tools/finalize_load.py refuses a slice without that bit.
ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:15.0

export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyVCamTweak

SRC := ../Sources

MyVCamTweak_FILES = Tweak.x \
	$(SRC)/Core/MyVCamFrame.m \
	$(SRC)/Core/MyVCamManager.m \
	$(SRC)/Media/MediaReader.m \
	$(SRC)/Buffer/SampleBufferBuilder.m \
	$(SRC)/Inject/VideoInjector.m

MyVCamTweak_CFLAGS = -fobjc-arc \
	-I$(SRC)/Core \
	-I$(SRC)/Media \
	-I$(SRC)/Buffer \
	-I$(SRC)/Inject

MyVCamTweak_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo Accelerate QuartzCore UIKit IOSurface

# The aggregate before-package step re-signs after the substrate path edit.
# -I keeps the identity off the ".unsigned" intermediate filename.
MyVCamTweak_CODESIGN_FLAGS = -Icom.myvcam.tweak -Cadhoc -S

include $(THEOS_MAKE_PATH)/tweak.mk
