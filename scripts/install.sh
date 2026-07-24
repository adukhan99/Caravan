#!/usr/bin/env bash
set -e

echo "🐫 Caravan Installer"
echo "===================="

# 1. Check for opam
if ! command -v opam >/dev/null 2>&1; then
    echo "opam is not installed. Please install opam first (https://opam.ocaml.org/doc/Install.html)."
    exit 1
fi

# 2. Check/initialize opam environment
if [ ! -d "$HOME/.opam" ]; then
    echo "Initializing opam..."
    opam init --bare -a -y
fi

eval $(opam env 2>/dev/null || true)

# 3. Install dependencies
echo "Installing OCaml dependencies..."
opam install . --deps-only --with-test --with-doc --with-dev-setup -y

# 4. Build Caravan
echo "Building Caravan..."
dune build

echo ""
echo "  ✓ Build complete!"
echo "  Run 'dune exec caravan -- init' or '_build/default/bin/main.exe init' to set up your environment."
