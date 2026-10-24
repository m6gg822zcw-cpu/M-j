#!/usr/bin/env python3
"""Validate device IPA structure, not cryptographic signing trust."""
import argparse
import plistlib
import struct
import zipfile
from pathlib import PurePosixPath


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_macho(data):
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        is64 = data[:4] == b"\xca\xfe\xba\xbf"
        require(len(data) >= 8, "Truncated universal Mach-O header")
        count = struct.unpack_from(">I", data, 4)[0]
        size = 32 if is64 else 20
        require(0 < count <= 32 and len(data) >= 8 + count * size, "Invalid Mach-O slices")
        for index in range(count):
            start = 8 + index * size
            cpu = struct.unpack_from(">I", data, start)[0]
            require(cpu == 0x0100000C, "IPA contains a non-arm64 executable slice")
            offset, length = struct.unpack_from(">QQ" if is64 else ">II", data, start + 8)
            require(length > 0 and offset + length <= len(data), "Invalid Mach-O slice bounds")
            require(data[offset:offset + 4] == b"\xcf\xfa\xed\xfe", "Invalid arm64 slice")
            check_macho(data[offset:offset + length])
        return
    require(len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe", "Executable is not an arm64 Mach-O")
    cpu, _, file_type, count, command_bytes = struct.unpack_from("<IIIII", data, 4)
    require(cpu == 0x0100000C and file_type == 2, "Expected an arm64 MH_EXECUTE binary")
    require(0 < count <= 65535 and 32 + command_bytes <= len(data), "Invalid Mach-O commands")
    position = 32
    device = False
    for _ in range(count):
        require(position + 8 <= 32 + command_bytes, "Truncated Mach-O command")
        command, size = struct.unpack_from("<II", data, position)
        require(size >= 8 and position + size <= 32 + command_bytes, "Invalid Mach-O command size")
        if command == 0x32:  # LC_BUILD_VERSION: iOS=2, iOSSimulator=7
            require(size >= 24, "Truncated platform command")
            require(struct.unpack_from("<I", data, position + 8)[0] == 2,
                    "Executable targets a simulator or another platform")
            device = True
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS, older device toolchains
            require(size >= 16, "Truncated minimum iOS version")
            device = True
        position += size
    require(position == 32 + command_bytes and device, "Missing iOS device platform metadata")


def validate(path, expect):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP members")
        require(all(not n.startswith("/") and ".." not in PurePosixPath(n).parts for n in names),
                "Unsafe ZIP path")
        plists = [n for n in names if len(PurePosixPath(n).parts) == 3
                  and n.startswith("Payload/") and n.endswith(".app/Info.plist")]
        require(len(plists) == 1, "Expected exactly one Payload/*.app/Info.plist")
        root = plists[0].removesuffix("Info.plist")
        info = plistlib.loads(archive.read(plists[0]))
        executable = info.get("CFBundleExecutable", "")
        require(executable and PurePosixPath(executable).name == executable and executable not in (".", ".."),
                "Invalid CFBundleExecutable")
        require(info.get("CFBundlePackageType") == "APPL", "Payload is not an iOS application")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "App was not built for iPhoneOS")
        require(bool(info.get("CFBundleIdentifier")), "Missing bundle identifier")
        check_macho(archive.read(root + executable))
        signature = root + "_CodeSignature/CodeResources" in names
        profile = root + "embedded.mobileprovision" in names
        if expect == "signed":
            require(signature and profile, "Missing code signature or provisioning profile")
        elif expect == "unsigned":
            require(not signature and not profile, "Unsigned IPA contains a signature or provisioning profile")
        require(archive.testzip() is None, "ZIP checksum verification failed")
        return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--expect", choices=("signed", "unsigned"), required=True)
    args = parser.parse_args()
    try:
        info = validate(args.ipa, args.expect)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f"IPA validation failed: {error}\n")
    print(f"IPA structure OK: {info['CFBundleIdentifier']} ({args.expect}, iOS arm64)")
    print("Signature trust requires macOS codesign and device installation testing."
          if args.expect == "signed" else "UNSIGNED: requires signing before installation.")


if __name__ == "__main__":
    main()
