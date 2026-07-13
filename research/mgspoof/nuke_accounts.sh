#!/bin/sh
# nuke_accounts.sh - wipe local Apple ID / IDS / iMessage account cache on device.
#
# Run ON THE DEVICE as root (rootful JB).
#
# BEFORE running (mandatory — file deletes do not clear keychain by themselves):
#   1) Settings -> Messages OFF
#   2) Settings -> Messages -> Send & Receive -> Sign Out (each Apple ID)
#   3) Settings -> FaceTime OFF if enabled
#   4) Settings -> [your name] -> Sign Out (repeat until "Sign in to your iPhone")
#
# AFTER running:
#   - Set a device passcode (avoids akd -7001 / SaveAccount Code=2 on re-login)
#   - Sign in one Apple ID fresh; enable iMessage if testing registration
#
# Does NOT reset Secure Enclave attestation (Apple's per-device Madrid bucket).
#
# NOTE: Settings may still SHOW the last Apple ID email as a sign-in *hint* after
# a successful nuke. That is keychain / SetupAssistant memory, not a logged-in
# account. Use --purge-hints to clear most of that. Only --purge-keychain removes
# all keychain material (Wi-Fi passwords, app creds, etc.).
#
# Usage:
#   sh nuke_accounts.sh                    # empty ZACCOUNT + caches
#   sh nuke_accounts.sh --destroy-db       # delete Accounts3.sqlite (+ backup)
#   sh nuke_accounts.sh --purge-hints      # also login-hint plists + apsd keychain
#   sh nuke_accounts.sh --check            # show where an email still appears
#   sh nuke_accounts.sh --destroy-db --purge-hints   # combine flags

set -e

DESTROY_DB=0
PURGE_HINTS=0
CHECK_ONLY=0
EMAIL=""

for arg in "$@"; do
  case "$arg" in
    --destroy-db) DESTROY_DB=1 ;;
    --purge-hints) PURGE_HINTS=1 ;;
    --purge-keychain)
      echo "[!] --purge-keychain: edit script and set PURGE_KEYCHAIN=1 after reading the warning."
      exit 1
      ;;
    --check) CHECK_ONLY=1 ;;
    --email=*) EMAIL="${arg#--email=}" ;;
    -h|--help)
      echo "Usage: sh nuke_accounts.sh [--destroy-db] [--purge-hints] [--check] [--email=user@icloud.com]"
      exit 0
      ;;
    *)
      echo "[!] unknown arg: $arg (try --help)"
      exit 1
      ;;
  esac
done

ACC_DIR=/var/mobile/Library/Accounts
ACC="$ACC_DIR/Accounts3.sqlite"
STAMP=$(date +%s)

scan_for_email() {
  needle="${1:-@}"
  echo "[*] scanning plists for: $needle"
  find /var/mobile/Library/Preferences /var/mobile/Library/Accounts \
    /var/mobile/Library/ConfigurationProfiles 2>/dev/null \
    | while read -r f; do
      case "$f" in
        *.plist|*.sqlite|*.sqlite-wal|*.sqlite-shm)
          if grep -aq "$needle" "$f" 2>/dev/null; then
            echo "    $f"
          fi
          ;;
      esac
    done
  if [ -f "$ACC" ]; then
    echo "[*] ZACCOUNT rows:"
    sqlite3 "$ACC" "SELECT Z_PK, ZUSERNAME, ZAUTHENTICATED FROM ZACCOUNT ORDER BY Z_PK;" 2>/dev/null || true
  else
    echo "[*] Accounts3.sqlite: absent"
  fi
  for kc in /var/Keychains/apsd.keychain /private/var/Keychains/apsd.keychain; do
    if [ -f "$kc" ]; then
      echo "[*] apsd keychain present: $kc"
    fi
  done
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  scan_for_email "${EMAIL:-hilmiazizi19}"
  exit 0
fi

echo "[!] Confirm you signed out of ALL Apple IDs in Settings first."
echo "[*] backing up Accounts3.sqlite -> Accounts3.sqlite.bak.$STAMP"
mkdir -p "$ACC_DIR"
if [ -f "$ACC" ]; then
  cp -a "$ACC" "$ACC_DIR/Accounts3.sqlite.bak.$STAMP"
  cp -a "$ACC_DIR/Accounts3.sqlite-shm" "$ACC_DIR/Accounts3.sqlite-shm.bak.$STAMP" 2>/dev/null || true
  cp -a "$ACC_DIR/Accounts3.sqlite-wal" "$ACC_DIR/Accounts3.sqlite-wal.bak.$STAMP" 2>/dev/null || true
fi

if [ "$DESTROY_DB" -eq 1 ]; then
  echo "[*] --destroy-db: removing Accounts3.sqlite (+ wal/shm)"
  rm -f "$ACC" "$ACC_DIR/Accounts3.sqlite-shm" "$ACC_DIR/Accounts3.sqlite-wal"
else
  echo "[*] clearing account rows from Accounts3.sqlite (keeping DB file)"
  if [ -f "$ACC" ]; then
    sqlite3 "$ACC" "DELETE FROM ZACCOUNT WHERE ZUSERNAME != 'local';" 2>/dev/null || true
    sqlite3 "$ACC" "DELETE FROM ZACCOUNT WHERE ZUSERNAME = 'local' AND ZAUTHENTICATED = 0;" 2>/dev/null || true
    sqlite3 "$ACC" "DELETE FROM ZACCOUNTPROPERTY;" 2>/dev/null || true
    sqlite3 "$ACC" "DELETE FROM ZACCOUNTCredential;" 2>/dev/null || true
    sqlite3 "$ACC" "VACUUM;"
    echo "[*] integrity_check: $(sqlite3 "$ACC" 'PRAGMA integrity_check;')"
  else
    echo "[!] no Accounts3.sqlite present (already gone or never created)"
  fi
