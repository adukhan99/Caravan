# Installation

## Requirements

- [opam](https://opam.ocaml.org/doc/Install.html) ≥ 2.1 — the only hard prerequisite
- OCaml ≥ 5.1 (the installer creates a 5.2 switch if needed)
- system libraries: `libssl-dev`, `libgmp-dev`, `pkg-config`

Everything installs into `~/.opam` — **no root required**.

## One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/adukhan99/Caravan/main/scripts/install.sh | bash
```

The installer is idempotent: it initializes opam if needed, ensures an
OCaml 5 switch, clones (or updates) the source in `~/.caravan/src`, builds,
and installs the `caravan` binary onto opam's PATH.
Override the clone location with `CARAVAN_SRC`, the repo with `CARAVAN_REPO`.

## Manual build

```bash
git clone https://github.com/adukhan99/Caravan.git && cd Caravan
opam install . --deps-only --with-test -y
dune build && dune test
dune exec caravan -- init
```

## First run

```bash
caravan init      # pick a provider, model, API key (input hidden; config saved 0600)
caravan doctor    # verify config, keys, endpoint reachability
caravan           # chat
```

## Upgrade / uninstall

```bash
# upgrade: re-run the installer
# uninstall:
rm -rf ~/.caravan
opam remove Caravan
```
