#!/bin/sh
set -eu
ACC=/var/mobile/Library/Accounts
BAK=$ACC/VerifiedBackup

echo "=== backup account rows ==="
python3 - <<'PY'
import sqlite3
c = sqlite3.connect("/var/mobile/Library/Accounts/VerifiedBackup/Accounts3.sqlite")
cols = [x[1] for x in c.execute("PRAGMA table_info(ZACCOUNT)")]
print("cols", cols)
for cand in ("ZUSERNAME", "ZACCOUNTDESCRIPTION", "ZIDENTIFIER"):
    if cand in cols:
        print(cand, c.execute(f"SELECT Z_PK, {cand} FROM ZACCOUNT").fetchall()[:30])
PY

echo "=== restoring VerifiedBackup Accounts3 ==="
killall -9 accountsd akd identityservicesd imagent apsd amsaccountsd mobileactivationd beepservd 2>/dev/null || true
sleep 1
cp -a "$ACC/Accounts3.sqlite" "$ACC/Accounts3.sqlite.emptynuke" 2>/dev/null || true
cp -a "$BAK/Accounts3.sqlite" "$ACC/Accounts3.sqlite"
rm -f "$ACC/Accounts3.sqlite-wal" "$ACC/Accounts3.sqlite-shm"
chown mobile:mobile "$ACC/Accounts3.sqlite"
chmod 644 "$ACC/Accounts3.sqlite"

rm -f /var/mobile/beepserv.log /var/mobile/idsbaa.log
rm -f /var/mobile/.beepserv_invalidate /var/mobile/.beepserv_kill
touch /var/mobile/.idsbaa_kill /var/mobile/.idsbaa_invalidate
chown mobile:mobile /var/mobile/.idsbaa_kill /var/mobile/.idsbaa_invalidate

# idextract must stay disabled (races Absinthe cert)
[ -f /Library/MobileSubstrate/DynamicLibraries/idextract.plist ] && \
  mv /Library/MobileSubstrate/DynamicLibraries/idextract.plist \
     /Library/MobileSubstrate/DynamicLibraries/idextract.plist.bak

sleep 2
killall -9 identityservicesd beepservd 2>/dev/null || true

i=0
while [ "$i" -lt 45 ]; do
  if grep -q "Done hooking" /var/mobile/beepserv.log 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 1
done
sleep 3
echo "=== boot ==="
tail -30 /var/mobile/beepserv.log || true
echo "=== idsbaa ==="
cat /var/mobile/idsbaa.log || true
echo "=== accounts now ==="
python3 - <<'PY'
import sqlite3
c = sqlite3.connect("/var/mobile/Library/Accounts/Accounts3.sqlite")
print(c.execute("SELECT Z_PK, ZUSERNAME, ZACCOUNTDESCRIPTION FROM ZACCOUNT").fetchall())
PY
