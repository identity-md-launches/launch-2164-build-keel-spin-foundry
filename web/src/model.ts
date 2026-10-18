import { formatEther, parseEther, type Address, type Hash } from "viem";
export enum State {
  None,
  Open,
  Spinning,
  Allocated,
  OraclePending,
  DecisionReady,
  AwaitingSale,
  Settled,
}
export enum Path {
  None,
  ObviousFloor,
  Oracle,
  FallbackFloor,
  FallbackDefault,
  External,
}
export interface VaultRound {
  state: State;
  bettors: number;
  fee: number;
  nftForwarded: boolean;
  oracleFailed: boolean;
  kept: boolean;
  feeRecipient: Address;
  pool: Address;
  collection: Address;
  allocatedAt: bigint;
  requestedAt: bigint;
  answerExpiresAt: bigint;
  totalShares: bigint;
  cash: bigint;
  requestId: bigint;
  listingId: bigint;
  tokenId: bigint;
  backing: bigint;
  ethBid: bigint;
  netOffer: bigint;
  oracleRequestId: Hash;
  path: Path;
}
export interface ChainEvent {
  eventName: string;
  args: Record<string, bigint | number | boolean | string>;
  blockNumber: bigint;
  blockHash: Hash;
  transactionHash: Hash;
  logIndex: number;
  timestamp: number;
}
export interface NFT {
  name: string;
  collectionName: string;
  image?: string;
  metadataFailed?: boolean;
}
export interface Round extends VaultRound {
  id: bigint;
  events: ChainEvent[];
  deposited: bigint;
  withdrawn: bigint;
  price: bigint;
  reward: bigint;
  paid: bigint;
  distributable?: bigint;
  sale?: { amount: bigint; hash: string };
  spinTime?: number;
  keptSince?: number;
  originalBettors: number;
  participants: string[];
  nft?: NFT;
  walletStake: bigint;
  claimable: bigint;
  withdrawable: bigint;
  deadline: bigint;
  fallbackAt: bigint;
  bid: bigint;
}
export interface Parameters {
  minBet: bigint;
  bufferBps: bigint;
  spinReward: bigint;
  maxSpinGasPrice: bigint;
  marginBps: bigint;
  haircutBps: bigint;
  feeBps: bigint;
  lowImdThreshold: bigint;
  imdBalance: bigint;
  minOracleLead: bigint;
  oraclePrice: bigint;
  maxBettors: bigint;
  teamWallet: Address;
  fwa: Address;
  router: Address;
  betsPaused: boolean;
}
export interface Snapshot {
  block: bigint;
  timestamp: number;
  receivedAt: number;
  gas: bigint;
  target: bigint;
  quote: bigint;
  reward: bigint;
  quoteValid: boolean;
  blackout: boolean;
  currentId: bigint;
  activeId: bigint;
  params: Parameters;
  rounds: Round[];
  verified: boolean;
  wiring: boolean;
}
export function joinRound(
  id: bigint,
  state: VaultRound,
  all: ChainEvent[],
): Round {
  const events = all
    .filter((e) => e.args.roundId === id)
    .sort((a, b) =>
      a.blockNumber === b.blockNumber
        ? a.logIndex - b.logIndex
        : a.blockNumber < b.blockNumber
          ? -1
          : 1,
    );
  const named = (name: string) => events.filter((e) => e.eventName === name);
  const sum = (name: string, key: string) =>
    named(name).reduce((s, e) => s + BigInt(e.args[key] ?? 0), 0n);
  const activeBettors = new Set<string>();
  let spinBettors = 0;
  for (const e of events) {
    if (e.eventName === "BetPlaced")
      activeBettors.add(String(e.args.bettor).toLowerCase());
    if (e.eventName === "Withdrawn")
      activeBettors.delete(String(e.args.bettor).toLowerCase());
    if (e.eventName === "SpinRequested") spinBettors = activeBettors.size;
  }
  const spins = named("SpinRequested"),
    settle = named("RoundSettled").at(-1),
    sale = named("SaleProceeds").at(-1);
  return {
    ...state,
    id,
    events,
    deposited: sum("BetPlaced", "amount"),
    withdrawn: sum("Withdrawn", "amount"),
    price: sum("SpinRequested", "quote"),
    reward: sum("SpinRequested", "reward"),
    paid: sum("Claimed", "amount"),
    distributable: settle ? BigInt(settle.args.distributable) : undefined,
    sale: sale
      ? { amount: BigInt(sale.args.amount), hash: String(sale.args.saleTxHash) }
      : undefined,
    spinTime: spins.at(-1)?.timestamp,
    keptSince: named("Decision").at(-1)?.timestamp,
    originalBettors: spinBettors,
    participants: [
      ...new Set(
        named("BetPlaced").map((e) => String(e.args.bettor).toLowerCase()),
      ),
    ],
    walletStake: 0n,
    claimable: 0n,
    withdrawable: 0n,
    deadline: 0n,
    fallbackAt: 0n,
    bid: state.ethBid,
  };
}
export function blackoutWindow(timestamp: number) {
  const t = ((timestamp % 43200) + 43200) % 43200;
  return {
    closed: t >= 42300,
    opensIn: t >= 42300 ? 43200 - t : 0,
    closesIn: t < 42300 ? 42300 - t : 0,
  };
}
export function spinReason(
  s: Snapshot | undefined,
  r: Round | undefined,
  now: number,
): string | undefined {
  if (!s || !r) return "waiting for live round data";
  if (!s.verified) return "deployment verification unavailable";
  if (!s.wiring) return "router setup is incomplete";
  if (r.state !== State.Open || r.totalShares === 0n)
    return "add ETH to this round first";
  if (s.activeId !== 0n) return "another spin is still resolving";
  if (s.gas > s.params.maxSpinGasPrice) return "gas is above the spin limit";
  if (blackoutWindow(now).closed || s.blackout)
    return "FWA is in its blackout window";
  if (!s.quoteValid) return "the live quote is unavailable";
  if (r.cash < s.quote + s.reward) return "this round needs more ETH";
  return undefined;
}
export function decisionActions(r: Round, now: number) {
  const valid =
    r.state === State.DecisionReady && BigInt(now) <= r.answerExpiresAt;
  const unresolved = [
    State.Allocated,
    State.OraclePending,
    State.DecisionReady,
  ].includes(r.state);
  return {
    sync: r.state === State.Spinning,
    request: r.state === State.Allocated,
    execute: valid && BigInt(now) < r.deadline,
    fallback:
      unresolved &&
      (r.oracleFailed ||
        BigInt(now) >= r.deadline ||
        (BigInt(now) >= r.fallbackAt && !valid)),
  };
}
export function eth(value: bigint | undefined): string {
  if (value === undefined) return "—";
  const n = Number(formatEther(value));
  if (n === 0) return "0";
  return n.toLocaleString("en-US", {
    maximumSignificantDigits: 4,
    minimumSignificantDigits: 1,
    useGrouping: false,
  });
}
export const exactETH = (v: bigint) => formatEther(v);
export function betError(value: string, min: bigint): string | undefined {
  try {
    if (!/^\d+(\.\d{0,18})?$/.test(value))
      return "enter an ETH amount with up to 18 decimals";
    if (parseEther(value) < min) return `minimum bet is ${eth(min)} ETH`;
  } catch {
    return "enter a valid ETH amount";
  }
}
export const short = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;
export const stateLabel = (state: State) =>
  [
    "",
    "open",
    "waiting for randomness",
    "deciding",
    "oracle pending",
    "oracle done",
    "awaiting sale",
    "settled",
  ][state] ?? "unknown";
