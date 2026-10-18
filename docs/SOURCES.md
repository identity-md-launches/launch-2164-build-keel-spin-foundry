# Integration sources

The application ABI subsets were compared with the verified mainnet sources retrieved through [Sourcify's contract API](https://docs.sourcify.dev/docs/api/). Source hashes and verification match classifications are recorded in [verified-sources.json](verified-sources.json). An explorer fetch was unavailable, so the integration review used Sourcify rather than assuming function names from prose.

| Dependency | Verified source |
| --- | --- |
| FWAV2 | [Mainnet source](https://sourcify.dev/server/v2/contract/1/0x958C41181182e76F221331b2755b77D9e1426A98?fields=all), compilation target `src/FWAV2/FWAV2.sol:FWAV2` |
| CollectionFloorOracle | [Mainnet source](https://sourcify.dev/server/v2/contract/1/0xaA4D9009a4664604b57644bF13e447E9036727DC?fields=all), `src/FWAV2/CollectionFloorOracle.sol:CollectionFloorOracle` |
| Intake v2 | [Mainnet source](https://sourcify.dev/server/v2/contract/1/0xa43e6f75ee006411f79ac1c84120606c2330de82?fields=all), `src/Intake.sol:Intake` |
| IMD | [Mainnet source](https://sourcify.dev/server/v2/contract/1/0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7?fields=all), `src/BridgedFP.sol:BridgedFP` |

Specific integration findings:

- FWA `quoteAcquisitionPrice()` includes `vrfService.requestFee()`, which depends on transaction gas price. `acquire` can drain staged listings and re-price inside the call. The router forwards the exact quote, bounds the pool fee, and immediately returns any actual overpayment.
- Acquisitions use statuses None=0, Pending=1, Fulfilled=2, Expired=3, Refunded=4, Ready=5, TimedOut=6. Ready/TimedOut require ordered processing before reconciliation. The refund is `priceEscrowed`; the VRF service charge is already spent.
- Listing status Allocated=2, Settled=4. Purchaser resolution remains callable while Allocated, even after the exclusivity window. Depositor reclaim and public finalization can resolve first.
- Explicit `keepNFT` uses `safeTransferFrom`. Automatic delivery and stuck recovery use `transferFrom` plus an ownership check. FWA can force-send ETH if a receiver rejects its transfer. These facts motivate terminal-state/custody/balance reconciliation and the single unresolved acquisition restriction.
- CollectionFloorOracle's method is `getFloor(address) returns (uint256 price, uint48 observedAt)`. The timestamp is the challenge observation time or an owner override, not necessarily a recent finalization transaction. Keel checks it rather than trusting the call time.
- Intake v2's callback is `(bytes32 intakeRequestId, OracleAttestation.Attestation, bytes signature)` and its failure selector has six arguments. It pulls the configured ERC-20 payment and gives each callback 200,000 gas. The exact 15-field attestation implementation was copied from the supplied canonical reference. The unchanged cross-implementation digest/signature vector is tested in `test/OracleConformance.t.sol`.

Builder reward custody adapts [FWAV2BuilderBase.sol](https://github.com/adamlizek/fwa-examples/blob/main/FWAV2BuilderBase.sol), including its exact Permit2 type hashes and scoped ERC-1271 authorization. Its immutable constructor-time external calls were replaced with static constructor inputs, owner-set helper wiring and validation on use, as required for this deployment. The router only purchases for the vault, returns round refunds synchronously, and fixes every reward recipient to the vault's current team wallet. It grants no general token approval or arbitrary call mechanism. The [builder example documentation](https://github.com/adamlizek/fwa-examples) explains FWA's locked token and next-block transfer helper.

The public [IMD oracle body specification](https://imd.fun/docs/#oracle-body) confirms decimal-string uint256 bounds and the relative-window semantics. A free `POST https://api.imd.fun/requests/check` with the exact question template instantiated for the CryptoPunks market address and token 1 returned **no blockers**. [oracle-preflight.json](oracle-preflight.json) retains the request and relevant response. The shortened preflight input does not include the full definitions; its response also contained wording, answerability and evidence suggestions. This is not a promise that any particular NFT has publicly accessible executable offers or that a future request will succeed. The shipped definitions, zero-if-missing rule, signed value checks and deadline fallback address those operational cases.

No state-changing mainnet transaction, fork test, mainnet signer operation or live marketplace purchase was performed. Current live owner-set protocol values and transfer-helper deployment must be checked by the launch operator; source verification alone does not establish their current values.

## Vendored software

- [OpenZeppelin Contracts v5.5.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.5.0), MIT: source dependency closure under `lib/openzeppelin-contracts/contracts`, license in `lib/openzeppelin-contracts/LICENSE`.
- [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7), MIT / Apache-2.0: test dependency closure under `lib/forge-std/src`, licenses in `lib/forge-std/`.
- `KeelFwaRouter` is adapted from the MIT-licensed upstream builder example identified above. `OracleAttestation.sol` is the MIT-licensed canonical source supplied with this assignment; only its imports/formatting are adapted.

The pinned eth-security, eth-addresses, oracle-consumer and fwa-v2 inputs were read as protocol/review reference data. Application requirements and their deployment restrictions take precedence over examples that assume a different deployment mechanism.
