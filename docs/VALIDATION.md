# Local validation

The final source was checked with the pinned Foundry configuration:

| Check | Result |
| --- | --- |
| `forge build` | Passed |
| `forge test -vv` | 91 passed, 0 failed, across 7 suites |
| `forge fmt --check` | Passed |
| Vault runtime | 24,477 bytes, within the 24,576-byte EIP-170 limit |
| Router runtime | 7,366 bytes, within the EIP-170 limit |
| Supplied application opcode scan | Passed for both applications |
| External library link references | None |

The fixed fuzz seed is in `foundry.toml`. Both bettor-count fuzz tests run 128 cases with counts from 1 through 500: one covers Open withdrawal conservation, the other unequal-stake settlement and complete payout. The stateful invariant suite runs 64 sequences of 64 calls and checks both solvency and the single unresolved spin rule, with intentional invalid-state calls allowed to revert. The oracle callback test also explicitly marks accounts and storage cold before its 200,000-gas delivery.

The original protocol digest/signature vector, the static factory constructors with absent dependency code, premature-bet prevention, reentrant payouts, deadline fallback cutoff, FWA external resolution, stuck NFT recovery and builder transfer-helper behavior are included in the passing tests.

These are local checks against the delivered source and offline mocks. They do not replace the assignment's independent verification or a security audit. See [SECURITY.md](SECURITY.md) for trust boundaries and the limits of the review.
