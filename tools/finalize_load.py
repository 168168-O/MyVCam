#!/usr/bin/env python3
"""Rewrite MyVCamTweak's substrate dependency and ad-hoc sign loadable binaries.

The Linux Theos link step leaves a linker placeholder signature. Its
CodeDirectory identity ends in ".unsigned" and the flags word is 0, not
CS_ADHOC. ElleKit dlopens tweaks from TweakInject. dyld on this Dopamine
setup rejects that placeholder before any constructor runs, so
runtime.status stays untouched.

ElleKit ships /var/jb/usr/lib/libsubstrate.dylib (libellekit). The dylib
already has that directory on its rpath. The vendor tbd instead records
@rpath/CydiaSubstrate.framework/CydiaSubstrate, which is only a
compatibility symlink. Point the load command at libsubstrate.dylib, then
sign with ldid -Cadhoc so the identity is not ".unsigned".
"""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_ID_DYLIB = 0xD
LC_RPATH = 0x8000001C
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
CPU_TYPE_ARM64 = 0x0100000C
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CS_ADHOC = 0x2

OLD_SUBSTRATE = b"@rpath/CydiaSubstrate.framework/CydiaSubstrate"
NEW_SUBSTRATE = b"@rpath/libsubstrate.dylib"

ROOT = Path(__file__).resolve().parents[1]
SCAN_DIRS = (
    ROOT / ".theos",
    ROOT / "MyVCamTweak" / ".theos",
    ROOT / "MyVCamMirror" / ".theos",
)


def _cstring(buf: bytes, start: int, end: int) -> bytes:
    stop = buf.find(b"\x00", start, end)
    if stop < 0:
        stop = end
    return buf[start:stop]


def _walk_commands(buf: bytes):
    if len(buf) < 32 or struct.unpack_from("<I", buf, 0)[0] != MH_MAGIC_64:
        raise SystemExit("expected a thin little-endian arm64 Mach-O")
    cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<IIIIIII", buf, 4
    )
    if cputype != CPU_TYPE_ARM64:
        raise SystemExit(f"expected arm64, cputype={cputype:#x}")
    if cpusubtype & 0xFF == 2 or cpusubtype & 0x80000000:
        raise SystemExit(f"arm64e slice is not allowed, cpusubtype={cpusubtype:#x}")
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(buf):
            raise SystemExit("truncated load commands")
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmdsize < 8 or off + cmdsize > len(buf):
            raise SystemExit("invalid load command size")
        yield off, cmd, cmdsize
        off += cmdsize


def _dylib_path(buf: bytes, off: int, cmdsize: int) -> bytes:
    name_off = struct.unpack_from("<I", buf, off + 8)[0]
    if name_off >= cmdsize:
        raise SystemExit("dylib name offset outside command")
    return _cstring(buf, off + name_off, off + cmdsize)


def retarget_substrate(path: Path) -> bool:
    """Point MyVCamTweak at libsubstrate.dylib. Idempotent. Returns True if changed."""
    data = bytearray(path.read_bytes())
    changed = False
    found_new = False
    for off, cmd, cmdsize in _walk_commands(data):
        if cmd not in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            continue
        current = _dylib_path(data, off, cmdsize)
        if current == NEW_SUBSTRATE:
            found_new = True
            continue
        if current != OLD_SUBSTRATE:
            continue
        name_off = struct.unpack_from("<I", data, off + 8)[0]
        start = off + name_off
        end = off + cmdsize
        if end - start <= len(NEW_SUBSTRATE):
            raise SystemExit(f"{path}: substrate path field is too small")
        data[start : start + len(NEW_SUBSTRATE)] = NEW_SUBSTRATE
        for index in range(start + len(NEW_SUBSTRATE), end):
            data[index] = 0
        changed = True
        found_new = True
    if not found_new:
        raise SystemExit(f"{path}: missing {OLD_SUBSTRATE.decode()} and {NEW_SUBSTRATE.decode()}")
    if changed:
        path.write_bytes(data)
    return changed


