#!/usr/bin/env python3
"""
genfp.py - generate a CONSISTENT iPhone9,3 (iPhone 7 / A1778) device-identity
fingerprint and write it as /var/mobile/.mgspoof.plist for the MGSpoof tweak.

The golden rule of beating Apple's per-device cap is INTERNAL CONSISTENCY:
- per-UNIT ids (serial, UDID, ECID, IMEI, MACs) are ROTATED every cycle
- per-MODEL ids (ProductType, HardwareModel, ChipID, BoardId) are kept FIXED
  to the real iPhone9,3 truth, otherwise the tuple is implausible and flagged.

BEST PRACTICE: seed the fixed/template parts from one of YOUR real iPhone 7s.
On the device:  gestalt SerialNumber InternationalMobileEquipmentIdentity \
                        HardwareModel ProductType
Then pass --serial-template <real_serial> --imei-tac <first 8 digits of real IMEI>.
Only the unique middle is randomized, so factory code + model-config + TAC stay real.

Usage:
    python3 genfp.py --serial-template F4JSDXCEHG7K --imei-tac 35404207 -o mgspoof.plist
    # copy to device: scp mgspoof.plist root@iphone:/var/mobile/.mgspoof.plist
"""

import argparse
import plistlib
import random
import string

# Apple serial charset for the random UNIQUE identifier (chars 6-8): no vowels,
# no easily-confused chars. (The unique field may be alphanumeric.)
SERIAL_CHARS = "0123456789CDFGHJKLMNPQRTVWXY"
HEX = "0123456789abcdef"

# Apple 12-char serial (2010-2020) = PPP Y W SSS CCCC:
#   PPP  chars 1-3  manufacturing plant
#   Y    char  4    year + half-of-year (letter, see table)
#   W    char  5    week-of-half (digit 1-9 = wk 1-9; letter = wk 10-27)
#   SSS  chars 6-8  unique unit identifier
#   CCCC chars 9-12 model/config code (ties to ProductType+color+capacity)
# Year letter -> (calendar year, half). Two letters per year, looping each decade.
YEAR_HALF = {
    "C": (2010, 1), "D": (2010, 2), "F": (2011, 1), "G": (2011, 2),
    "H": (2012, 1), "J": (2012, 2), "K": (2013, 1), "L": (2013, 2),
    "M": (2014, 1), "N": (2014, 2), "P": (2015, 1), "Q": (2015, 2),
    "R": (2016, 1), "S": (2016, 2), "T": (2017, 1), "V": (2017, 2),
    "W": (2018, 1), "X": (2018, 2), "Y": (2019, 1), "Z": (2019, 2),
}
# Week code -> week-of-half (1..27): digits 1-9, then letters C..Y minus vowels & S.
WEEK_ORDER = "123456789CDFGHJKLMNPQRTVWXY"   # index 0 => week 1
# iPhone 7 (iPhone9,3) shipped Sep 2016 .. ~2019, so manufacture is 2016 H2 onward.
IPHONE7_YEAR_CODES = "STVWXYZ"   # 2016 H2, 2017 H1/H2, 2018 H1/H2, 2019 H1/H2
# A few real Apple Wi-Fi OUIs (first 3 octets).
APPLE_OUIS = ["f0:18:98", "3c:15:c2", "a4:83:e7", "90:9c:4a", "f4:0f:24", "ac:bc:32"]


def luhn_check_digit(num14: str) -> str:
    """Standard Luhn check digit for a 14-digit IMEI body."""
    total = 0
    for i, ch in enumerate(num14):
        d = int(ch)
        # double every second digit counting from the right of the final 15-digit
        # number => from the left of the 14-digit body the doubling lands on odd idx
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return str((10 - (total % 10)) % 10)


def decode_serial_date(serial: str) -> str:
    """Human-readable manufacture date a 12-char serial decodes to (for verification)."""
    y, w = serial[3], serial[4]
    if y not in YEAR_HALF or w not in WEEK_ORDER:
        return "INVALID date code"
    year, half = YEAR_HALF[y]
    week = WEEK_ORDER.index(w) + 1 + (26 if half == 2 else 0)
    return f"{year} H{half} (~week {week})"


