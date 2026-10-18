# Keel Spin

Ethereum mainnet contracts for small ETH bets pooled into one FWAV2 acquisition per round. `KeelSpinVault` owns the acquisition, refund credit and NFT settlement rights. `KeelFwaRouter` is the acquisition caller and earns FWA builder revenue.

## Build and checks

All Solidity dependencies are vendored as ordinary source files under `lib/`. No network, RPC, environment variables, submodules, FFI, filesystem permissions or secrets are needed to build or test.

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, via-IR optimization, and no bytecode metadata hash. The fuzz seed is `0x742c30e652373c765963716e572266856c5215a4a7898aa0509e582b93fec513`. Tests use protocol mocks and include the supplied oracle signature vector, the actual callback under a 200,000 gas stipend, stateful solvency invariants, and fuzzing with up to 500 distinct bettors. Mocks exercise asynchronous success and failure; they do not demonstrate production VRF or marketplace availability.

## Deployment parameters

Deploy these two contracts in order. Constructors are nonpayable, use only static address arguments, do not call dependencies, and assign ownership to the explicit owner argument. No proxy, linked external library, child deployment or deployment transaction is needed from this repository. The separate launch process supplies its manifest; this repository deliberately contains no `launch.json`.

1. `KeelSpinVault(owner_, fwa_, floorOracle_, intake_, imd_, signer_, teamWallet_)`:

