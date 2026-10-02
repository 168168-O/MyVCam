#
# MyVCam — rootless aggregate.
#
# Aggregate rootless package. Capture hooks live in the tweak subproject.
# myvcam-mirror is a root helper, not a filter. It copies test.mp4 under
# /var/jb and into Camera's container because Camera cannot read Documents.
# This Makefile does not install onto a device and does not target mediaserverd.
#

export THEOS_PACKAGE_SCHEME = rootless

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
