#!/usr/bin/env bash
# Caravan installer — safe to run via:
#   curl -fsSL https://raw.githubusercontent.com/adukhan99/Caravan/main/scripts/install.sh | bash
# or from inside a checkout:  ./scripts/install.sh
set -euo pipefail

REPO_URL="${CARAVAN_REPO:-https://github.com/adukhan99/Caravan.git}"
CLONE_DIR="${CARAVAN_SRC:-$HOME/.caravan/src}"

say()  { printf '  %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

echo "☾ Caravan installer"
echo "───────────────────"

# 1. opam is the only hard prerequisite.
command -v opam >/dev/null 2>&1 || fail \
  "opam is not installed. Get it first: https://opam.ocaml.org/doc/Install.html"

# 2. Ensure an initialized opam with an OCaml 5 switch.
if [ ! -d "$HOME/.opam" ]; then
    say "Initializing opam (this compiles OCaml once — several minutes)…"
    opam init --bare -a -y
fi
eval "$(opam env 2>/dev/null || true)"

OCAML_MAJOR="$(ocaml -e 'print_string (String.sub Sys.ocaml_version 0 1)' 2>/dev/null || echo 0)"
if [ "$OCAML_MAJOR" -lt 5 ]; then
    say "Current switch is OCaml ${OCAML_MAJOR}.x; Caravan needs OCaml 5 (effects)."
    say "Creating a 5.2.0 switch (one-time compile)…"
    opam switch create 5.2.0 -y || opam switch set 5.2.0
    eval "$(opam env)"
fi

# 3. Locate or fetch the sources. Works both piped-from-curl and in-checkout.
if [ -f dune-project ] && grep -q '(name Caravan)' dune-project 2>/dev/null; then
    SRC="$(pwd)"
    say "Using existing checkout: $SRC"
else
    if [ -d "$CLONE_DIR/.git" ]; then
        say "Updating existing clone in $CLONE_DIR…"
        git -C "$CLONE_DIR" pull --ff-only || true
    else
        say "Cloning Caravan into $CLONE_DIR…"
        mkdir -p "$(dirname "$CLONE_DIR")"
        git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
    fi
    SRC="$CLONE_DIR"
fi
cd "$SRC"

# 4. System libraries openssl/gmp are needed by the OCaml deps.
if ! pkg-config --exists openssl 2>/dev/null; then
    say "⚠ openssl development headers not found (libssl-dev / openssl-devel)."
    say "  Install them if the next step fails."
fi

# 5. Dependencies + build + install onto PATH (opam's bin dir).
say "Installing OCaml dependencies…"
opam install . --deps-only --with-test -y
say "Building…"
dune build
say "Installing the caravan binary…"
dune install --prefix "$(opam var prefix)" 2>/dev/null || dune install

echo
say "✓ Installed. Try:"
say "    caravan init      # guided setup (provider, model, API key)"
say "    caravan doctor    # verify the installation"
say "    caravan           # start chatting"
if ! command -v caravan >/dev/null 2>&1; then
    say "⚠ 'caravan' is not on PATH yet — run:  eval \"\$(opam env)\""
fi
