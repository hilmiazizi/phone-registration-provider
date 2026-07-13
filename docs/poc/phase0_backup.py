#!/usr/bin/env python3
"""Phase 0 - reversible backup + state snapshot for the identity-rotation PoC.

Captures the file-based device state we CAN restore, plus a manifest of the
current identity/account/daemon state. Note: on iOS the IDS identity keys and
ADI/anisette provisioning live in the SEP-wrapped keychain and are NOT portable
files - the authoritative "restore working account" path is re-login (see
RESTORE.md). This script backs up everything that is file-restorable.
"""
import base64
import datetime
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from _ssh import run  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

# Device paths that are file-restorable. Keychain items are intentionally NOT
# here (not portable on iOS); they are handled via re-login in RESTORE.md.
BACKUP_PATHS = [
    "/Library/MobileSubstrate/DynamicLibraries/MGSpoof.plist",
    "/Library/MobileSubstrate/DynamicLibraries/MGSpoof.plist.bak",
    "/Library/MobileSubstrate/DynamicLibraries/MGSpoof.dylib",
    "/var/mobile/Library/IdentityServices",
    "/var/mobile/Library/Application Support/com.apple.akd",
    "/var/mobile/Library/Caches/com.apple.akd",
    "/var/root/Library/Lockdown/data_ark.plist",
]


def sh(cmd, sudo=True):
    rc, out, err = run(cmd, sudo=sudo, timeout=180)
    return rc, out, err


def main():
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dst = os.path.join(HERE, f"backup_{ts}")
    os.makedirs(dst, exist_ok=True)
    print(f"[*] backup dir: {dst}")

    # 1. tar the file-restorable state on device, pull via base64.
    paths = " ".join(f"'{p}'" for p in BACKUP_PATHS)
    # device has no gzip -> use uncompressed tar (state is small)
    sh("rm -f /tmp/poc_backup.tar")
    rc, out, err = sh(
        f"tar cf /tmp/poc_backup.tar {paths} 2>/dev/null; "
        "base64 /tmp/poc_backup.tar"
    )
    b64 = "".join(l for l in out.splitlines() if l and " " not in l)
    try:
        blob = base64.b64decode(b64)
        with open(os.path.join(dst, "device_state.tar"), "wb") as f:
            f.write(blob)
        print(f"[+] pulled device_state.tar ({len(blob)} bytes)")
    except Exception as e:
        print(f"[!] tar pull failed: {e}\n{out[:300]}")

    # 2. state manifest (identity + account + daemons).
    rc, manifest, _ = sh(
        'echo "## kernel uname"; uname -a; '
        'echo "## SPOOFED gestalt"; gestalt SerialNumber UniqueDeviceID UniqueChipID WifiAddress BluetoothAddress 2>/dev/null; '
        'echo "## REAL ioreg (kernel, unhookable)"; ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | grep -iE "IOPlatformSerialNumber|IOPlatformUUID"; '
        'echo "## MGSpoof filter"; cat /Library/MobileSubstrate/DynamicLibraries/MGSpoof.plist; '
        'echo "## daemons"; ps aux 2>/dev/null | grep -iE "identityservicesd|imagent|akd|apsd" | grep -v grep; '
        'echo "## IdentityServices listing"; ls -la /var/mobile/Library/IdentityServices; '
        'echo "## region"; cat /var/root/Library/Lockdown/data_ark.plist 2>/dev/null | strings | grep -iE "Language|Locale|TimeZone|DeviceName"'
    )
    with open(os.path.join(dst, "manifest.txt"), "w") as f:
        f.write(manifest)
    print("[+] wrote manifest.txt")
    print("\n--- MANIFEST ---\n" + manifest)

    # 3. pointer to latest
    with open(os.path.join(HERE, "LATEST_BACKUP.txt"), "w") as f:
        f.write(dst + "\n")
    print(f"\n[*] LATEST_BACKUP -> {dst}")


if __name__ == "__main__":
    main()
