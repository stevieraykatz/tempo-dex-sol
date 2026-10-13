#!/usr/bin/env bash
# Checks that test/spec is Tempo's upstream DEX suite, then runs it on the precompile and on the port.
set -euo pipefail

TEMPO_REV=80fe55edf20f013efeac6f9d8b5e71d75cfab5a8
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> Fetching tempoxyz/tempo@${TEMPO_REV:0:7}"
git clone -q --filter=blob:none --no-checkout https://github.com/tempoxyz/tempo "$tmp/tempo"
git -C "$tmp/tempo" sparse-checkout set --no-cone /tips/verify/test/
git -C "$tmp/tempo" checkout -q "$TEMPO_REV"
up="$tmp/tempo/tips/verify/test"

echo "==> Diffing test/spec against upstream (only change: setUp marked virtual)"
mkdir -p "$tmp/expected/invariants"
cp -R "$up/TempoTest.t.sol" "$up/StablecoinDEX.t.sol" "$up/mocks" "$up/helpers" "$tmp/expected/"
cp "$up/invariants/StablecoinDEX.t.sol" "$up/invariants/InvariantBaseTest.t.sol" "$tmp/expected/invariants/"
sed -i.bak 's/function setUp() public override {/function setUp() public virtual override {/' \
  "$tmp/expected/StablecoinDEX.t.sol" "$tmp/expected/invariants/StablecoinDEX.t.sol"
find "$tmp/expected" -name '*.bak' -delete
diff -r "$tmp/expected" test/spec
echo "    identical"

echo "==> Spec suite on the Rust precompile"
forge test --match-contract '^StablecoinDEX(Invariant)?Test$'

echo "==> Same suite on the Solidity port"
forge test --match-contract '^PortStablecoinDEX'
