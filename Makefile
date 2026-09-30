#
# MyVCam — rootless aggregate.
#
# Stage 2.2 adds a local-file reader and sample-buffer builder.
# This Makefile does not enable injection, mediaserverd, or any capture hook.
#

export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += MyVCamTweak

include $(THEOS_MAKE_PATH)/aggregate.mk
