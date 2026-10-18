# Local validation

The final source was checked with the pinned Foundry configuration:

| Check | Result |
| --- | --- |
| `forge build` | Passed |
| `forge test -vv` | 102 passed, 0 failed, across 7 suites (plus the two reviewer proofs, run from a scratch copy: both pass) |
| `forge fmt --check` | Passed |
| Vault runtime | 24,528 bytes, within the 24,576-byte EIP-170 limit |
| Router runtime | 7,327 bytes, within the EIP-170 limit |
| Supplied application opcode scan | Passed for both applications; the vault runtime ends in code, with no trailing constant data region |
| External library link references | None |

The fixed fuzz seed is in `foundry.toml`. Both bettor-count fuzz tests run 128 cases with counts from 1 through 500: one covers Open withdrawal conservation, the other unequal-stake settlement and complete payout. The stateful invariant suite runs 64 sequences of 64 calls and checks solvency, the single unresolved spin rule and that `unresolvedShares` equals the stake of every round that is neither AwaitingSale nor Settled, with intentional invalid-state calls allowed to revert. The oracle callback test also explicitly marks accounts and storage cold before its 200,000-gas delivery.

The original protocol digest/signature vector, the static factory constructors with absent dependency code, premature-bet prevention, reentrant payouts, deadline fallback cutoff, the paid oracle decision under the live one-hour settlement window, FWA external resolution, stuck NFT recovery, stranded NFT release and builder transfer-helper behavior are included in the passing tests.

The revision after the independent review changed `optimizer_runs` from 800 to 700. The added code pushed the vault's runtime over the EIP-170 limit at 800 runs; at 600 runs or fewer the compiler's constant optimizer moves 32-byte constants into a CODECOPY data region after the code, which a linear opcode scan can misread as opcodes. 700 runs keeps the runtime within the limit and emits all constants inline.

These are local checks against the delivered source and offline mocks. They do not replace the assignment's independent verification or a security audit. See [SECURITY.md](SECURITY.md) for trust boundaries and the limits of the review.
