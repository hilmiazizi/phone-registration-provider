# beepserv (spoofing fork) — Beeper validation-data provider

Jailbroken iPhone provider that mints **spoofed** iMessage validation-data (~261 bytes)
for rustpush over Beeper’s registration-relay.

**Spoof + `baa:false` is the only supported Beeper farm mode.** Real-serial passthrough
is debug-only. Every account cycle starts with [`ops/relayrotate`](ops/relayrotate).

| Doc | Purpose |
|-----|---------|
| **[INSTALL.md](INSTALL.md)** | Fresh phone → install deb → **first `relayrotate` (spoof on)** |
| **[FARM.md](FARM.md)** | Every Apple ID: spoof rotate → rustpush `--register` |
| **[ARCHITECTURE.md](ARCHITECTURE.md)** | Why spoof is mandatory + mint path |
| **[REPAIR.md](REPAIR.md)** | Optional `baawipe` / `dcrtforce` when Absinthe/DCRT dies |
| [releases/](releases/) | Production kit: beepserv deb (includes `relayrotate`) + repair debs |

Consumer repo: [rustpush](https://github.com/hilmiazizi/rustpush) (Linux/WSL). Protocol-only
coupling via the relay — see ARCHITECTURE.

> Fork of [thatmarcel/beepserv-rewrite](https://github.com/thatmarcel/beepserv-rewrite) /
> [beeper/phone-registration-provider](https://github.com/beeper/phone-registration-provider).
> Research leftovers: [`research/`](research/) — do **not** install on farm phones.

## Quick path

```sh
# on phone (root, unlocked) — enables spoof, baa:false, new identity + code
relayrotate

# on Linux
cd ~/imessage/rustpush
RUST_LOG=info ./target/release/rustpush-test --register --relay-code=XXXX-XXXX-XXXX-XXXX
```

Healthy phone: `get-version-info` serial **equals** `.beepserv_spoof.plist` and is **not**
the fused real serial; `get-validation-data` → HTTP 200 / ~261B.

## What the package does

- **`bp_spoof.x`**: spoof Serial/UDID/IMEI; force `baa:false`
- **Mint**: IDS validation queue → `setValidationData:` (~261B)
- **`BPDeviceIdentifiers`**: generate/rotate `.beepserv_spoof.plist` (`Enabled=YES`)
- **`beepservd`**: relay WebSocket; version-info matches spoof

## Building

```sh
git submodule update --init --recursive
make clean package FINALPACKAGE=1
# Pin into releases/ and bump INSTALL.md
```

## Credits

Original [beepserv](https://github.com/beeper/phone-registration-provider) (Beeper);
rewrite by [thatmarcel](https://github.com/thatmarcel/beepserv-rewrite).
