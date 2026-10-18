# Keel Spin interface revision validation

This revision preserves the existing app, contracts, chain configuration, dependencies and visual tokens. It addresses the four supplied findings in the shared history button, transaction notice, round timeline and history read states. Source is in `web/`; the production export is `dist/`. Checks below ran locally on the final application source on 2026-10-18. They are worker evidence, not independent certification.

## Findings reproduced and corrected

| Finding | Reproduction on the original export | Final behavior and source |
| --- | --- | --- |
| `6f8d7f…` accessible history names | Chromium 360×800, `/?demo=1#history`: explicit axe `label-content-name-mismatch` scan reported 25 buttons; first visible label included sample collection #8031, but its name was `view round 31, sold`. | Removed the overriding `aria-label` at `web/src/App.tsx:1103`. Visible NFT, token, round and outcome text now name the button. Zero violations of that rule in the 25-row history and the recent-spin feed. |
| `d84778…` pending-payment dismissal | Chromium 390×844, original transaction fixture with receipt withheld: before dismissal, one send and disabled submit; after dismissal, no notice and enabled submit; a second click produced a second send. | Native dismissal is disabled during simulation/pending at `web/src/App.tsx:1074`. Regression checks hold simulation and receipt separately, attempt dismissal and another payment, and retain the progress notice, explorer link and lock. Confirmed/failed notices remain dismissible. |
| `7c3dbd…` raw timeline values | Round #31 showed bet `20000000000000000`, quote `90000000000000000`, sale `130000000000000000`, a Unix deadline, and state/path numbers. | `eventAmounts`/`EventValue` at `web/src/App.tsx:1161` format monetary fields by event, deadlines/expiry with `Time`, and state/path with shared labels (`web/src/model.ts:240`). Browser assertions verify 0.02 ETH, 0.09 ETH, 0.13 ETH, the oracle value/expiry, full IDs/hashes/addresses and exact UTC hover text. Future timestamps use a countdown. |
| `4a8de6…` outage shown as empty history | Fresh context, both supplied public RPC URLs return JSON-RPC error `-32000`: original export said 0 spins, No spins recorded yet, a quiet start, and no spins here yet. | Successful snapshots gate empty copy and numeric counts (`web/src/App.tsx:145`, `:711`, `:766`, `:800`). An initial error shows unavailable history/latest spin, an unknown count and retry guidance. Retry makes another RPC request. Separate tests confirm a successful empty read still shows zero, and a later outage keeps that last successful snapshot with its warning. |

Full finding IDs and verdicts are in `../.imd-responses.json`.

## Commands and actual results

Browser checks used the served production `dist/`, not the Vite development server. Optional tools were installed outside the repository under `/tmp/keel-checks`: Playwright 1.64.1, axe Playwright 4.14.0 and Lighthouse 13.5.0. Chromium was installed under `/tmp/keel-browsers`. No tool dependency or cache is delivered.

| Command/check | Result |
| --- | --- |
| `npm ci --prefix web --cache /tmp/keel-npm-cache --no-audit --no-fund` | Passed using the existing lockfile; peer/deprecation/install-script warnings. Manifest and lockfile unchanged. |
| `npm --prefix web run typecheck` | Passed, including a final separate run. |
| `npm --prefix web test` | 17 model tests passed: funding/gas/blackout boundaries, decision predicates, all fixture outcomes/paths, exact claims, retries and event ordering. |
| `npm --prefix web run build` | Passed (`tsc --noEmit` and Vite 6.4.1). Dependency annotation warnings were nonfatal. Relative static assets generated in root `dist/`. |
| `forge build --out test/scratch/contracts --cache-path test/scratch/foundry-cache` | Passed, preparing existing contract bytecode for the RPC fixture. Solidity lint warnings; no Solidity/configuration changes. Contract tests were not rerun in this interface revision. |
| `node web/tests/interface.browser.mjs …` | All 35 checks passed: public-chain reads without a wallet, first-screen action, wallet sheet, pagination/filters, exact fixture claim amounts, trust view, responsive tabs and reduced motion. Full live-page axe scan: zero violations; no uncaught page errors. |
| `node web/tests/revision.browser.mjs …` | All 45 checks passed: semantic row names, timeline values and identifiers, keyboard open/Escape/focus restoration, filters, unknown loading/error counts, retry and latest/recent unavailability. Explicit visible-label scans: zero violations. Default axe scans scoped to `main`: zero violations in history and recent spins. |
| `web/node_modules/.bin/tsx web/tests/transactions.browser.mjs …` | All 12 transaction/read-state checks passed. Simulation before sending, locked simulation/pending notices, exact contract claim values, confirmation/refresh, claim/spin selection, cancellation, decoded simulation errors, successful empty reads and retained snapshots after failure. Three mocked sends total; no broadcasts. |
| Pinned `taste.mjs --out test/scratch/taste` | 16/16 passed. No missing local assets/script errors, horizontal overflow, overlapping/clipped text, or contrast failures among the measured first-screen pairs. Share metadata present. Three controls below the comfortable 44px size satisfy the probe's minimum target/spacing check. |
| Lighthouse, mobile production entry page | Accessibility 100/100, no failing audits. The CLI's default Chrome launcher failed waiting for a debugging port; rerunning Lighthouse against Playwright-managed Chromium on CDP port 9222 succeeded. The scratch harness called `lighthouse(url, {port: 9222, onlyCategories: ['accessibility']})`. |
| Static subpath check | Served the complete export under `/preview/`: sample round, 25-row history and keyboard detail open/close worked; zero missing local resources and zero page errors. |
| Delivery byte check | Retained source/export and response JSON total less than 4.5 MiB before packaging, below the 8 MiB limit. The complete export has 93 files totaling 2,770,447 bytes. No dependency/cache directories or npm archives appear in submission candidates. |
| `git diff --check` | Passed. |

