# tools/ — host helpers + repair tweak sources

## Production-related

| Path | Role |
|------|------|
| [`../ops/relayrotate`](../ops/relayrotate) | **Use this** for farm rotate (canonical) |
| `relayrotate` | Thin wrapper → `ops/relayrotate` |
| `_ssh.py` | Host SSH helper for PoC phones |
| `assemble_bbox.py` | Off-device bbox assembly |
| `baawipe/` | Source for DeviceIdentity repair tweak → deb in `releases/` |
| `dcrtforce/` | Source for DCRT repair tweak → deb in `releases/` |

## Not for farm install

Probe scripts (`probe_dcrt.sh`, `force_dcrt.js`, …) and `_heal_accounts.sh` are
one-off recovery aids. Prefer [REPAIR.md](../REPAIR.md) + `releases/` debs.
