# Keel Spin design

## Overview

Keel Spin is a compact Ethereum pool interface for bettors and permissionless keepers. A near-black page, forest surfaces, pale leaf controls and silver text carry the requested calm forest character. The round and deposit control lead the page; explanation follows the product. The brief supplied no actual hex values or font names, so the tokens below are implementation choices.

Source: `web/src/style.css`; composition: `web/src/App.tsx`. The chrome fawn and silver leaf shield are small original SVGs in `web/src/components/Icons.tsx`, used in empty states and allocation reveals. There is no downloaded font or remote decorative image.

## Colors

| Token | Value | Role |
| --- | --- | --- |
| `--page` | `#0b110e` | Page and input background |
| `--surface` | `#131d17` | Round, latest-spin panel, mobile navigation, dialogs |
| `--surface-raised` | `#1b2a20` | Hover, selected navigation and secondary status surfaces |
| `--forest` | `#213c2a` | Pool mark, placeholder art, spin action |
| `--text` | `#edf2ed` | Primary text |
| `--muted` | `#a6b3a9` | Secondary text and units |
| `--leaf` | `#bfdda9` | Primary action fill, interactive accents, funding progress |
| `--leaf-hover` | `#cde8ba` | Primary hover |
| `--ink` | `#162213` | Text on the pale primary action |
| `--line` | `#304135` | Dividers and control borders |
| `--warning` | `#e3c48b` | Setup, connection and IMD warning text |
| `--error` | `#f1a6a0` | Validation and transaction failure text |
| `--focus` | `#d9eccb` | Two-pixel keyboard focus outline |

Warnings use a separate dark amber background, `#211f15`. Status always includes words. The final probe measured rendered first-screen contrast against its actual solid backgrounds; all measured pairs passed its WCAG AA thresholds. Lighthouse and axe results and limitations are recorded in `docs/WEB-VALIDATION.md`. This is a dark-only interface; an unrequested light theme is deliberately absent.

## Typography

Arial, Helvetica, sans-serif, with weights 400 and 600. The local system font stack avoids font loading and layout shifts. The six-size scale is `--sm:12px`, `--body:14px`, `--control:16px`, `--heading:20px`, `--title:32px`, `--display:36px`.

Body line height is 1.5; headings use 1.15–1.4. Main title tracking is −0.035em; headings −0.02em. Labels retain normal spacing. Inputs are 16px, including on phones. Prices, progress, timers and addresses use tabular numerals. Amounts ordinarily show four significant digits; claim values use the exact `formatEther` string, including all nonzero wei digits. Long addresses and event values wrap, and full contract addresses remain available in links and round details.

## Layout

The desktop shell is at most 1120px, with 40px inline padding and a 100px header. The main spin view uses two columns at a 1.08:1 ratio, separated by 24px. Panels have 26px padding. The shared spacing steps are 4, 8, 12, 16, 20, 24, 28, 32, 40 and 56px, chosen for compact data grouping.

At 900px the inline margin becomes 24px and panels use 22px padding. At 760px and below the layout becomes one column, the shell uses 20px margins, panels use 20px padding, and desktop navigation becomes four mobile bottom tabs. A scrollable shell reserves 68px plus the bottom safe area for these tabs, so they cannot cover the spin control. Small phones at 370px and below use 16px margins and 18px panel padding. At this width the redundant Ethereum header label is hidden; chain identity remains in wallet and info controls.

Mobile history rows wrap outcomes below the NFT name. Info stats and live settings use two columns; explanation and trust sections stack. Claim amounts and full addresses wrap rather than truncate. Dialogs become bottom sheets on phones. The supported layout was checked at 320, 360, 390, 760 and 1440px; the main action was checked on the 390×844 first screen.

## Elevation & depth

Surfaces are flat, with tonal separation and structural dividers. There are no panel shadows or glow effects. Native modal dialogs use a dark, blurred backdrop and browser-managed top-layer stacking. Mobile navigation is above the scrolling shell; transaction notices sit above navigation. There are no nested decorative cards.

## Shapes

Panels use 16px corners; controls 8px; metadata badges 5px; NFT thumbnails 7px; full artwork 10px. Desktop dialogs use 16px corners, mobile sheets 18px top corners. The pool leaf and step numbers use circles. Image fitting uses contain, preserving the original NFT image.

## Components

- `Amount`, `Time`, `ELink` in `App.tsx`: consistent monetary display, relative time with exact UTC on hover, and Etherscan transaction links.
- `HistoryRow`: a native button opens the detail sheet and takes its accessible name from the visible NFT, token, round and outcome text; separate sale and explorer links remain independent. Decision path, cost, outcome and return share a stable row structure. Each acquisition attempt has a distinct row keyed by its transaction and log index; a refund followed by another spin never collapses into one entry.
- `RoundDetail` and `EventValue`: complete round event timeline with every decoded argument, transaction hash link and block. Event-specific ETH fields reuse `Amount`, deadlines and oracle expiry reuse `Time` (past relative time or future countdown, exact UTC on hover), and vault state/decision path values use shared plain labels. Token/listing/request IDs, addresses and hashes keep their full values.
- `Empty`, `Fawn`, `NFTArt`: restrained empty/loading visuals and local fallback art. History and latest-spin empty copy requires a successful snapshot; an initial connection error shows unavailable copy and an unknown history count. NFT metadata is never required to navigate or claim.
- `Dialog` in `components/Dialog.tsx`: native `showModal()`, inert background, Escape and backdrop close, initial focus and focus restoration.
- `WalletControl` and `WalletSheet`: one header control, named EIP-6963 providers first, generic browser provider when needed, mobile wallet-browser links and Coinbase. WalletConnect appears only with a build-time project ID. Mobile injected providers stay available.
- `.button.primary`: the deposit action; `.button.spin-button` and `.button` are secondary. Controls define hover, focus, pressed, disabled and pending states. Native progress and labelled input elements carry semantics.
- `.tx-status`: persistent simulation, pending, confirmed and failed feedback with a transaction link when known. Dismissal is disabled during simulation and pending confirmation, preserving the payment lock and progress link. Confirmed or failed notices can be dismissed. Errors use plain recoverable messages.

A short allocation reveal uses opacity and an 8px translation over 550ms. Pressed buttons scale to 0.96 only with no reduced-motion preference. The reduced-motion rule removes animations and transitions. No animation repeats indefinitely.

## Do’s and don’ts

Reuse the shell, section header, amount formatter, native controls and existing tokens when adding a view. Keep one filled primary action, group live numbers before explanatory copy, and keep the first phone screen focused on the round. Use the same path labels and outcome terms throughout. Preserve full exact claim amounts.

Keep deployment verification, reads and simulation in `chain.ts`; UI components consume its typed data. Never present sample events as live: `?demo=1` visibly labels its fixtures and disables transactions. Add a new view to the same navigation and responsive shell; do not add a marketing hero, new font family, animated background or second accent palette.

Design guidance attribution and license notices: `docs/INTERFACE-NOTICE.md` and `docs/INTERFACE-LICENSES.txt`.