export const status = (
  r: Pick<Round, "state" | "kept" | "sale" | "nftForwarded"> & {
    refunded?: boolean;
  },
) =>
  r.refunded
    ? "refunded"
    : r.state === State.Settled
      ? r.sale
        ? "sold"
        : r.kept
          ? "kept nft"
          : "took ETH bid"
      : r.state === State.AwaitingSale && !r.nftForwarded
        ? "kept nft"
        : stateLabel(r.state);
export const pathLabel = (path: Path) =>
  ["pending", "pre-check", "oracle", "fallback", "fallback", "external"][path];
export const returnRate = (r: Round) =>
  r.distributable !== undefined && r.deposited > r.withdrawn
    ? (r.distributable * 10n ** 18n) / (r.deposited - r.withdrawn)
    : undefined;
export function relative(timestamp: number, now: number) {
  const n = Math.max(0, now - timestamp);
  return n < 60
    ? "just now"
    : n < 3600
      ? `${Math.floor(n / 60)}m ago`
      : n < 86400
        ? `${Math.floor(n / 3600)}h ago`
        : `${Math.floor(n / 86400)}d ago`;
}
export function countdown(seconds: number) {
  seconds = Math.max(0, Math.ceil(seconds));
  return `${Math.floor(seconds / 3600) ? `${Math.floor(seconds / 3600)}h ` : ""}${Math.floor((seconds % 3600) / 60)}m ${seconds % 60}s`;
}
export const jsonEncode = (v: unknown) =>
  JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? `${x}n` : x));
