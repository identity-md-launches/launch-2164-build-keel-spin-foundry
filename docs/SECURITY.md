# Security and operational review

## Invariants and trust boundaries

`accountedETH` is the sum of every round's cash plus all pending fee credits. Each ETH outflow reduces its corresponding cash/share/credit liability before the call. Failed payments revert that reduction. Spending a quote or reward debits only the selected round. Refunds are recognized from an actual balance increase; terminal FWA payouts are recognized from surplus ETH after the protocol confirms resolution. This includes ETH transfers that bypass `receive()`.

Only one request can be unresolved because the live protocol's plain ETH transfers and aggregate refund credit have no per-round callback metadata. An NFT round releases that slot once it is resolved, even if the team has not sold it yet. Concurrent Open and AwaitingSale rounds retain separate balances and shares.

An Open withdrawal and a Settled claim burn all caller shares against the remaining cash/share ratio. On refund, unchanged shares absorb costs pro rata; minting new shares against remaining cash prevents cross-subsidies between old and new bettors. Direct donations cannot alter share minting and cannot be withdrawn by the owner. Rounding dust remains with bettors.

The owner has no ETH sweep or arbitrary external call. FWA and purchase-router replacement require all bettor shares to be gone. All ordinary value-moving functions hold a reentrancy guard; callbacks that must run inside FWA settlement only authenticate/return, while oracle callbacks only update the request's result. Pool, token and Intake callbacks cannot create a second spin. Team fee withdrawals are pull-based and separate from bettor claims.

External trust still matters:

- FWAV2, its chosen NFT collections, Chainlink VRF/service and protocol governance control acquisition, allocation and settlement. A protocol outage can delay resolution; the vault cannot fabricate a VRF fulfillment or seize backing directly.
- The CollectionFloorOracle permits trusted owner overrides. A fresh floor is a rough collection estimate, not proof of a sellable token offer. The immediate keep path intentionally uses the requested 3x threshold and haircut.
- An oracle signer plus the Intake writer bind a result to this contract's paid request. Relative windows prevent precomputing the exact question hash. The consumer relies on the writer's pairing of its own pending Intake id, and independently checks signature domain, chain, type, panel, agreement, UUID replay and time validity. A valid signature does not guarantee an economically accurate offer.
- The team receives custody of kept NFTs. Sale execution, timely repayment and truthful proceeds reporting are contractual/social responsibilities, not enforceable marketplace automation. `saleTxHash` is an audit reference, not on-chain proof of sale. AwaitingSale has no confiscation, forced sale or user-funded bailout mechanism.
- The owner can change the team, feed and decision policy, pause new bets and withdraw IMD. Those powers can affect outcomes or oracle availability; they cannot sweep escrowed bettor ETH. The owner and team should operate secure custody and monitoring. Intake/signer/payment rotation is unavailable until the active spin resolves.
- If FWA's window is shorter than safety margin plus lead, oracle evaluation may be unavailable by design. The immediate fallback is the safe liveness policy for that case. A missed deadline exposes the round to the protocol's depositor/finalizer choices.
- No-value/expired market offers, unavailable marketplace APIs, unavailable IMD and oracle non-delivery are normal fallback cases. A keeper transaction is still required; Solidity cannot schedule itself.

## Review performed

The implementation was reviewed locally for authorization, custody, time boundaries, reentrancy, cross-round cash attribution, refunded-round share dilution, callback replay and dynamic protocol parameters. The supplied deployment-probe logic is reproduced against both applications: code is present, runtime is at most 24,576 bytes, and the compiled bytecode scan finds no DELEGATECALL, CALLCODE or SELFDESTRUCT. Constructors were exercised through a factory with absent dependency code and the explicit launch owner. The Solidity optimizer is pinned to preserve these deployment properties.

The offline tests cover:

- Carry-over and tiny remainder fragments; minimum bets; bounded carry-over; 500-member capacity; price and gas-dependent VRF changes; Open withdrawal; blackout boundaries; quote failure atomicity; live reward cap and guard forwarding.
- Immediate overpayment, fee refunds, expiry/timeout processing, retry shares, pro-rata VRF/reward loss, dependency replacement restrictions and independence of unrelated rounds.
- Fresh/stale/future/reverting floors; obvious keep; exact oracle JSON and escaping; IMD top-up behavior; price mismatch; true/false valuation decisions; strict equality; live bid discount changes.
- Canonical oracle digest, original protocol signature, canonical callback selector and a uint256 callback under 200,000 gas; bad signatures, wrong domains/chains/types, weak panels, expired/future values, unknown/non-Intake callbacks, duplicate delivery and cross-request UUID replay.
- Failure fallback, missing-value deadline, stored-value expiry, pending-request clearing, one-hour settlement windows and post-deadline liveness.
- Depositor reclaim before sync and during a pending oracle request; public finalizer delivery without receiver hook; stuck NFTs; failed keep retry; failed team transfer and later recovery.
- Authorized once-only sale proceeds; proportional payout; fee caps/snapshots; buffer exemption; rounding dust; rejecting ETH recipients; reentrant withdrawal and claim; owner inability to withdraw bettor cash.
- Builder reward transfer restrictions, exact scoped Permit2 authorization, next-block helper payment, helper failure atomicity, min-output/deadline limits and emergency builder-only ETH recovery.
- Stateful random sequences of bets, price changes, withdrawals, spins, allocations, refunds, decisions, sales, fee claims and bettor claims. The assertions compare all tracked shares and cash with the ledger and actual ETH, and specifically require claimable plus Open balances not to exceed vault ETH.

These checks use mocks and local review. No independent security audit, Slither/Mythril analysis, economic oracle validation, production VRF test, live helper validation or marketplace execution is claimed. An independent review remains a launch responsibility.
