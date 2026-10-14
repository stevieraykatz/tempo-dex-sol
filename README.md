# tempo-dex-sol

Tempo's StablecoinDEX precompile (`0xDEc0000000000000000000000000000000000000`) ported from Rust to
Solidity, for reading.

- [`src/StablecoinDEX.sol`](src/StablecoinDEX.sol) is the port. It matches the precompile at the
  latest hardfork, from [`tempoxyz/tempo@80fe55e`](https://github.com/tempoxyz/tempo/tree/80fe55edf20f013efeac6f9d8b5e71d75cfab5a8/crates/precompiles/src/stablecoin_dex).
  It follows the [Coinbase Solidity Style Guide](https://github.com/coinbase/solidity-style-guide).
- [`reference/StablecoinDEX.2026-04.sol`](reference/StablecoinDEX.2026-04.sol) is Tempo's own
  Solidity reference, deleted upstream in [#3699](https://github.com/tempoxyz/tempo/pull/3699).
  It's stale; the port started from it.

## Does it match?

Tempo's DEX spec suite (70 tests plus an invariant fuzzer) passes against both the precompile and
the port.

```sh
git clone --recursive https://github.com/stevieraykatz/tempo-dex-sol && cd tempo-dex-sol
./verify.sh
```

[`verify.sh`](verify.sh) does three things:

1. Fetches `tempoxyz/tempo@80fe55e` and diffs its `tips/verify/test` against `test/spec`. The only
   change here is that `setUp` is marked `virtual`.
2. Runs the suite on the Rust precompile.
3. Runs the same suite on the port. [`test/StablecoinDEX.t.sol`](test/StablecoinDEX.t.sol) points the
   suite's `exchange` at a deployed port instead of the precompile.

It needs Foundry 1.8.5+, which runs Tempo hardforks natively. CI runs the script on every push.

For a heavier run (500 runs × 500 depth; it passed with 250k calls in about 18 minutes):

```sh
FOUNDRY_PROFILE=fuzz500 forge test --match-contract PortStablecoinDEXInvariantTest
```

## Not modelled

- **Storage credits.** This is protocol gas accounting with no Solidity equivalent, so
  `storageCredits()` always returns 0.
- **Packed order records.** The port stores the plain `Order` struct. All other storage follows the
  precompile's slot order.
- **Allowance-free pulls.** The precompile pulls tokens with `systemTransferFrom`, which needs no
  allowance. The port uses `transferFrom`, which does.
- **Flip atomicity.** The precompile uses a storage checkpoint. The port uses a guarded self-call
  inside try/catch.
- **History and gas.** Pre-fork code paths and gas costs are not modelled.

## Changes since the April reference

| | April reference | Now |
|---|---|---|
| `place` on a missing pair | Reverts | Creates the pair |
| Flip tick | Strictly beyond `tick` | May equal `tick` |
| `flipTick` out of range | `InvalidFlipTick` | `TickOutOfBounds(flipTick)` |
| Full fill of a flip order | New order ID; failure ignored silently | Same order ID; failure emits `FlipFailed` |
| Placement policy | Both tokens checked for the maker | Escrow: maker → DEX. Payout: DEX → maker, and not paused |
| Pause | Not checked | Checked on route tokens, internal-balance debits, and the payout token |
| Quotes | Per tick | Per order, identical to execution |
| `totalLiquidity` | Stored | Summed on read |
| `swapExactAmountIn` | Debits input after filling | Debits input before filling |
| `cancelStaleOrder` | Escrow sender check only | Also the payout recipient check; a missing policy counts as stale |
| Book IDs | None | `bookKeys`, `bookIndexForKey`, `bookKeyForIndex`, `setBookIndex` |

## License

MIT OR Apache-2.0, as upstream. `reference/` and `test/spec/` are copied from
[tempoxyz/tempo](https://github.com/tempoxyz/tempo).
