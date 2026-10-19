# Fresh device identity + relay code

**Canonical docs:** [INSTALL.md](../INSTALL.md) · [FARM.md](../FARM.md)

`ops/relayrotate` soft-rotates spoof identity + relay code (beepserv-native flags only).
It does **not** hard-nuke Accounts / IdentityServices / Absinthe ucrt.

Install on the iPhone once:

```bash
# relayrotate is installed by the beepserv deb at /usr/bin/relayrotate
```

Run as root (**phone unlocked**):

```bash
relayrotate
```

Then smoke-test and register — see [FARM.md](../FARM.md).

```bash
curl -sS --max-time 90 -X POST "https://registration-relay.beeper.com/api/v1/bridge/get-validation-data" \
  -H "Authorization: Bearer NEW-CODE-HERE" \
  -H "X-Beeper-Access-Token: 5c175851953ecaf5209185d897591badb6c3e712" \
  -H "Content-Length: 0"
```

```bash
cd ~/imessage/rustpush
rm -f hwconfig.plist
RUST_LOG=info ./target/release/rustpush-test --register --relay-code=NEW-CODE-HERE
```

**Do not sign into any Apple ID on the provider phone.**
