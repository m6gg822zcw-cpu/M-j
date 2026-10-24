"""Synthetic structural fixtures only; these are not compiled or installable apps."""
import importlib.util
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("validate_ipa", Path(__file__).parents[1] / "validate_ipa.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def macho(platform=2, cpu=0x0100000C):
    return struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0) + struct.pack(
        "<IIIIII", 0x32, 24, platform, 0x110000, 0x120000, 0)


class IPAValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "fixture.ipa"

    def fixture(self, binary=None, platforms=None, signed=False):
        info = {"CFBundleExecutable": "Moxu", "CFBundlePackageType": "APPL",
                "CFBundleIdentifier": "test.fixture.moxu",
                "CFBundleSupportedPlatforms": platforms or ["iPhoneOS"]}
        with zipfile.ZipFile(self.path, "w") as archive:
            archive.writestr("Payload/Moxu.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/Moxu.app/Moxu", macho() if binary is None else binary)
            if signed:
                archive.writestr("Payload/Moxu.app/_CodeSignature/CodeResources", b"fixture")
                archive.writestr("Payload/Moxu.app/embedded.mobileprovision", b"fixture")

    def test_accept_device_structure(self):
        self.fixture()
        self.assertEqual(validator.validate(self.path, "unsigned")["CFBundleIdentifier"], "test.fixture.moxu")

    def test_reject_source_zip(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            archive.writestr("App/MoxuApp.swift", "import SwiftUI")
        with self.assertRaisesRegex(ValueError, "Payload"):
            validator.validate(self.path, "unsigned")

    def test_reject_simulator_plist(self):
        self.fixture(platforms=["iPhoneSimulator"])
        with self.assertRaisesRegex(ValueError, "iPhoneOS"):
            validator.validate(self.path, "unsigned")

    def test_reject_arm64_simulator_binary_even_with_device_plist(self):
        self.fixture(binary=macho(platform=7))
        with self.assertRaisesRegex(ValueError, "simulator"):
            validator.validate(self.path, "unsigned")

    def test_reject_non_arm64_and_empty_binary(self):
        for binary in (macho(cpu=0x01000007), b"", b"source code"):
            with self.subTest(binary=binary):
                self.fixture(binary=binary)
                with self.assertRaises(ValueError):
                    validator.validate(self.path, "unsigned")

    def test_signing_mode_cannot_be_mislabeled(self):
        self.fixture()
        with self.assertRaisesRegex(ValueError, "signature"):
            validator.validate(self.path, "signed")
        self.fixture(signed=True)
        validator.validate(self.path, "signed")  # Presence only, not cryptographic trust.
        with self.assertRaisesRegex(ValueError, "Unsigned"):
            validator.validate(self.path, "unsigned")

    def test_reject_wrong_platform_in_universal_binary(self):
        device, simulator = macho(), macho(platform=7)
        header = struct.pack(">II", 0xCAFEBABE, 2)
        first = struct.pack(">IIIII", 0x0100000C, 0, 48, len(device), 0)
        second = struct.pack(">IIIII", 0x0100000C, 2, 48 + len(device), len(simulator), 0)
        self.fixture(binary=header + first + second + device + simulator)
        with self.assertRaisesRegex(ValueError, "simulator"):
            validator.validate(self.path, "unsigned")

    def test_reject_truncated_load_commands(self):
        self.fixture(binary=macho()[:-1])
        with self.assertRaisesRegex(ValueError, "commands"):
            validator.validate(self.path, "unsigned")


if __name__ == "__main__":
    unittest.main()