def _code_directory(buf: bytes):
    sigoff = None
    for off, cmd, cmdsize in _walk_commands(buf):
        if cmd == LC_CODE_SIGNATURE:
            sigoff, sigsize = struct.unpack_from("<II", buf, off + 8)
            break
    if sigoff is None:
        raise SystemExit("missing LC_CODE_SIGNATURE")
    blob = buf[sigoff : sigoff + sigsize]
    if len(blob) < 12:
        raise SystemExit("truncated code signature")
    magic, length, count = struct.unpack_from(">III", blob, 0)
    if magic != 0xFADE0CC0:
        raise SystemExit(f"unexpected signature magic {magic:#x}")
    for index in range(count):
        typ, offset = struct.unpack_from(">II", blob, 12 + index * 8)
        if offset + 8 > len(blob):
            continue
        cd_magic = struct.unpack_from(">I", blob, offset)[0]
        if cd_magic != CSMAGIC_CODEDIRECTORY:
            continue
        version, flags, _hash_off, ident_off = struct.unpack_from(">IIII", blob, offset + 8)
        ident = _cstring(blob, offset + ident_off, len(blob))
        return version, flags, ident
    raise SystemExit("signature has no CodeDirectory")


def verify_binary(path: Path) -> None:
    buf = path.read_bytes()
    version, flags, ident = _code_directory(buf)
    ident_text = ident.decode("utf-8", "replace")
    if b".unsigned" in ident or ident_text.endswith(".unsigned"):
        raise SystemExit(f"{path}: signature identity is still a linker placeholder: {ident_text}")
    if flags & CS_ADHOC == 0:
        raise SystemExit(f"{path}: signature flags {flags:#x} are not CS_ADHOC")
    loads = []
    platform = None
    for off, cmd, cmdsize in _walk_commands(buf):
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_ID_DYLIB):
            loads.append(_dylib_path(buf, off, cmdsize))
        elif cmd == LC_BUILD_VERSION and cmdsize >= 24:
            platform = struct.unpack_from("<I", buf, off + 8)[0]
    if platform not in (None, 2):
        raise SystemExit(f"{path}: LC_BUILD_VERSION platform {platform} is not iOS")
    if path.name == "MyVCamTweak.dylib":
        if NEW_SUBSTRATE not in loads:
            raise SystemExit(f"{path}: does not load {NEW_SUBSTRATE.decode()}")
        for item in loads:
            if b"CydiaSubstrate.framework" in item:
                raise SystemExit(f"{path}: still loads {item.decode()}")
    print(
        f"verified {path.name}: ident={ident_text} flags={flags:#x} cd_version={version:#x}"
    )


def _ldid() -> str:
    found = shutil.which("ldid")
    if not found:
        raise SystemExit("ldid is not on PATH; ad-hoc sign cannot run")
    return found


def sign_binary(path: Path) -> None:
    if path.name == "MyVCamTweak.dylib":
        ident = "com.myvcam.tweak"
        retarget_substrate(path)
    elif path.name == "myvcam-mirror":
        ident = "com.myvcam.mirror"
    else:
        raise SystemExit(f"refusing to sign unexpected binary {path}")
    cmd = [_ldid(), f"-I{ident}", "-Cadhoc", "-S", str(path)]
    subprocess.run(cmd, check=True)
    verify_binary(path)


def _is_dsym_companion(path: Path) -> bool:
    """dsymutil writes a DWARF file named like the dylib. It is not linked."""
    return any(part.endswith(".dSYM") for part in path.parts)


def _binaries_under(root: Path) -> list[Path]:
    found = []
    if not root.is_dir():
        return found
    for path in root.rglob("*"):
        if not path.is_file() or path.name not in ("MyVCamTweak.dylib", "myvcam-mirror"):
            continue
        if _is_dsym_companion(path):
            continue
        found.append(path)
    return found


def collect_build_binaries() -> list[Path]:
    found: list[Path] = []
    for directory in SCAN_DIRS:
        found.extend(_binaries_under(directory))
    # Stable order, obj copies before staging copies is not required.
    unique = []
    seen = set()
    for path in found:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        unique.append(path)
    if not unique:
        raise SystemExit("no MyVCamTweak.dylib or myvcam-mirror under .theos")
    return unique


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify",
        action="store_true",
        help="check signature and substrate load command without modifying files",
    )
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args()
    paths = args.paths or collect_build_binaries()
    if not paths:
        raise SystemExit("no binaries given")
    for path in paths:
        if not path.is_file():
            raise SystemExit(f"missing binary {path}")
        if _is_dsym_companion(path):
            print(f"skip dSYM companion {path}")
            continue
        if args.verify:
            verify_binary(path)
        else:
            sign_binary(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
