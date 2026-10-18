# Independent test additions

The existing tests and production contracts are unchanged. These additions run offline with the project's existing vendored dependencies and mocks. No RPC, environment mutation, FFI, downloaded runtime dependency, or skipped test is required.

| File | Additional coverage |
| --- | --- |
| `KeelAccountingProperties.t.sol` | Refunded-share rounding cycles; 2–500 independently weighted bettors, VRF losses, exit and replacement, retry, fees and shuffled claims; capacity reuse; simultaneous sale/refund/Open balances; team rotation and fee ownership. |
| `KeelFailurePaths.t.sol` | Sixteen malformed signed-attestation variants, unchanged pending state after rejection, subsequent fallback; exact expiry/skew boundaries; maximum offer; ERC-1271 and high-s signatures; unsigned failure authentication/replay; events; gas-exhausting NFT recipients; rejecting ETH recipients; malformed acquisition responses; definition escaping/length limits and exact NFT question. |
| `KeelLifecycleInvariant.t.sol` | Random bets, withdrawals, market changes, refunds, allocation, paid oracle requests/results/failures, bad signatures, time passage, fallback, depositor/finalizer resolution, sales, claims, fee claims, pauses and donations. |
| `KeelRevisionChecks.t.sol` | The revision's migration gate (`unresolvedShares`) across refunds back to Open, Spinning rounds, withdrawals, resolution and claims (fuzzed with 1–60 bettors); recovering a stuck NFT from the old pool after migration; stranded-release authorisation and zero-value refusals; strict timing bounds against the live window; refusing an answer at the cutoff when the oracle lead is zero. |
| `KeelBuilderInvariant.t.sol` | Random builder allowances, token claims, held-token queues, helper outages, minimum-output failures, next-block delivery, emergency ETH recovery, builder ETH withdrawals and contemporaneous bettor spins/refunds. |

The lifecycle campaign runs 128 sequences of 96 calls. Its independent ETH ledger records user inputs and counterparty receipts/payments; it does not derive expected solvency from `accountedETH`. It also checks that `unresolvedShares` equals the stake of every round that is neither AwaitingSale nor Settled. Other properties compare all actor shares, all round cash and fee liabilities, pending requests, terminal states, NFT custody and IMD expenditure. The explicit handler scenario exercises oracle keep/cashout, failure fallback, refund, external resolution and sale branches. After each random sequence, the handler resolves outstanding protocol requests, returns sale proceeds, and attempts every bettor/fee withdrawal.

The router campaign runs 128 sequences of 64 calls. It checks conservation of builder ETH, reward allowances and locked FWA; helper custody; one consumed Permit2 nonce per successful queue; closed signature authorization outside a queue; and independence from bettor ETH. Its final drain requires all simulated rewards to reach the team and all bettor ETH to remain withdrawable.

Both new campaigns use `fail-on-revert = true`; invalid inputs expected by the harness use explicit revert assertions. Their outer transaction sender is fixed to an unrelated test driver because Forge funds fuzz senders for gas. The actual bettors/operators vary inside the handlers. This avoids the test runner injecting untracked ETH into an application contract selected as sender. Tests do not change contract storage with `vm.store` or edit the shared environment.

Fuzz counts are inline: 512 refund-round-trip cases, 128 cases with up to 500 bettors, 128 malformed-attestation cases, 128 JSON round trips and 32 malformed acquisition responses. The seed is `0x742c30e652373c765963716e572266856c5215a4a7898aa0509e582b93fec513`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x742c30e652373c765963716e572266856c5215a4a7898aa0509e582b93fec513 forge test
```

Local validation with Forge 1.8.3: `forge build` succeeded; the full seeded suite passed 115 tests across 11 suites, with zero failures and zero skips. The two added invariant campaigns completed 20,480 handler calls with zero unexpected reverts.

The external boundaries were reviewed against the supplied FWA and oracle ABI/attestation references, the [verified FWAV2 source](https://sourcify.dev/server/v2/contract/1/0x958C41181182e76F221331b2755b77D9e1426A98?fields=all), and [FWAV2BuilderBase](https://github.com/adamlizek/fwa-examples/blob/main/FWAV2BuilderBase.sol). The shared pool mock models the settlement and refund interfaces, rather than live VRF selection, pool pricing or notifier execution. The reward mock uses a deterministic conversion rate rather than a Uniswap trade. Mainnet fork checks of those internals, live helper wiring and marketplace execution remain outside this offline suite. No confirmed application defect was reproduced by these additions.

## Reported, not asserted

`.imd-findings.json` reports two defects found in the revised vault, each with a failing proof test. They are not asserted as correct here:

- (medium) A kept NFT that FWA left stuck for the vault cannot be recovered once the team has settled the round through the 30-day stranded path, because `recoverStuckNFT` requires AwaitingSale.
- (low) With `minOracleLead = 0`, `requestDecision` at exactly `fallbackAt` still pays for an oracle question whose answer the callback must refuse.
