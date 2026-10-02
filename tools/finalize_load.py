#!/usr/bin/env python3
"""Retarget substrate, ad-hoc sign, and require an iOS 15 arm64e slice.

ElleKit dlopens a tweak from TweakInject into the host process and ignores
dlopen errors. iPhone 12 is arm64e. dyld does not map an arm64 dylib into
an arm64e process, so an arm64-only image never reaches a constructor.
0.2.17 was that image: ad-hoc, arm64, iOS 15.0, LC_UUID, and the ElleKit
rpaths were already in place, and the constructors still never ran.

The slice dyld will map is arm64e with the versioned pointer-auth ABI
(cpusubtype 0x80000002, pacibsp/retab). That is the iOS 14+ ABI iOS 15
uses. The September 2023 Linux clang emitted an arm64e slice that crashed
on the first authenticated call; this script refuses an arm64e slice that
lacks the version bit so that ABI cannot be packaged.

ldid -Cadhoc replaces the linker's ".unsigned" signature (flags 0). The
load command is @rpath/libsubstrate.dylib, which ElleKit ships at
/var/jb/usr/lib/libsubstrate.dylib.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import struct
import subprocess
import sys
from pathlib import Path

FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_ID_DYLIB = 0xD
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
CPU_SUBTYPE_PTRAUTH_ABI = 0x80000000
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CS_ADHOC = 0x2
PLATFORM_IOS = 2

OLD_SUBSTRATE = b"@rpath/CydiaSubstrate.framework/CydiaSubstrate"
NEW_SUBSTRATE = b"@rpath/libsubstrate.dylib"

ROOT = Path(__file__).resolve().parents[1]
SCAN_DIRS = (
    ROOT / ".theos",
    ROOT / "MyVCamTweak" / ".theos",
    ROOT / "MyVCamMirror" / ".theos",
)


class Slice:
    def __init__(self, offset: int, size: int, cputype: int, cpusubtype: int) -> None:
        self.offset = offset
        self.size = size
        self.cputype = cputype
        self.cpusubtype = cpusubtype


def _cstring(buf: bytes | bytearray, start: int, end: int) -> bytes:
    stop = buf.find(b"\x00", start, end)
    if stop < 0:
        stop = end
    return bytes(buf[start:stop])


def slices_of(buf: bytes | bytearray) -> list[Slice]:
    if len(buf) < 8:
        raise SystemExit("file is too small to be a Mach-O")
    magic_be = struct.unpack_from(">I", buf, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_CIGAM):
        count = struct.unpack_from(">I", buf, 4)[0]
        if count < 1 or count > 8:
            raise SystemExit(f"unexpected fat arch count {count}")
        found = []
        for index in range(count):
            cputype, cpusubtype, offset, size, _align = struct.unpack_from(
                ">IIIII", buf, 8 + index * 20
            )
            if offset + size > len(buf):
                raise SystemExit("fat slice extends past end of file")
            found.append(Slice(offset, size, cputype, cpusubtype))
        return found
    magic = struct.unpack_from("<I", buf, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a Mach-O or fat file (magic {magic:#x})")
    cputype, cpusubtype = struct.unpack_from("<II", buf, 4)
    return [Slice(0, len(buf), cputype, cpusubtype)]


def _walk_commands(buf: bytes | bytearray, sl: Slice):
    if sl.size < 32:
        raise SystemExit("Mach-O slice is too small")
    if struct.unpack_from("<I", buf, sl.offset)[0] != MH_MAGIC_64:
        raise SystemExit("expected a thin little-endian arm64 Mach-O slice")
    cputype, cpusubtype, _filetype, ncmds, _sizeofcmds, _flags, _reserved = struct.unpack_from(
        "<IIIIIII", buf, sl.offset + 4
    )
    if cputype != CPU_TYPE_ARM64:
        raise SystemExit(f"expected arm64, cputype={cputype:#x}")
    if cpusubtype != sl.cpusubtype:
        raise SystemExit(
            f"slice subtype {sl.cpusubtype:#x} does not match mach header {cpusubtype:#x}"
        )
    off = sl.offset + 32
    end = sl.offset + sl.size
    for _ in range(ncmds):
        if off + 8 > end:
            raise SystemExit("truncated load commands")
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmdsize < 8 or off + cmdsize > end:
            raise SystemExit("invalid load command size")
        yield off, cmd, cmdsize
        off += cmdsize


def _dylib_path(buf: bytes | bytearray, off: int, cmdsize: int) -> bytes:
    name_off = struct.unpack_from("<I", buf, off + 8)[0]
    if name_off >= cmdsize:
        raise SystemExit("dylib name offset outside command")
    return _cstring(buf, off + name_off, off + cmdsize)


def _arch_kind(sl: Slice) -> str:
    low = sl.cpusubtype & 0xFF
    if sl.cputype != CPU_TYPE_ARM64:
        raise SystemExit(f"cputype {sl.cputype:#x} is not arm64")
    if low == 0:
        if sl.cpusubtype & CPU_SUBTYPE_PTRAUTH_ABI:
            raise SystemExit(f"arm64 slice has ptrauth bit set ({sl.cpusubtype:#x})")
        return "arm64"
    if low == CPU_SUBTYPE_ARM64E:
        if sl.cpusubtype & CPU_SUBTYPE_PTRAUTH_ABI == 0:
            raise SystemExit(
                f"arm64e slice cpusubtype {sl.cpusubtype:#x} lacks the versioned "
                "ptrauth ABI bit 0x80000000. That is the pre-iOS 14 ABI. "
                "dyld on iOS 15 would load it and crash on the first authenticated call"
            )
        return "arm64e"
    raise SystemExit(f"unexpected arm64 subtype {sl.cpusubtype:#x}")


def retarget_substrate(data: bytearray) -> bool:
    """Point every MyVCamTweak slice at libsubstrate.dylib. Idempotent."""
    changed = False
    for sl in slices_of(data):
        found_new = False
        for off, cmd, cmdsize in _walk_commands(data, sl):
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
                raise SystemExit("substrate path field is too small")
            data[start : start + len(NEW_SUBSTRATE)] = NEW_SUBSTRATE
            for index in range(start + len(NEW_SUBSTRATE), end):
                data[index] = 0
            changed = True
            found_new = True
        if not found_new:
            raise SystemExit(
                f"slice at {sl.offset:#x} is missing {OLD_SUBSTRATE.decode()} "
                f"and {NEW_SUBSTRATE.decode()}"
            )
    return changed


def _decode_version(value: int) -> tuple[int, int, int]:
    return ((value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF)


def _code_directory(buf: bytes, sl: Slice) -> dict:
    sigoff = None
    sigsize = 0
    for off, cmd, cmdsize in _walk_commands(buf, sl):
        if cmd == LC_CODE_SIGNATURE:
            dataoff, sigsize = struct.unpack_from("<II", buf, off + 8)
            sigoff = sl.offset + dataoff
            break
    if sigoff is None:
        raise SystemExit("missing LC_CODE_SIGNATURE")
    blob_end = sigoff + sigsize
    if blob_end > sl.offset + sl.size:
        raise SystemExit("code signature extends outside its slice")
    blob = buf[sigoff:blob_end]
    if len(blob) < 12:
        raise SystemExit("truncated code signature")
    magic, _length, count = struct.unpack_from(">III", blob, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise SystemExit(f"unexpected signature magic {magic:#x}")
    cd_rel = None
    for index in range(count):
        typ, offset = struct.unpack_from(">II", blob, 12 + index * 8)
        if typ == 0:
            cd_rel = offset
            break
    if cd_rel is None:
        raise SystemExit("signature has no CodeDirectory")
    cd_abs = sigoff + cd_rel
    cd_magic = struct.unpack_from(">I", buf, cd_abs)[0]
    if cd_magic != CSMAGIC_CODEDIRECTORY:
        raise SystemExit(f"CodeDirectory magic {cd_magic:#x}")
    version, flags, hash_off, ident_off, n_special, n_code, code_limit = struct.unpack_from(
        ">IIIIIII", buf, cd_abs + 8
    )
    hash_size, hash_type, platform, page_shift = struct.unpack_from(">BBBB", buf, cd_abs + 36)
    ident = _cstring(buf, cd_abs + ident_off, blob_end)
    return {
        "version": version,
        "flags": flags,
        "hash_off": hash_off,
        "n_special": n_special,
        "n_code": n_code,
        "code_limit": code_limit,
        "hash_size": hash_size,
        "hash_type": hash_type,
        "cd_platform": platform,
        "page_shift": page_shift,
        "ident": ident,
        "cd_abs": cd_abs,
    }


def _hashes_match(buf: bytes, sl: Slice, cd: dict, slot0: int) -> bool:
    if cd["hash_type"] != 2 or cd["hash_size"] != 32:
        raise SystemExit(
            f"expected SHA-256 code hashes, type={cd['hash_type']} size={cd['hash_size']}"
        )
    page_size = 1 << cd["page_shift"]
    if page_size not in (4096, 16384):
        raise SystemExit(f"code directory page shift {cd['page_shift']} is not 12 or 14")
    for slot in range(cd["n_code"]):
        start = sl.offset + slot * page_size
        end = sl.offset + min((slot + 1) * page_size, cd["code_limit"])
        if end < start or end > len(buf):
            return False
        digest = hashlib.sha256(buf[start:end]).digest()
        stored = buf[slot0 + slot * 32 : slot0 + (slot + 1) * 32]
        if digest != stored:
            return False
    return True


def _verify_hashes(buf: bytes, sl: Slice, cd: dict) -> None:
    # ldid's hashOffset addresses code slot 0. Apple's layout addresses the
    # first special slot, which is nSpecial slots earlier. Accept either.
    slot0_ldid = cd["cd_abs"] + cd["hash_off"]
    slot0_apple = slot0_ldid + cd["n_special"] * cd["hash_size"]
    if _hashes_match(buf, sl, cd, slot0_ldid) or _hashes_match(buf, sl, cd, slot0_apple):
        return
    raise SystemExit(
        f"code signature hashes do not match the slice at {sl.offset:#x} "
        f"(page shift {cd['page_shift']})"
    )


def verify_binary(path: Path, require_arm64e: bool) -> None:
    buf = path.read_bytes()
    slices = slices_of(buf)
    kinds = []
    described = []
    for sl in slices_of(buf):
        kind = _arch_kind(sl)
        kinds.append(kind)
        has_uuid = False
        platform = None
        minos = None
        loads = []
        for off, cmd, cmdsize in _walk_commands(buf, sl):
            if cmd == LC_UUID:
                has_uuid = True
            elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_ID_DYLIB):
                loads.append(_dylib_path(buf, off, cmdsize))
            elif cmd == LC_BUILD_VERSION and cmdsize >= 24:
                platform, minos_raw, _sdk, _ntools = struct.unpack_from("<IIII", buf, off + 8)
                minos = _decode_version(minos_raw)
        if not has_uuid:
            raise SystemExit(f"{path}: {kind} slice is missing LC_UUID")
        if platform != PLATFORM_IOS:
            raise SystemExit(f"{path}: {kind} LC_BUILD_VERSION platform {platform} is not iOS")
        if minos is None or minos > (15, 3, 1):
            raise SystemExit(
                f"{path}: {kind} min OS {minos} is newer than the iOS 15.3.1 device. "
                "dyld rejects that image before constructors"
            )
        cd = _code_directory(buf, sl)
        ident = cd["ident"]
        ident_text = ident.decode("utf-8", "replace")
        if b".unsigned" in ident or ident_text.endswith(".unsigned"):
            raise SystemExit(f"{path}: signature identity is still a linker placeholder: {ident_text}")
        if cd["flags"] & CS_ADHOC == 0:
            raise SystemExit(f"{path}: signature flags {cd['flags']:#x} are not CS_ADHOC")
        _verify_hashes(buf, sl, cd)
        if path.name == "MyVCamTweak.dylib":
            if ident_text != "com.myvcam.tweak":
                raise SystemExit(f"{path}: identity {ident_text} is not com.myvcam.tweak")
            if NEW_SUBSTRATE not in loads:
                raise SystemExit(f"{path}: does not load {NEW_SUBSTRATE.decode()}")
            for item in loads:
                if b"CydiaSubstrate.framework" in item:
                    raise SystemExit(f"{path}: still loads {item.decode()}")
        elif path.name == "myvcam-mirror":
            if ident_text != "com.myvcam.mirror":
                raise SystemExit(f"{path}: identity {ident_text} is not com.myvcam.mirror")
        described.append(
            f"{kind}:{sl.cpusubtype:#x}:min={minos[0]}.{minos[1]}.{minos[2]}:"
            f"pagesz={1 << cd['page_shift']}:flags={cd['flags']:#x}"
        )
    if path.name == "myvcam-mirror" and kinds != ["arm64"]:
        raise SystemExit(f"{path}: myvcam-mirror must stay thin arm64, found {kinds}")
    if require_arm64e:
        if "arm64e" not in kinds:
            raise SystemExit(
                f"{path}: no arm64e slice. dyld will not map arm64 into an arm64e process, "
                "so constructors never run"
            )
        if "arm64" not in kinds:
            raise SystemExit(f"{path}: missing the arm64 slice")
    print(f"verified {path.name}: ident slices {', '.join(described)}")


def _ldid() -> str:
    found = shutil.which("ldid")
    if not found:
        raise SystemExit("ldid is not on PATH; ad-hoc sign cannot run")
    return found


def sign_binary(path: Path) -> None:
    if path.name == "MyVCamTweak.dylib":
        ident = "com.myvcam.tweak"
        data = bytearray(path.read_bytes())
        retarget_substrate(data)
        path.write_bytes(data)
    elif path.name == "myvcam-mirror":
        ident = "com.myvcam.mirror"
    else:
        raise SystemExit(f"refusing to sign unexpected binary {path}")
    cmd = [_ldid(), f"-I{ident}", "-Cadhoc", "-S", str(path)]
    subprocess.run(cmd, check=True)
    verify_binary(path, require_arm64e=False)


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
        help="check signature, ABI, and substrate load command without modifying files",
    )
    parser.add_argument(
        "--require-arm64e",
        action="store_true",
        help="require an arm64 slice and a versioned arm64e slice (the injected tweak)",
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
            verify_binary(path, require_arm64e=args.require_arm64e)
        else:
            if args.require_arm64e:
                raise SystemExit("--require-arm64e is only valid with --verify")
            sign_binary(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
