#!/usr/bin/env python3
"""
assemble_bbox.py — turn an idextract.json (keychain dump from inside
identityservicesd) into a rustpush-compatible bbox (caches.json format).

A bbox is a flat TLV stream: tag(1) | len(2, big-endian) | value.
rustpush's `Bbox::parse` only needs these tags for an id-query lookup:

    0x10  serial   (informational alias)
    0x11  main_id  (the registered handle, e.g. an email)
    0x21  push_token  (32 bytes)          <-- REQUIRED
    0x31  id_cert     (DER, IDS identity)  <-- REQUIRED
    0x32  id_priv_der (PKCS#1 RSA-2048)    <-- REQUIRED

Push cert/key and EC keys are NOT needed for the HTTP id-query path.

Usage:
    pip install cryptography
    python3 assemble_bbox.py idextract.json \
        --handle mailto:hilmiazizi19@icloud.com \
        --serial C02XXXXXXXXX \
        -o caches.json
"""

import argparse
import base64
import json
import struct
import sys

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
except ImportError:
    sys.exit("Need `cryptography`: pip install cryptography")


# keychain attribute 4-char codes
K_CLASS = "__class__"
K_SVCE = "svce"      # service
K_ACCT = "acct"      # account
K_AGRP = "agrp"      # access group
K_LABL = "labl"      # label
K_DATA = "v_Data"    # value data


def b64field(item, key):
    """Return the raw bytes for a keychain field stored as {'__b64__': ...}."""
    v = item.get(key)
    if isinstance(v, dict) and "__b64__" in v:
        return base64.b64decode(v["__b64__"])
    if isinstance(v, str):
        return v.encode()
    return None


def s(item, key):
    v = item.get(key)
    return v if isinstance(v, str) else None


def load_rsa_private(der):
    """Load an RSA private key from DER in whatever format the keychain stored it."""
    for loader in (
        lambda d: serialization.load_der_private_key(d, password=None),
        lambda d: serialization.load_pem_private_key(d, password=None),
    ):
        try:
            k = loader(der)
            if isinstance(k, rsa.RSAPrivateKey):
                return k
        except Exception:
            pass
    return None


def to_pkcs1_der(key):
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )


def tlv(tag, value):
    return struct.pack(">B H", tag, len(value)) + value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump", help="idextract.json from the device")
    ap.add_argument("--handle", required=True, help="e.g. mailto:foo@bar.com")
    ap.add_argument("--serial", default="IPHONE", help="device serial (alias only)")
    ap.add_argument("--push-token", help="base64 push token override (32 bytes)")
    ap.add_argument("-o", "--out", default="caches.json")
    args = ap.parse_args()

    items = json.load(open(args.dump))
    print(f"[*] {len(items)} keychain items loaded")

    # --- 1. IDS identity RSA private key -------------------------------------
    rsa_key = None
    for it in items:
        acct = (s(it, K_ACCT) or "").lower()
        svce = (s(it, K_SVCE) or "").lower()
        if "identity-rsa" in acct or ("ids" in svce and "rsa" in acct):
            d = b64field(it, K_DATA)
            if d and (k := load_rsa_private(d)):
                rsa_key = k
                print(f"[+] IDS RSA key: svce={s(it,K_SVCE)} acct={s(it,K_ACCT)}")
                break
    if rsa_key is None:
        # fall back: any RSA private key in the dump
        for it in items:
            d = b64field(it, K_DATA)
            if d and (k := load_rsa_private(d)):
                rsa_key = k
                print(f"[~] fallback RSA key: svce={s(it,K_SVCE)} acct={s(it,K_ACCT)}")
                break
    if rsa_key is None:
        sys.exit("[!] no RSA private key found in dump")

    key_n = rsa_key.private_numbers().public_numbers.n
    id_priv_der = to_pkcs1_der(rsa_key)

    # --- 2. matching IDS identity certificate --------------------------------
    # The IDS identity cert is usually NOT a standalone keychain cert item; it
    # is packed inside a registration blob (e.g. com.apple.facetime/registrationV2).
    # So: gather candidate DER certs from (a) standalone cert items and (b) any
    # SEQUENCE found inside every item's data, then match by modulus.
    def candidate_certs():
        for it in items:
            d = b64field(it, K_DATA)
            if not d:
                continue
            if it.get(K_CLASS) == "cert":
                yield d
            # scan blob for embedded DER certs (0x30 0x82 LL LL ...)
            i = 0
            while True:
                j = d.find(b"\x30\x82", i)
                if j < 0:
                    break
                if j + 4 <= len(d):
                    ln = int.from_bytes(d[j + 2:j + 4], "big") + 4
                    yield d[j:j + ln]
                i = j + 2

    id_cert = None
    for d in candidate_certs():
        try:
            cert = x509.load_der_x509_certificate(d)
        except Exception:
            continue
        pub = cert.public_key()
        if isinstance(pub, rsa.RSAPublicKey) and pub.public_numbers().n == key_n:
            id_cert = d
            print(f"[+] matched id_cert (subject: {cert.subject.rfc4514_string()})")
            break
    if id_cert is None:
        sys.exit("[!] no certificate matching the RSA key was found")

    # --- 3. push token -------------------------------------------------------
    push_token = None
    if args.push_token:
        push_token = base64.b64decode(args.push_token)
    else:
        # The madrid/iMessage identity uses the device's *common* APNs token,
        # stored as service "push.apple.com" with an EMPTY account. The
        # "push.apple.com,PerAppToken.v0" entries are per-app tokens (not madrid).
        main = [it for it in items
                if s(it, K_SVCE) == "push.apple.com" and not (s(it, K_ACCT) or "")]
        if main:
            push_token = b64field(main[0], K_DATA)
            print(f"[+] push token: push.apple.com (common) "
                  f"{base64.b64encode(push_token).decode()}")
        else:
            cands = [(s(it, K_SVCE), b64field(it, K_DATA)) for it in items
                     if b64field(it, K_DATA) and len(b64field(it, K_DATA)) == 32]
            print(f"[~] no common push.apple.com token; candidates ({len(cands)}):")
            for svce, d in cands:
                print(f"      svce={svce}  b64={base64.b64encode(d).decode()}")
            if cands:
                push_token = cands[0][1]
                print("[~] using first candidate; pass --push-token to override")
    if push_token is None or len(push_token) != 32:
        sys.exit("[!] no 32-byte push token found; supply --push-token <b64>")

    # --- 4. assemble bbox ----------------------------------------------------
    blob = b""
    blob += tlv(0x10, args.serial.encode())
    blob += tlv(0x11, args.handle.split(":", 1)[-1].encode())
    blob += tlv(0x21, push_token)
    blob += tlv(0x31, id_cert)
    blob += tlv(0x32, id_priv_der)

    b64 = base64.b64encode(blob).decode()
    json.dump([b64], open(args.out, "w"), indent=2)
    print(f"[+] wrote {args.out} ({len(blob)} bytes, base64 {len(b64)} chars)")
    print("[*] test it:  cargo run --example lookup  (feed caches.json to Bbox::parse_b64)")


if __name__ == "__main__":
    main()
