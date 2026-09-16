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

## Build and run

```bash
go build -o gnark_service .

# One-time setup: writes manifest.json and the verifying keys into --keys-dir,
# and the proving keys into a local cache. Commit the verifying keys; never
# distribute the proving keys.
./gnark_service setup --keys-dir keys --pk-dir ~/.cache/fl_ppml/gnark_pk

# Two roles, so the verifier never holds proving keys
./gnark_service serve --role prover   --keys-dir keys --pk-dir ~/.cache/fl_ppml/gnark_pk --port 9000
./gnark_service serve --role verifier --keys-dir keys --port 9001
```

`./test_gnark_integration.sh` exercises a prove/verify round trip end to end.

## Keys and trust

`keys/manifest.json` pins each circuit's verifying key by SHA-256, and every
proof carries the hash of the key it was made under; a proof under any other
key is rejected. The setup is **single-party**: the setup randomness existed in
one process and is not recoverable from these files, but nothing proves it was
destroyed. A multi-party ceremony would remove that assumption.

## Tests

```bash
go test ./...
```

## Licence

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 CorpiXo.
