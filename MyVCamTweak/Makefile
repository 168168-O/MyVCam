#
# MyVCamTweak — single tweak target.
#
# Compiles the local-file reader, sample-buffer builder, injector, and the
# C1-C manager feed into one dylib. INSTALL_TARGET_PROCESSES is empty on
# purpose. The filter plist matches Camera, SpringBoard, and Preferences.
# SpringBoard and Preferences are load witnesses. Hooks stay in Camera.
#

# arm64 only. iPhone 12 is arm64e, and the Linux Theos clang emits an arm64e
# slice with an incompatible pointer-auth ABI (ld warns at link). dyld prefers
# that slice and Camera dies on the first authenticated call, before any feed
# runs. ElleKit on Dopamine loads an arm64 tweak into an arm64e process.
# Do not add arm64e back while Actions uses this toolchain.
ARCHS := arm64
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
