#!/bin/sh
# reset_cycle.sh - clear iMessage/IDS/APNs state so the NEXT activation registers
# a brand-new device identity (the one in /var/mobile/.mgspoof.plist).
#
# Run ON THE DEVICE (rootful JB) between rotation cycles.
#
# IMPORTANT ordering for the test:
#   1) Settings -> Messages OFF, then sign OUT of the Apple ID (clears IDS identity
#      + push token from the keychain; file deletion alone cannot do this).
#   2) Drop the new fingerprint:  scp mgspoof.plist -> /var/mobile/.mgspoof.plist
#   3) Run this script (clears caches + restarts daemons under the new identity).
#   4) Sign the Apple ID back in, turn iMessage ON -> this is the registration we test.

set -e

echo "[*] clearing IDS / iMessage / APNs caches..."
rm -rf /var/mobile/Library/Caches/com.apple.ids*           2>/dev/null || true
rm -rf /var/mobile/Library/com.apple.ids*                  2>/dev/null || true
rm -rf /var/mobile/Library/Preferences/com.apple.ids*      2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.imessage*      2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.imagent*       2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.apsd*          2>/dev/null || true

if [ ! -f /var/mobile/.mgspoof.plist ]; then
  echo "[!] WARNING: /var/mobile/.mgspoof.plist missing - daemons will use the REAL identity."
fi

echo "[*] restarting daemons (they will read the new fingerprint on respawn)..."
killall -9 identityservicesd imagent IMDPersistenceAgent apsd akd 2>/dev/null || true

echo "[+] done. Now sign the Apple ID back in and enable iMessage to register."
echo "    Verify the spoof took:  gestalt SerialNumber UniqueDeviceID InternationalMobileEquipmentIdentity"