export const jsonDecode = (v: string) =>
  JSON.parse(v, (_k, x) =>
    typeof x === "string" && /^\d+n$/.test(x) ? BigInt(x.slice(0, -1)) : x,
  );

export interface SpinEntry extends Round {
  spinKey: string;
  spinHash: Hash;
  spinBlock: bigint;
  spinLog: number;
  attempt: number;
  refunded: boolean;
}
/** One entry per actual acquisition attempt, including repeated spins after refunds. */
export function spinHistory(rounds: Round[]): SpinEntry[] {
  return rounds
    .flatMap((round) => {
      const requests = round.events.filter(
        (e) => e.eventName === "SpinRequested",
      );
      return requests.map((request, index) => {
        const next = requests[index + 1];
        const inAttempt = round.events.filter(
          (e) =>
            (e.blockNumber > request.blockNumber ||
              (e.blockNumber === request.blockNumber &&
                e.logIndex >= request.logIndex)) &&
            (!next ||
              e.blockNumber < next.blockNumber ||
              (e.blockNumber === next.blockNumber &&
                e.logIndex < next.logIndex)),
        );
        const refunded = inAttempt.some(
          (e) => e.eventName === "AcquisitionRefunded",
        );
        const active = new Set<string>();
        for (const event of round.events) {
          if (
            event.blockNumber > request.blockNumber ||
            (event.blockNumber === request.blockNumber &&
              event.logIndex > request.logIndex)
          )
            break;
          if (event.eventName === "BetPlaced")
            active.add(String(event.args.bettor).toLowerCase());
          if (event.eventName === "Withdrawn")
            active.delete(String(event.args.bettor).toLowerCase());
        }
        const entry: SpinEntry = {
          ...round,
          spinKey: `${request.transactionHash}:${request.logIndex}`,
          spinHash: request.transactionHash,
          spinBlock: request.blockNumber,
          spinLog: request.logIndex,
          attempt: index + 1,
          requestId: BigInt(request.args.requestId),
          refunded,
          price: BigInt(request.args.quote),
          reward: BigInt(request.args.reward),
          spinTime: request.timestamp,
          originalBettors: active.size,
          participants: [...active],
        };
        if (refunded)
          Object.assign(entry, {
            state: State.Open,
            kept: false,
            nftForwarded: false,
            listingId: 0n,
            nft: undefined,
            path: Path.None,
            sale: undefined,
            distributable: undefined,
          });
        return entry;
      });
    })
    .sort((a, b) =>
      a.spinBlock === b.spinBlock
        ? b.spinLog - a.spinLog
        : a.spinBlock > b.spinBlock
          ? -1
          : 1,
    );
}
