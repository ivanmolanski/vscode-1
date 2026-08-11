#!/usr/bin/env python3
import subprocess
import shutil
import tempfile
import plistlib
import os


def _parse_dmg_entities(plist_data):
    """Extract (mount_point, device) from an hdiutil attach plist.

    Returns (None, None) when the device-entry is missing, and
    (mount_point, None) when only the mount-point is missing, so callers
    can distinguish the two failure modes.
    """
    mount_point = None
    device = None
    for entity in plist_data.get("system-entities", []):
        mount_point = entity.get("mount-point")
        device = entity.get("dev-entry")
        if mount_point is not None:
            break
    return mount_point, device


def patch_dmg_icon(dmg_path, new_icon_path):
    """Replace the volume icon in an existing DMG."""

    temp_rw = tempfile.NamedTemporaryFile(suffix=".dmg", delete=False)
    temp_rw.close()

    try:
        # 1. Convert to read-write format
        subprocess.run([
            "hdiutil", "convert", dmg_path,
            "-format", "UDRW",  # Read-write
            "-o", temp_rw.name,
            "-ov"  # Overwrite
        ], check=True)

        # 2. Attach the writable DMG
        result = subprocess.run(
            ["hdiutil", "attach", "-nobrowse", "-plist", temp_rw.name],
            capture_output=True, check=True
        )
        plist = plistlib.loads(result.stdout)
        mount_point, device = _parse_dmg_entities(plist)

        if mount_point is None:
            raise RuntimeError("Failed to locate mount point for attached DMG")
        if device is None:
            raise RuntimeError("Failed to locate device entry for attached DMG")

        try:
            # 3. Copy custom icon
            icon_target = os.path.join(mount_point, ".VolumeIcon.icns")
            shutil.copyfile(new_icon_path, icon_target)

            # 4. Set the custom icon attribute on the volume
            subprocess.run(["/usr/bin/SetFile", "-a", "C", mount_point], check=True)

            # Sync before detach
            subprocess.run(["sync", "--file-system", mount_point], check=True)

        finally:
            # 5. Detach (device is guaranteed non-None here)
            subprocess.run(["hdiutil", "detach", device], check=True)

        # 6. Convert back to compressed format (ULMO = lzma)
        subprocess.run([
            "hdiutil", "convert", temp_rw.name,
            "-format", "ULMO",
            "-o", dmg_path,
            "-ov"
        ], check=True)

    finally:
        # Cleanup temp file in all paths; a missing file is fine.
        if os.path.exists(temp_rw.name):
            os.unlink(temp_rw.name)

    print(f"Successfully patched {dmg_path} with new icon")


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <dmg_path> <icon.icns>")
        sys.exit(1)

    patch_dmg_icon(sys.argv[1], sys.argv[2])
