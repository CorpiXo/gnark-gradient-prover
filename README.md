# gnark-gradient-prover

A Groth16 proof service for federated learning: clients prove that the model
update they upload is bounded and matches what the server aggregates, and the
server verifies those proofs without seeing the update.

It is the proving backend for [ppflx](https://github.com/CorpiXo/ppflx); the
protocol and its limitations are documented there (`docs/ZKP.md`).

## Circuits

| Circuit | Statement | Size |
|---|---|---|
| `norm` | MiMC hash of the quantized update, and Σ Δq² within a declared bound, with a range check per witness | 256 values per proof, 103,365 constraints |
| `elgamal` | The same bound over coordinates encrypted with exponential ElGamal, binding the proof to the ciphertext the server aggregates | 128 coordinates per proof, 1,274,949 constraints |

## Build

Go 1.26 or later (see `go.mod`).

```bash
go build -o gnark_service .
```

## Keys

`gnark_service setup` compiles both circuits, runs Groth16 setup and writes
`manifest.json` and the verifying keys into `--keys-dir`, and the proving keys
(hundreds of MB) into `--pk-dir`. It refuses to replace an existing manifest or
proving key without `--force`.

### Local keys, for benchmarks and development

Proving keys are never committed, so a fresh checkout cannot prove under the
pinned keys in `keys/`. Run your own setup outside the repository instead:

```bash
./gnark_service setup --keys-dir ~/.cache/ppflx/keys --pk-dir ~/.cache/ppflx/pk
export FL_ZKP_KEYS_DIR=~/.cache/ppflx/keys
export FL_ZKP_PK_DIR=~/.cache/ppflx/pk
```

Setup takes a while for the ElGamal circuit. When
one operator runs the prover, the verifier and the clients, a local setup is
self-consistent, and proving and verification cost depend on the circuit and
the witness, not on the setup randomness. ppflx and ppflx-bench read both
variables, and every ZKP round outcome in a ppflx-bench report records the
manifest's SHA-256 (`key_manifest_sha256`), so the keys each run used are
traceable.

### Pinned keys

`keys/` holds the pinned manifest and verifying keys that ppflx ships as its
trust anchor (`ppflx/core/gnark_keys_data/`). Re-keying them is a deliberate
change: run setup into `keys/` with `--force`, and update the copy in ppflx in
the same set of pull requests, since proofs under the old keys stop verifying.
It is never a way to get started.

## Run

Two roles, so the verifier never holds proving keys:

```bash
./gnark_service serve --role prover   --keys-dir "$FL_ZKP_KEYS_DIR" --pk-dir "$FL_ZKP_PK_DIR" --port 9000
./gnark_service serve --role verifier --keys-dir "$FL_ZKP_KEYS_DIR" --port 9001
```

Both roles refuse to start if a key is missing or differs from the manifest.
ppflx-bench starts both itself from `FL_GNARK_BINARY`.

`./test_gnark_integration.sh` starts both roles from `FL_ZKP_KEYS_DIR` (default:
`keys/`) and `FL_ZKP_PK_DIR` (default: `~/.cache/ppflx/pk`) and checks a
prove/verify round trip end to end.

## Keys and trust

`manifest.json` pins each circuit's verifying key and proving key by SHA-256,
and every proof carries the hash of the verifying key it was made under; a
proof under any other key is rejected. Every setup, the pinned one included, is
**single-party**: the setup randomness existed in one process and is not
recoverable from these files, but nothing proves it was destroyed. A
multi-party ceremony would remove that assumption.

## Tests

```bash
go test ./...
```

## Licence

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 CorpiXo.
