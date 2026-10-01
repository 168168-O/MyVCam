#
# MyVCam — rootless aggregate.
#
# Aggregate rootless package. Capture hooks live in the tweak subproject.
# This Makefile does not install onto a device and does not target mediaserverd.
#

export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += MyVCamTweak

include $(THEOS_MAKE_PATH)/aggregate.mk