def gen_serial(template: str, rotate_date: bool = True) -> str:
    """Build a FORMAT-VALID iPhone serial: PPP Y W SSS CCCC.

    Keeps the plant (1-3) and model-config (9-12) from a REAL serial so the
    tuple stays consistent with iPhone9,3. The year (4) and week (5) are drawn
    from Apple's VALID code sets (so the serial decodes to a plausible iPhone 7
    manufacture date, not garbage), and the 3-char unique unit id (6-8) is random.
    """
    template = (template or "F4JSDXCEHG7K").upper()
    if len(template) != 12:
        raise SystemExit(f"serial template must be 12 chars, got {len(template)!r}")
    plant = template[:3]
    config = template[8:12]
    if rotate_date:
        year_c = random.choice(IPHONE7_YEAR_CODES)        # valid half-year letter
        week_c = random.choice(WEEK_ORDER)                # valid week code
    else:
        year_c = template[3]                              # keep the real date code
        week_c = template[4]
    unique = "".join(random.choice(SERIAL_CHARS) for _ in range(3))
    serial = plant + year_c + week_c + unique + config
    assert len(serial) == 12
    return serial


def gen_imei(tac: str) -> str:
    tac = (tac or "35404207")
    if len(tac) != 8 or not tac.isdigit():
        raise SystemExit("--imei-tac must be the 8-digit TAC of a real iPhone 7")
    serial6 = "".join(random.choice(string.digits) for _ in range(6))
    body = tac + serial6  # 14 digits
    return body + luhn_check_digit(body)


def gen_udid() -> str:
    # iPhone 7 / iOS 15 uses the 40-hex-char UDID format.
    return "".join(random.choice(HEX) for _ in range(40))


def gen_mac() -> str:
    oui = random.choice(APPLE_OUIS)
    tail = ":".join(f"{random.randint(0,255):02x}" for _ in range(3))
    return f"{oui}:{tail}"


def bt_from_wifi(wifi: str) -> str:
    parts = wifi.split(":")
    parts[-1] = f"{(int(parts[-1],16)+1)%256:02x}"
    return ":".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial-template", default="F4JSDXCEHG7K",
                    help="a REAL iPhone 7 serial; factory+config kept, middle rotated")
    ap.add_argument("--imei-tac", default="35404207",
                    help="8-digit TAC from a REAL iPhone 7 IMEI")
    ap.add_argument("--product-type", default="iPhone9,3")
    ap.add_argument("--hardware-model", default="D101AP")
    ap.add_argument("-o", "--out", default="mgspoof.plist")
    args = ap.parse_args()

    wifi = gen_mac()
    fp = {
        # ---- ROTATED per cycle (per-unit identifiers) ----
        "SerialNumber": gen_serial(args.serial_template),
        "UniqueDeviceID": gen_udid(),
        "UniqueChipID": random.randint(0x10_0000_0000, 0xFF_FFFF_FFFF),  # ECID
        "DieID": random.randint(0x10_0000_0000, 0xFF_FFFF_FFFF),
        "InternationalMobileEquipmentIdentity": gen_imei(args.imei_tac),
        "WifiAddress": wifi,
        "BluetoothAddress": bt_from_wifi(wifi),
        "EthernetMacAddress": wifi,
        # ---- FIXED to the real model (do NOT randomize: must stay consistent) ----
        "ProductType": args.product_type,
        "HardwareModel": args.hardware_model,
    }

    with open(args.out, "wb") as f:
        plistlib.dump(fp, f)

    sn = fp["SerialNumber"]
    print(f"[+] wrote {args.out}")
    for k, v in fp.items():
        print(f"    {k:42} {v}")
    print(f"\n[*] serial breakdown: plant={sn[:3]} year={sn[3]} week={sn[4]} "
          f"unique={sn[5:8]} config={sn[8:12]}")
    print(f"[*] decodes to: {decode_serial_date(sn)}  "
          f"(real template decoded: {decode_serial_date(args.serial_template.upper())})")
    print("\n[*] copy to device:  scp", args.out, "root@<iphone>:/var/mobile/.mgspoof.plist")
    print("[*] then run reset_cycle.sh on the device to apply + re-register.")


if __name__ == "__main__":
    main()
