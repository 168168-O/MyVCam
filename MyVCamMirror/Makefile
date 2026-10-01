#
# myvcam-mirror — root helper, not injected.
#
# com.apple.camera cannot read /var/mobile/Documents. This tool is started
# by launchd as root (--watch), outside Camera's sandbox. It copies test.mp4
# under /var/jb and into Camera's data container, mode 0644, and writes
# mirror.status (euid, mode, errno) so the tweak can log that it ran.
#
# arm64 only. A fat arm64e slice from this Linux toolchain is the wrong
# pointer-auth ABI. An arm64 executable still runs on arm64e iOS.
#

ARCHS := arm64
TARGET := iphone:clang:latest:15.0

export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = myvcam-mirror

myvcam-mirror_FILES = main.c
myvcam-mirror_CFLAGS = -Wall -Wextra -Wno-unused-parameter
myvcam-mirror_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
