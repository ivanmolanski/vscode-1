#!/usr/bin/env python3
"""Unit tests for build/darwin/patch-dmg.py entity parsing."""
import importlib.util
import os
import unittest

# Make the module under test importable regardless of cwd. The module is
# named patch-dmg.py (hyphen) so it cannot be imported via a normal import
# statement; load it by path instead.
_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("patch_dmg", os.path.join(_HERE, "patch-dmg.py"))
assert _spec is not None and _spec.loader is not None, "could not load patch-dmg.py"
patch_dmg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(patch_dmg)
_parse_dmg_entities = patch_dmg._parse_dmg_entities


class ParseDmgEntitiesTest(unittest.TestCase):
    def test_missing_mount_point_returns_none(self):
        plist = {
            "system-entities": [
                {"dev-entry": "/dev/disk4", "mount-point": None},
            ]
        }
        mount_point, device = _parse_dmg_entities(plist)
        self.assertIsNone(mount_point)
        # Device may still be reported; the caller raises for the missing
        # mount-point first.
        self.assertEqual(device, "/dev/disk4")

    def test_missing_dev_entry_returns_none_device(self):
        plist = {
            "system-entities": [
                {"mount-point": "/Volumes/My App"},
            ]
        }
        mount_point, device = _parse_dmg_entities(plist)
        self.assertEqual(mount_point, "/Volumes/My App")
        self.assertIsNone(device)

    def test_both_present(self):
        plist = {
            "system-entities": [
                {"dev-entry": "/dev/disk3", "mount-point": "/Volumes/My App"},
            ]
        }
        mount_point, device = _parse_dmg_entities(plist)
        self.assertEqual(mount_point, "/Volumes/My App")
        self.assertEqual(device, "/dev/disk3")

    def test_empty_entities(self):
        mount_point, device = _parse_dmg_entities({"system-entities": []})
        self.assertIsNone(mount_point)
        self.assertIsNone(device)

    def test_missing_system_entities_key(self):
        mount_point, device = _parse_dmg_entities({})
        self.assertIsNone(mount_point)
        self.assertIsNone(device)


if __name__ == "__main__":
    unittest.main()