| Argument | Ethereum launch value |
| --- | --- |
| `owner_` | `$owner`: `0x51a9ca901c0cb5c222d244b2ccb0ebfc5c9aba99` |
| `fwa_` | `0x958C41181182e76F221331b2755b77D9e1426A98` |
| `floorOracle_` | `0xaA4D9009a4664604b57644bF13e447E9036727DC` |
| `intake_` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` (Intake v2) |
| `imd_` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| `signer_` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, from the supplied oracle protocol reference |
| `teamWallet_` | `$owner` |

2. `KeelFwaRouter(owner_, vault_, pool_)`:

| Argument | Launch value |
| --- | --- |
| `owner_` | `$owner` |
| `vault_` | `$contract:KeelSpinVault` |
| `pool_` | `0x958C41181182e76F221331b2755b77D9e1426A98` |

The owner must call `vault.setRouter(router)` after both are deployed and **before anyone bets**. Until then, betting and spinning revert `NotConfigured`, so a premature bet cannot block initial wiring. The intentionally unset router is not a constructor placeholder: the brief requires this deployment order and setter.

## After launch

- Confirm the published dependency addresses, oracle signer, live FWA settings and oracle price before accepting funds. `setFwa`, `setRouter`, and router `setPool` support migrations only while no bettor shares remain outstanding. Configure pool changes in the vault and router together, then check the router wiring. This prevents the owner from redirecting already funded bets to another acquisition contract.
- Transfer IMD into the vault. Each paid question uses exactly 0.5 IMD initially, separate from bettor ETH. `imdBalance()`, `needsImdTopUp()` and `LowImdBalance` support monitoring. The event is emitted when a request observes less than 2 IMD, including after paying. Insufficient IMD leaves the allocation retryable and the deadline fallback available.
- Configure `router.setTransferHelper(address)` with the **current mainnet FWATokenTransfer helper published by FWA**, verifying its `token()` and `permit2()` wiring and enabled distributor status. The brief does not name that helper; it is an owner-set storage setting, not a guessed constructor argument. Reward claims revert `NotConfigured` until set. Bets and settlement do not depend on it.
- Review the live settlement window against `safetyMargin` and `fallbackLead`. Keepers must observe allocations and act promptly. The supplied FWA reference reports a one-hour window, while the verified source's initializer says 24 hours; neither is hardcoded as the live setting. All deadlines read `settlementWindow()` on chain.
- Arrange team NFT custody, sale execution and return of the **entire actual ETH sale proceeds**, with a transaction hash for the event. The contracts cannot make the team sell an NFT or prove the truth/completeness of a reported off-chain sale.
- Have an independent contributor review the final contracts before accepting public funds. The local adversarial tests and review described in `docs/SECURITY.md` are not an independent audit.

## Rounds and accounting

`bet()` accepts at least 0.001 ETH and fills the current Open round to the live target. Remainders continue into subsequent Open rounds, including fragments smaller than the transaction minimum. Each round has at most 500 current bettors. A full participant list sends a new bettor to the next round; existing bettors can still add to their round. One call can visit at most 32 rounds, bounding work; larger bets revert atomically.

```text
reward = min(configured spinReward, live total quote / 50)
liveTarget = floor(total quote * (10000 + bufferBps) / 10000) + reward
```

The quote includes FWA's pool fee and VRF service fee at `tx.gasprice`. Quote previews must specify the intended gas price. A target-filled round stays **Open**, so it never locks at a stale price. `betInto(roundId)` tops up an older Open round after a price rise or refund. `withdraw(roundId)` and `withdrawTo(roundId, recipient)` redeem all of the caller's shares while Open, even when betting is paused.

Anyone can call `spin(roundId)`. It reads a new quote in that transaction, checks that round's cash against quote plus reward, checks the gas cap and both UTC blackouts, and sends only the quoted total to the router. It does not require the buffer to be filled. The router names the vault as purchaser, buys exactly one draw, uses the quoted **pool fee** as `maxAcquisitionFee`, and passes the configured value/slippage guards. Immediate acquisition overpayment is returned to that round. The caller receives the capped reward. A rejecting caller can use a different keeper; a failed payment reverts the whole spin.

There is **one unresolved FWA request at a time**. FWA sends purchaser ETH without a request/listing identifier and keeps aggregate refund credits, so this restriction permits unambiguous reconciliation, including depositor-initiated payouts and forced ETH. Other rounds can remain Open, and any number of resolved NFT rounds can await sale. Once the active round resolves or refunds, another may spin.

Chainlink VRF and FWA's ordered processing choose the NFT, using FWA's backing-weighted distribution. Keel does not generate randomness or select a bettor as winner: every bettor owns a proportional share of the round's eventual ETH. Anyone can call FWA `processAcquisitions(maxCount)` to progress Ready/TimedOut requests and then `vault.syncRound(roundId)`.

Refunded/Expired requests claim FWA's refund credit and return to Open. The spent VRF fee **and the already paid keeper reward** reduce the cash backing existing shares pro rata. Shares do not reset: subsequent entrants buy at the remaining cash/share price, so they cannot extract another bettor's refund or transfer the earlier loss to new bettors. The pool fee refund, buffer and immediate overpayment stay with the round. An unsolicited acquisition refund credited to the vault is a donation to the currently refunded round; there is no claim for an outsider who named this vault as purchaser without betting.

## Decision and deadlines

`syncRound` records the selected listing. `requestDecision(roundId)` first reads `getFloor(collection)` and the live `settlementDiscountBps()`:

```text
ethBid = floor(backing * settlementDiscountBps / 10000)
haircutFloor = floor(floorPrice * (10000 - haircutBps) / 10000)
```

A missing, zero, future-dated, reverting, or more than 24-hour-old floor is unavailable. If a fresh haircut floor is at least three times the bid, the vault keeps immediately. Otherwise it requests a uint256 net-offer valuation, unless the fallback time has already arrived or the oracle has failed. It never pays for another question after a failure for the same allocation.

The on-chain JSON uses chain 1, version 1, panel evidence, a one-hour window, 5 seats, quorum 4, tolerance 500 bps, validity 3,600 seconds, and decimal-string bounds 0 through 1e22 wei. It asks exactly:

> What is the highest live offer, in wei, that the owner of <collection> token <tokenId> could accept right now, after marketplace fees and creator royalties?

Four owner-set definitions specify token/collection/trait offers, WETH, excluding offers expiring within two hours, OpenSea/Blur/CryptoPunks sources, net enforced fees/royalties and answering zero when no offer exists. Definitions are 1–511 printable ASCII bytes and are JSON escaped. The router renders the body through a pure function; the vault remains the Intake callback target and EIP-712 verifying contract.

`onOracleResult` accepts only the configured Intake, a pending local Intake request id, the canonical signed 15-field attestation, chain 1, uint256 answers, sufficient signed panel/quorum/agreement, freshness, bounds and a previously unused oracle UUID. **The Intake id and oracle UUID intentionally differ.** The signature uses domain `IdentityMD Oracle`, version `2`, the actual chain id and this vault. It stores only the offer and expiry. New values are rejected at or after `fallbackAt`, so a late delivery cannot revoke the fallback right. It does not transfer NFTs or settle ETH. `onFailure` similarly only records failure and clears the pending request. Unknown, stale, forged and replayed callbacks revert.

Anyone calls `executeDecision` for a still-valid stored value. Keep only if `netOffer * 10000 > liveEthBid * (10000 + marginBps)`; equality takes ETH. An expired value cannot be executed.

```text
decisionDeadline = allocatedAt + max(settlementWindow - safetyMargin, 0)
fallbackAt = max(allocatedAt, decisionDeadline - fallbackLead)
```

The saturating rule is intentional: with a one-hour live window and a two-hour safety margin, fallback becomes available **immediately at allocation**, and a non-obvious `requestDecision` uses it without spending IMD. This avoids arithmetic underflow or pretending there is time for an oracle panel. If the owner wants oracle evaluation during a shorter live window, reduce the two timing settings before operation.

Anyone can `settleFallback` after failure, or at/after `fallbackAt` when no unexpired stored answer exists. At `decisionDeadline` fallback is always allowed so an unexecuted answer cannot lock settlement. A fresh haircut floor must be strictly greater than the margin-adjusted bid to keep; without a fresh floor the default is keep. The vault can still resolve after its own deadline while FWA remains Allocated; no artificial hard stop prevents a late keeper saving the round.

If the depositor or FWA's finalizer resolves first, `syncRound`, `requestDecision`, `executeDecision` or `settleFallback` recognize the terminal listing and reconcile what actually arrived. FWA's automatic NFT delivery uses `transferFrom`, so the implementation does not rely exclusively on a receiver callback. A stuck NFT owed to the vault is treated as AwaitingSale and can be recovered with `recoverStuckNFT(roundId)`. No path calls FWA's token cashout or relist functions.

## NFTs, sales and payouts

Keeping records a `Decision` event with the collection, token id, ETH bid, stored net offer (zero when none), keep choice and path. The vault receives the ERC-721 and attempts a bounded safe transfer to `teamWallet`. A rejection leaves custody in the vault and emits `NFTForwardPending`; anyone may retry `forwardNFT(roundId)` after the team can receive it or the owner changes the recipient. The round becomes AwaitingSale. Sale settlement requires that forwarding succeeded.

Only the current `teamWallet` or owner may `depositSaleProceeds(roundId, saleTxHash)` with positive ETH and a nonzero sale hash, once. This emits `SaleProceeds` and settles the round. An ETH-bid outcome settles immediately when reconciled. Fees are initially zero, capped at 300 bps and snapshotted with the fee beneficiary when the round is created (empty current rounds can be updated). **Fees apply to the ETH bid or sale proceeds, never to the unused buffer or acquisition refund.**

Bettors pull `claim(roundId)` or `claimTo(roundId, recipient)`. Each claim burns the bettor's shares against the remaining cash and share supply. Integer dust stays with remaining bettors; the final claimant receives the remainder. The team pulls fee credits with `claimFees(recipient)`, so a rejecting fee recipient cannot block bettors.

`accountedETH` equals all round cash plus unclaimed fee credits. It excludes ETH already spent with FWA and rewards. A minimal `receive()` permits FWA's stipend/forced transfers; after a terminal FWA outcome, any unaccounted ETH belongs to the resolving round. Unsolicited ETH is therefore a donation, not an owner-withdrawable balance. The vault exposes no ETH sweep, arbitrary call, relist or NFT transfer to an arbitrary user.

## Defaults and administrative powers

| Setting | Initial value | Owner setter |
| --- | --- | --- |
| Minimum transaction bet / bettors / target buffer | 0.001 ETH / 500 / 500 bps | `setBetParameters` |
| Keeper reward / maximum gas price | 0.002 ETH, capped live at 2% / 100 gwei | `setSpinParameters` |
| Minimum weighted pool value / negative slippage | 0 (guard disabled) / 500 bps | `setSpinParameters` |
| Floor haircut / offer margin / maximum floor age | 1500 bps / 500 bps / 24 hours | `setDecisionParameters` |
| Safety margin / fallback lead / missing-floor choice | 2 hours / 1 hour / keep | `setDecisionParameters` |
| Fee | 0 bps, maximum 300 | `setFeeBps` |
| Oracle action / payment / low-balance threshold | `oracle.request@oracle-1` / 0.5 IMD / 2 IMD | `setOraclePayment` |
| New bets paused | false | `setBetsPaused` |
| External integrations and team | constructor table above | `setFwa`, `setRouter`, `setFloorOracle`, `setIntake`, `setIMD`, `setOracleSigner`, `setTeamWallet` |
| Valuation definitions | text described above | `setDefinition(index, text)` |

The owner may withdraw **IMD only**, with `withdrawIMD`, and may change decision policy/floor feed/team. Timing and floor/margin policy changes affect unresolved allocations; monitor these events. Intake, signer, IMD asset and oracle payment settings cannot rotate while a spin is unresolved. FWA/router replacement is stricter: all bettor shares must first be withdrawn or claimed. Pausing affects new bets only. Ownable supports explicit ownership transfer and renunciation; renouncing abandons all configuration and IMD/reward withdrawal powers.

The owner claims router builder revenue with `claimBuilderRewards(minFWAOut, deadline)`. Following `FWAV2BuilderBase`, rewards buy FWA, and the router grants a one-call, exact-digest ERC-1271 authorization to canonical Permit2 for the configured helper to queue tokens to the current team. Anyone calls the helper's `claim(teamWallet)` starting the next block. This is builder income, separate from the purchaser's NFT decision; it never chooses the FWA token cashout for a round. Direct FWA transfers between ordinary accounts are intentionally not used. Emergency builder ETH recovery only works when FWA permits it and goes to the team. Purchaser epoch token rewards are outside this implementation's payout model.

See `docs/SOURCES.md` for verified integration provenance, `docs/SECURITY.md` for trust boundaries, and `docs/VALIDATION.md` for the final local check results.
