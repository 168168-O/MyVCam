#
# MyVCam — rootless aggregate.
#
# Aggregate rootless package. Capture hooks live in the tweak subproject.
# myvcam-mirror is a root helper, not a filter. It copies test.mp4 under
# /var/jb and into Camera's container because Camera cannot read Documents.
# This Makefile does not install onto a device and does not target mediaserverd.
#

export THEOS_PACKAGE_SCHEME = rootless

# The aggregate has no sources. Without a deployment target, Theos defaults
# to iOS 9 and warns that this clang cannot build arm64e for that OS.
# Subprojects set their own ARCHS. The tweak is arm64 and arm64e.
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += MyVCamTweak
SUBPROJECTS += MyVCamMirror

include $(THEOS_MAKE_PATH)/aggregate.mk

# Sign after link, and again after stage copies the binaries into the deb root.
# tools/finalize_load.py retargets CydiaSubstrate.framework to libsubstrate.dylib
# and replaces the linker ".unsigned" signature with CS_ADHOC.
after-all::
	python3 tools/finalize_load.py

before-package::
	python3 tools/finalize_load.py