fi

echo "[*] clearing IDS / iMessage / APNs caches..."
rm -rf /var/mobile/Library/Caches/com.apple.ids*              2>/dev/null || true
rm -rf /var/mobile/Library/com.apple.ids*                   2>/dev/null || true
rm -rf /var/mobile/Library/Preferences/com.apple.ids*       2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.imessage*       2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.imagent*        2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.apsd*           2>/dev/null || true

echo "[*] clearing Accounts / AuthKit / Store caches..."
rm -rf /var/mobile/Library/Caches/com.apple.akd*            2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.accounts*       2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.accountsd*     2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.AppleAccount*  2>/dev/null || true
rm -rf /var/mobile/Library/Caches/com.apple.storeservices*  2>/dev/null || true
rm -rf /var/mobile/Library/HTTPStorages/com.apple.akd*      2>/dev/null || true

echo "[*] clearing account / IDS / iMessage preferences..."
rm -f  /var/mobile/Library/Preferences/com.apple.account*.plist       2>/dev/null || true
rm -f  /var/mobile/Library/Preferences/com.apple.identityservices*.plist 2>/dev/null || true
rm -f  /var/mobile/Library/Preferences/com.apple.imessage*.plist      2>/dev/null || true
rm -f  /var/mobile/Library/Preferences/com.apple.apsd.plist             2>/dev/null || true
rm -f  /var/mobile/Library/Preferences/com.apple.facetime.plist         2>/dev/null || true
rm -f  /var/mobile/Library/Preferences/com.apple.appleaccount.plist     2>/dev/null || true
rm -f  /var/mobile/Library/Preferences/com.apple.akd.plist              2>/dev/null || true
rm -f  /var/mobile/Library/Preferences/com.apple.itunesstored.plist     2>/dev/null || true
rm -f  /var/mobile/Library/Preferences/com.apple.AppStore.plist         2>/dev/null || true

echo "[*] clearing IdentityServices / Messages data stores..."
rm -rf /var/mobile/Library/IdentityServices/*               2>/dev/null || true
rm -rf /var/mobile/Library/com.apple.messages*              2>/dev/null || true

echo "[*] clearing optional cloud config stubs (ignore errors if absent)..."
rm -f  /var/mobile/Library/ConfigurationProfiles/CloudConfigurationDetails.plist 2>/dev/null || true
rm -f  /var/mobile/Library/ConfigurationProfiles/ClientTruth.plist               2>/dev/null || true

if [ "$PURGE_HINTS" -eq 1 ]; then
  echo "[*] --purge-hints: login-hint plists + APNs keychain (forces new push token)"
  rm -f  /var/mobile/Library/Preferences/com.apple.purplebuddy.plist      2>/dev/null || true
  rm -f  /var/mobile/Library/Preferences/com.apple.SetupAssistant.plist   2>/dev/null || true
  rm -f  /var/mobile/Library/Preferences/com.apple.loginwindow.plist      2>/dev/null || true
  rm -f  /var/Keychains/apsd.keychain                                     2>/dev/null || true
  rm -f  /private/var/Keychains/apsd.keychain                             2>/dev/null || true
  rm -rf /var/mobile/Library/Caches/com.apple.AuthKit*                    2>/dev/null || true
fi

if [ ! -f /var/mobile/.mgspoof.plist ]; then
  echo "[i] no /var/mobile/.mgspoof.plist (real gestalt identity)"
else
  echo "[i] MGSpoof plist present — daemons will respawn with spoofed gestalt"
fi

echo "[*] restarting account / IDS / APNs daemons + respring..."
killall -9 accountsd akd identityservicesd imagent IMDPersistenceAgent apsd 2>/dev/null || true
killall -9 SpringBoard 2>/dev/null || sbreload 2>/dev/null || true

sleep 2

if [ -f "$ACC" ]; then
  echo "[*] remaining ZACCOUNT rows:"
  sqlite3 "$ACC" "SELECT Z_PK, ZUSERNAME, ZAUTHENTICATED FROM ZACCOUNT ORDER BY Z_PK;" 2>/dev/null || true
  AUTH=$(sqlite3 "$ACC" "SELECT COUNT(*) FROM ZACCOUNT WHERE ZAUTHENTICATED=1;" 2>/dev/null || echo "?")
  echo "[*] authenticated count: $AUTH"
else
  echo "[*] Accounts3.sqlite absent — accountsd recreates on next login attempt"
fi

echo "[+] done. backup: $ACC_DIR/Accounts3.sqlite.bak.$STAMP"
echo ""
echo "    If Settings still shows an email at 'Sign in to your iPhone':"
echo "      - That is often just a *hint*, not a logged-in account."
echo "      - Top of Settings should NOT show your name / iCloud storage."
echo "      - Re-run: sh nuke_accounts.sh --destroy-db --purge-hints"
echo "      - Diagnose: sh nuke_accounts.sh --check --email=hilmiazizi19"
echo ""
echo "    Set passcode before signing in. Restore DB if akd fails:"
echo "      cp $ACC_DIR/Accounts3.sqlite.bak.$STAMP $ACC"
