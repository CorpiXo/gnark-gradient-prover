# Contributing

Thanks for your interest. This project implements cryptographic protocols, so
contributions are held to a stricter standard than the average Python library:
a claim about what a circuit or a key check guarantees has to be backed by a test.

## Contributor Licence Agreement

Before a pull request can be merged you must sign the CLA, which the CLA
assistant will prompt for on your first pull request. It licenses your
contribution to CorpiXo, which holds copyright for the project, so the project
can be relicensed or dual-licensed in future without tracking down every
contributor. You keep the copyright in your own work.

## Development setup

Go 1.26 or later (see `go.mod`).

```bash
go build -o gnark_service .
go test ./...
```

The tests run setup on small circuits in temporary directories; they never
touch `keys/`. For the integration script, make a local key set outside the
repository first (see [README.md](README.md#local-keys-for-benchmarks-and-development)):

```bash
./gnark_service setup --keys-dir ~/.cache/ppflx/keys --pk-dir ~/.cache/ppflx/pk
export FL_ZKP_KEYS_DIR=~/.cache/ppflx/keys FL_ZKP_PK_DIR=~/.cache/ppflx/pk
./test_gnark_integration.sh
```

## Before opening a pull request

1. `go test ./...` passes and `gofmt -l .` prints nothing.
2. If you changed a circuit, the key format or an endpoint, run
   `./test_gnark_integration.sh` against a fresh local key set.
3. A circuit change or a re-keying changes the pinned keys in `keys/`: update
   the copy in ppflx (`ppflx/core/gnark_keys_data/`) in the same set of pull
   requests, and run the affected ZKP modes from ppflx-bench end to end:
   `python compare.py --dataset healthcare --modes <modes> --rounds 2 --num-clients 2`
4. New behaviour in a security-relevant path comes with a test that fails
   without your change.

## What the project expects of a change

- **Fail closed.** On error or ambiguity in a security-relevant path, abort;
  do not continue with a weaker guarantee.
- **Claims match tests.** Do not describe a property as verified unless a test
  exercises it. Prover and verifier timings are cost measurements, not
  soundness results.
- **Numbers come from raw results.** `results/**/comparison_report.json` is the
  source of truth for benchmark figures; documentation follows it, not the
  other way round.
- **No proving keys in commits.** Only `keys/manifest.json` and the `.vk`
  files are committed, and only when the pinned keys change deliberately.

## Reporting a vulnerability

Do not open a public issue. See [SECURITY.md](SECURITY.md).
