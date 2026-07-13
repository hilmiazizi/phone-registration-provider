# research/ — archive only

**Do not install anything under this directory on farm phones.**

Spoof + `baa:false` + mint live inside the product package `com.beeper.beepserv`
(see [INSTALL.md](../INSTALL.md), [ARCHITECTURE.md](../ARCHITECTURE.md)).

| Path | Historical role |
|------|-----------------|
| `idsbaa/` | Forced `baa:false` + keychain dump/purge before spoof was integrated |
| `mgspoof/` | Gestalt `MGCopyAnswer` spoof / `genfp.py` experiments |
| `idextract/` | Dump signed-in IDS identity for bbox cloning |
| `beepserv-fork/` | Nested old fork tree — **gitignored**; see [`SPOOF_FORK.md`](SPOOF_FORK.md) |
| `re/` | Pulled binaries / RE notes |
| `archive/` | Dumps and one-off captures |

Repair tweaks for production (**optional**): prebuilt debs in [`../releases/`](../releases/),
sources in [`../tools/baawipe`](../tools/baawipe) / [`../tools/dcrtforce`](../tools/dcrtforce).
See [`../REPAIR.md`](../REPAIR.md). **idsbaa is not a farm dependency.**
