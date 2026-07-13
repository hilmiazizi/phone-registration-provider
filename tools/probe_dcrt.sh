#!/bin/bash
# Run on-device as root. Probes DCRT / DeviceIdentity renew path.
set -x
DCRT=/private/var/containers/Data/System/1598C2CD-DBDB-410C-8455-8BA776C14C49/Library/dcrt

echo "=== MA strings ==="
python3 - <<'PY'
import re
data = open("/usr/libexec/mobileactivationd", "rb").read()
keys = (b"dcrt", b"DCRT", b"humb", b"HUMBUG", b"issueClient", b"DeleteExisting",
        b"ReferenceKey", b"kMAOptions", b"RKCertification", b"RKSigning",
        b"baa", b"BAA", b"OOB", b"DeviceCert")
found = set()
for s in re.findall(rb"[\x20-\x7e]{6,}", data):
    if any(k in s for k in keys):
        found.add(s.decode("ascii", "replace"))
open("/tmp/ma_s.txt", "w").write("\n".join(sorted(found)))
print("count", len(found))
PY
head -120 /tmp/ma_s.txt

echo "=== dcrt ==="
openssl x509 -inform DER -in "$DCRT/dcrt.der" -noout -dates -subject 2>&1 || true
ls -la "$DCRT" /var/mobile/Library/Logs/mobileactivationd/

echo "=== backups / extracts ==="
ls -la /var/mobile/bak_beepserv 2>/dev/null | head
ls -la /var/mobile/idextract.json /var/mobile/dcrt_req.txt /var/mobile/dcrt_resp.txt 2>/dev/null
head -c 400 /var/mobile/dcrt_req.txt 2>/dev/null; echo

echo "=== find der certs ==="
find /private/var/containers/Data/System -name "*.der" 2>/dev/null
find /private/var/containers/Shared -name "*BAA*" -o -name "*ucrt*" 2>/dev/null | head
