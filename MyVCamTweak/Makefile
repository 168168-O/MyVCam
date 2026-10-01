#
# MyVCamTweak — single tweak target.
#
# Compiles the local-file reader, sample-buffer builder, injector, and the
# C1-C manager feed into one dylib. INSTALL_TARGET_PROCESSES is empty on
# purpose. The filter plist matches com.apple.camera only.
#

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

MyVCamTweak_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo

include $(THEOS_MAKE_PATH)/tweak.mk