The browser commands use the module arguments documented in the README and `PLAYWRIGHT_BROWSERS_PATH=/tmp/keel-browsers`. The probe used `IMD_PLAYWRIGHT=/tmp/keel-checks/node_modules/playwright/index.mjs`. The existing interface test read current round #1 from the public RPC without signing; the live app still reported incomplete router setup. Its deposit action ended at y=579.375 on the 390×844 first screen.

## Better Interface review

Read the pinned workflow and the core principles of all six domains. Review covered the changed surfaces and their shared components, preserving the forest palette, Arial stack, six-size scale and existing density. `DESIGN.md` records the final component behavior.

| Domain | Source and rendered coverage | Findings and disposition |
| --- | --- | --- |
| Accessibility | Native history buttons, visible names, disabled dismissal, labelled controls, keyboard Enter/Escape and focus restoration; axe scans described above. Viewed the keyboard-focus screenshot. | Repeated label mismatch fixed at `App.tsx:1103`; existing two-pixel focus ring retained. |
| Layout | All four tabs at 320, 360, 390, 760 and 1440px; detail sheet at 360px; first-screen action at 390px; `/preview/` relative assets. Viewed mobile, desktop, timeline and outage screenshots. | No horizontal overflow in these checks. Existing grid, mobile tabs and sheets retained. |
| Writing | Read status/action/error copy and compare event labels with the source event meanings. | Raw units/enums and false empty-history claims fixed at the locations above. Unavailable data directs the reader to retry. |
| Typography | Reused `Amount` and `Time`, tabular numbers and existing scale; checked long addresses/hashes and timeline wrapping at 360px. | Monetary values use four significant digits and exact amount hover values. IDs remain complete; relative timestamps retain exact UTC titles. |
| Colors | Existing semantic tokens and solid backgrounds reviewed; pinned rendered contrast probe and live Lighthouse/axe scans run. | Probe passed for measured text pairs. No palette changes or unmeasured contrast ratios claimed. |
| UI | Checked simulation, pending, confirmed, failed, loading, unavailable, verified empty, retained snapshot and populated states. Reduced-motion reveal tested. | Pending dismissal fixed; successful/failed notices still dismiss. Existing surfaces, fawn, icon treatments and motion preserved. |

Worker screenshots/results were written to `test/scratch/`, which the assignment removes before submission: `revision-mobile.png`, `revision-desktop.png`, `revision-timeline.png`, `revision-deadline.png`, `revision-unavailable-latest.png`, `revision-focus.png`, `revision-results.json`, `transaction-results.json`, `browser-results.json`, `lighthouse.json` and the pinned probe output. These transient files are not runtime dependencies.

## Limits

- Full-page demo-mode axe also reports the existing preview banner outside a landmark (`.preview-banner`, rule `region`). It is outside the changed components; main-content scans and the full live entry-page scan pass. This revision does not claim a globally clean demo-mode axe scan.
- WebKit could not launch because its browser runtime was unavailable. Safari/native-wallet-device, screen-reader, browser-native 200% zoom, RTL, forced-colors and slowed-animation checks were not performed. Narrow viewport checks do not establish those results.
- Pending/success/failure transaction tests use explicit wallet and RPC mocks. No mainnet transaction, external wallet approval, WalletConnect relay or team sale was signed/tested. Live contract setup remains the owner's responsibility.
- Production runtime assets and the existing source/lockfile remain complete. Dependency/cache trees and scratch output are excluded. No ignore file, Solidity dependency, build configuration or submodule was changed.
