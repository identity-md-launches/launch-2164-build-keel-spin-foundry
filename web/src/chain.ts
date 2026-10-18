/** The only module that performs chain reads, event indexing, metadata reads and simulations. */
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  decodeEventLog,
  keccak256,
  parseAbi,
  type Address,
  type Hash,
  type Hex,
  type WalletClient,
} from "viem";
import {
  abi,
  chain,
  deployment,
  deploymentBlock,
  fwaABI,
  router,
  routerABI,
  transport,
  vault,
} from "./config";
import runtime from "./contracts/runtime.json";
import {
  type ChainEvent,
  type NFT,
  type Parameters as VaultParameters,
  type Round,
  type Snapshot,
  type VaultRound,
  State,
  joinRound,
  jsonDecode,
  jsonEncode,
} from "./model";
export const client = createPublicClient({ chain, transport: transport() });
const read = async <T>(
  functionName: string,
  args: readonly unknown[] = [],
  options: Record<string, unknown> = {},
) =>
  client.readContract({
    address: vault,
    abi,
    functionName,
    args,
    ...options,
  } as Parameters<typeof client.readContract>[0]) as Promise<T>;
type ReadOptions = { blockNumber: bigint; gasPrice?: bigint };
const poolRead = async <T>(
  address: Address,
  functionName: string,
  args: readonly unknown[] = [],
  options: ReadOptions,
) =>
  client.readContract({
    address,
    abi: fwaABI,
    functionName,
    args,
    ...options,
  } as Parameters<typeof client.readContract>[0]) as Promise<T>;
const key = `keel:events:v2:${chain.id}:${vault.toLowerCase()}`;
let events: ChainEvent[] = [],
  scanned = deploymentBlock - 1n,
  wallet: Address | undefined,
  snapshot: Snapshot | undefined,
  busy = false,
  again = false,
  verified = false;
const roundCache = new Map<string, Round>(),
  nfts = new Map<string, NFT>();
export interface Store {
  snapshot?: Snapshot;
  loading: boolean;
  error?: string;
  progress?: string;
}
let store: Store = { loading: true };
const listeners = new Set<() => void>();
const emit = (patch: Partial<Store>) => {
  store = { ...store, ...patch };
  listeners.forEach((l) => l());
};
export const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => {
    listeners.delete(l);
  };
};
export const getStore = () => store;
let interval: ReturnType<typeof setInterval> | undefined;
export function start() {
  if (interval) return;
  void refresh();
  interval = setInterval(() => void refresh(), 12_000);
}
export function setWallet(value: Address | undefined) {
  if (wallet === value) return;
  wallet = value;
  roundCache.forEach((r) => {
    r.walletStake = 0n;
    r.claimable = 0n;
    r.withdrawable = 0n;
  });
  if (snapshot)
    emit({ snapshot: { ...snapshot, rounds: [...roundCache.values()] } });
  void refresh();
}
async function limited<T, R>(
  items: T[],
  fn: (x: T) => Promise<R>,
  concurrency = 6,
): Promise<R[]> {
  const output: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, async () => {
      for (;;) {
        const i = next++;
        if (i >= items.length) return;
        output[i] = await fn(items[i]);
      }
    }),
  );
  return output;
}
function loadCache() {
  try {
    const c = jsonDecode(localStorage.getItem(key) ?? "null");
    if (
      c?.version === 2 &&
      typeof c.to === "bigint" &&
      Array.isArray(c.events) &&
      c.events.every(
        (e: ChainEvent) =>
          typeof e.blockNumber === "bigint" &&
          typeof e.eventName === "string" &&
          e.args,
      )
    ) {
      events = c.events;
      scanned = c.to;
    }
  } catch {
    /* A blocked or full localStorage never prevents reading the chain. */
  }
}
loadCache();
function saveCache() {
  try {
    localStorage.setItem(key, jsonEncode({ version: 2, to: scanned, events }));
  } catch {
    /* Storage is optional. */
  }
}
export async function verifyDeployment() {
  if ((await client.getChainId()) !== deployment.chainId)
    throw new Error("RPC is on the wrong chain. Ethereum mainnet is required.");
  for (const c of deployment.contracts) {
    const code = await client.getCode({ address: c.address as Address });
    const expected = runtime[c.name as keyof typeof runtime];
    if (!code || code === "0x" || (code.length - 2) / 2 !== expected.bytes)
      throw new Error(
        `${c.name} deployment does not match the handoff. Transactions are disabled.`,
      );
    let normalized = code.slice(2);
    for (const { start, length } of expected.immutableReferences)
      normalized =
        normalized.slice(0, start * 2) +
        "0".repeat(length * 2) +
        normalized.slice((start + length) * 2);
    if (keccak256(`0x${normalized}`) !== expected.hash)
      throw new Error(
        `${c.name} runtime verification failed. Transactions are disabled.`,
      );
  }
  verified = true;
}
async function scan(to: bigint) {
  // Re-read 12 blocks on every pass so short reorgs replace logs, rather than duplicating them.
  if (scanned > to) {
    events = events.filter((e) => e.blockNumber <= to);
    scanned = to > deploymentBlock ? to - 1n : deploymentBlock - 1n;
  }
  let from = scanned >= deploymentBlock ? scanned - 11n : deploymentBlock;
  if (from < deploymentBlock) from = deploymentBlock;
  let chunk = 2000n;
  const changed = new Set<bigint>();
  while (from <= to) {
    const end = from + chunk - 1n < to ? from + chunk - 1n : to;
    emit({
      progress: `reading Ethereum blocks ${from.toLocaleString()}–${end.toLocaleString()}`,
    });
    let logs;
    try {
      logs = await client.getLogs({
        address: vault,
        fromBlock: from,
        toBlock: end,
      });
    } catch (error) {
      if (chunk > 100n) {
        chunk = chunk / 2n;
        continue;
      }
      throw error;
    }
    const decoded: ChainEvent[] = [];
    const times = new Map<bigint, number>();
    await limited([...new Set(logs.map((l) => l.blockNumber))], async (n) => {
      times.set(
        n,
        Number((await client.getBlock({ blockNumber: n })).timestamp),
      );
    });
    for (const log of logs) {
      try {
        const e = decodeEventLog({
          abi,
          data: log.data,
          topics: log.topics,
          strict: true,
        });
        decoded.push({
          eventName: e.eventName!,
          args: e.args as unknown as ChainEvent["args"],
          blockNumber: log.blockNumber,
          blockHash: log.blockHash,
          transactionHash: log.transactionHash,
          logIndex: log.logIndex,
          timestamp: times.get(log.blockNumber)!,
        });
        const id = (e.args as unknown as Record<string, unknown>).roundId;
        if (typeof id === "bigint") changed.add(id);
      } catch {
        /* Ignore events outside the verified vault ABI. */
      }
    }
    const previous = events.filter(
      (e) => e.blockNumber >= from && e.blockNumber <= end,
    );
    for (const e of previous)
      if (typeof e.args.roundId === "bigint") changed.add(e.args.roundId);
    events = [
      ...events.filter((e) => e.blockNumber < from || e.blockNumber > end),
      ...decoded,
    ];
    scanned = end;
    saveCache();
    from = end + 1n;
  }
  return changed;
}
const parameterNames = [
  "minBet",
  "bufferBps",
  "spinReward",
  "maxSpinGasPrice",
  "marginBps",
  "haircutBps",
  "feeBps",
  "lowImdThreshold",
  "imdBalance",
  "minOracleLead",
  "oraclePrice",
  "maxBettors",
  "teamWallet",
  "fwa",
  "router",
  "betsPaused",
] as const;
export async function refresh() {
  if (busy) {
    again = true;
    return;
  }
  busy = true;
  try {
    if (!verified) await verifyDeployment();
    const block = await client.getBlock(),
      gas = await client.getGasPrice(),
      options = { blockNumber: block.number, gasPrice: gas };
    const params = Object.fromEntries(
      await Promise.all(
        parameterNames.map(async (n) => [
          n,
          await read(n, [], options).then((value) =>
            typeof value === "number" ? BigInt(value) : value,
          ),
        ]),
      ),
    ) as unknown as VaultParameters;
    const [
      currentId,
      activeId,
      target,
      quoteData,
      blackout,
      routerVault,
      routerPool,
    ] = await Promise.all([
      read<bigint>("currentRoundId", [], options),
      read<bigint>("activeRoundId", [], options),
      read<bigint>("liveTarget", [], options),
      poolRead<readonly [bigint, bigint, bigint]>(
        params.fwa,
        "quoteAcquisitionPrice",
        [],
        options,
      ),
      poolRead<boolean>(params.fwa, "isPurchaseBlackout", [], options),
      client.readContract({
        address: router,
        abi: routerABI,
        functionName: "vault",
        blockNumber: block.number,
      }),
      client.readContract({
        address: router,
        abi: routerABI,
        functionName: "pool",
        blockNumber: block.number,
      }),
    ]);
    const [fee, vrf, quote] = quoteData;
    const reward = await read<bigint>("effectiveSpinReward", [quote], options);
    const changed = await scan(block.number);
    const ids = new Set<bigint>([
      currentId,
      ...events
        .filter((e) => typeof e.args.roundId === "bigint")
        .map((e) => e.args.roundId as bigint),
    ]);
    if (activeId) ids.add(activeId);
    const readWallet = wallet;
    const rounds = await limited([...ids], async (id) => {
      let r = roundCache.get(String(id));
      if (
        !r ||
        changed.has(id) ||
        id === currentId ||
        id === activeId ||
        r.state === State.AwaitingSale
      ) {
        const data = await read<VaultRound>("rounds", [id], options);
        r = joinRound(id, data, events);
      }
      if (readWallet && r.participants.includes(readWallet.toLowerCase())) {
        [r.walletStake, r.claimable, r.withdrawable] = await Promise.all([
          read<bigint>("stake", [id, readWallet], options),
          read<bigint>("claimable", [id, readWallet], options),
          read<bigint>("withdrawable", [id, readWallet], options),
        ]);
      } else {
        r.walletStake = 0n;
        r.claimable = 0n;
        r.withdrawable = 0n;
      }
      if (
        r.allocatedAt > 0n &&
        [State.Allocated, State.OraclePending, State.DecisionReady].includes(
          r.state,
        )
      ) {
        [r.deadline, r.fallbackAt, r.bid] = await Promise.all([
          read<bigint>("decisionDeadline", [id], options),
          read<bigint>("fallbackAt", [id], options),
          read<bigint>("ethBid", [id], options),
        ]);
      }
      r.nft = nfts.get(`${r.pool}:${r.listingId}`);
      roundCache.set(String(id), r);
      return r;
    });
    if (wallet !== readWallet) {
      again = true;
      return;
    }
    // Remove rounds orphaned by a reorg.
    for (const id of roundCache.keys())
      if (!ids.has(BigInt(id))) roundCache.delete(id);
    snapshot = {
      block: block.number,
      timestamp: Number(block.timestamp),
      receivedAt: Date.now(),
      gas,
      target,
      quote,
      reward,
      quoteValid: fee > 0n && quote === fee + vrf,
      blackout,
      currentId,
      activeId,
      params,
      rounds,
      verified,
      wiring:
        params.router.toLowerCase() === router.toLowerCase() &&
        String(routerVault).toLowerCase() === vault.toLowerCase() &&
        String(routerPool).toLowerCase() === params.fwa.toLowerCase(),
    };
    emit({ snapshot, loading: false, error: undefined, progress: undefined });
    void hydrateNFTs(rounds, options);
  } catch (e) {
    emit({ loading: false, error: plainError(e), progress: undefined });
  } finally {
    busy = false;
    if (again) {
      again = false;
      void refresh();
    }
  }
}
const erc721 = parseAbi([
  "function tokenURI(uint256) view returns (string)",
  "function name() view returns (string)",
]);
const punkData = parseAbi([
  "function punkImageSvg(uint16) view returns (string)",
]);
// Explicitly supplied by the brief; all deployment and protocol addresses otherwise come from the handoff or live state.
const cryptoPunksData = "0x16F5A35647D6F03D5D3da7b35409D65ba03aF3B2" as Address;
export function uriUrls(uri: string): string[] {
  if (uri.startsWith("ipfs://")) {
    const path = uri.slice(7).replace(/^ipfs\//, "");
    return [
      `https://ipfs.io/ipfs/${path}`,
      `https://cloudflare-ipfs.com/ipfs/${path}`,
      `https://dweb.link/ipfs/${path}`,
    ];
  }
  return /^(https:\/\/|data:application\/json|data:image\/)/i.test(uri)
    ? [uri]
    : [];
}
async function metadata(uri: string) {
  for (const url of uriUrls(uri)) {
    try {
      const response = await fetch(url, {
        signal: AbortSignal.timeout(6000),
        referrerPolicy: "no-referrer",
      });
      if (response.ok) return await response.json();
    } catch {
      /* Try the next public IPFS gateway. */
    }
  }
  throw new Error("NFT metadata unavailable");
}
const hydrating = new Set<string>();
async function hydrateNFTs(rounds: Round[], options: ReadOptions) {
  await limited(
    rounds.filter((r) => r.listingId > 0n && !r.nft),
    async (r) => {
      const key = `${r.pool}:${r.listingId}`;
      if (hydrating.has(key)) return;
      hydrating.add(key);
      let nft: NFT = {
        name: `NFT #${r.tokenId}`,
        collectionName: "collection",
        metadataFailed: true,
      };
      try {
        const listing = await poolRead<{
          collection: Address;
          tokenId: bigint;
        }>(r.pool, "listings", [r.listingId], options);
        const collectionName = await client
          .readContract({
            address: listing.collection,
            abi: erc721,
            functionName: "name",
          })
          .catch(() => r.collection);
        nft = {
          ...nft,
          collectionName,
          name: `${collectionName} #${listing.tokenId}`,
        };
        if (/cryptopunks/i.test(collectionName)) {
          const svg = await client.readContract({
            address: cryptoPunksData,
            abi: punkData,
            functionName: "punkImageSvg",
            args: [Number(listing.tokenId)],
          });
          nft = {
            ...nft,
            image: `data:image/svg+xml,${encodeURIComponent(svg)}`,
            metadataFailed: false,
          };
        } else {
          const uri = await client.readContract({
            address: listing.collection,
            abi: erc721,
            functionName: "tokenURI",
            args: [listing.tokenId],
          });
          const data = await metadata(uri);
          nft = {
            ...nft,
            name: typeof data.name === "string" ? data.name : nft.name,
            image:
              typeof data.image === "string"
                ? uriUrls(data.image)[0]
                : undefined,
            metadataFailed: false,
          };
        }
      } catch {
        /* Original local art remains visible when a collection or gateway is unavailable. */
      }
      nfts.set(key, nft);
      r.nft = nft;
      hydrating.delete(key);
      if (snapshot)
        emit({ snapshot: { ...snapshot, rounds: [...snapshot.rounds] } });
    },
    3,
  );
}
export type Action =
  | "bet"
  | "betInto"
  | "withdraw"
  | "spin"
  | "syncRound"
  | "requestDecision"
  | "executeDecision"
  | "settleFallback"
  | "claim";
export async function sendAction(
  walletClient: WalletClient,
  account: Address,
  action: Action,
  id?: bigint,
  value?: bigint,
  onHash?: (hash: Hash) => void,
) {
  if (!verified)
    throw new Error("Deployment verification is required before sending.");
  if ((await walletClient.getChainId()) !== chain.id)
    throw new Error("Switch your wallet to Ethereum mainnet.");
  const gasPrice = await client.getGasPrice();
  const { request } = await client.simulateContract({
    account,
    address: vault,
    abi,
    functionName: action,
    args: action === "bet" ? [] : [id!],
    value,
    gasPrice,
    chain,
  });
  const hash = await walletClient.writeContract(request);
  onHash?.(hash);
  let actionReplaced = false;
  const receipt = await client.waitForTransactionReceipt({
    hash,
    confirmations: 1,
    onReplaced: (replacement) => {
      onHash?.(replacement.transaction.hash);
      if (replacement.reason !== "repriced") actionReplaced = true;
    },
  });
  if (actionReplaced) {
    await refresh();
    throw new Error(
      "The transaction was replaced or cancelled. Check the linked transaction before trying again.",
    );
  }
  if (receipt.status !== "success")
    throw new Error("The transaction reverted. No action was completed.");
  await refresh();
  return receipt.transactionHash;
}
const errorMessages: Record<string, string> = {
  InvalidAmount:
    "The amount is outside the allowed range. Check the minimum bet.",
  WrongState: "This round has changed. Refresh and try again.",
  Paused: "New bets are paused by the vault.",
  NotConfigured: "The vault router is not configured yet.",
  SpinInProgress: "Another spin is still resolving.",
  InsufficientRoundBalance:
    "The live spin price increased. This round needs more ETH.",
  GasPriceTooHigh: "Gas is above the vault limit. Try again when it falls.",
  Blackout: "FWA is closed for its UTC blackout. Try after the window ends.",
  TooEarly: "This action is not available yet.",
  StaleAnswer: "The oracle answer has expired. The fallback may be available.",
  InvalidParameter:
    "A live protocol parameter changed. Refresh before trying again.",
  TransferFailed:
    "Your wallet could not receive ETH. The contract left your stake intact.",
};
export function plainError(error: unknown): string {
  if (error instanceof BaseError) {
    const reverted = error.walk(
      (e) => e instanceof ContractFunctionRevertedError,
    );
    if (reverted instanceof ContractFunctionRevertedError) {
      return (
        errorMessages[reverted.data?.errorName ?? ""] ??
        "The contract refused this action. Refresh the round and try again."
      );
    }
    if (/reject|denied|cancel/i.test(error.message))
      return "The wallet request was cancelled.";
    if (/insufficient funds/i.test(error.message))
      return "Your wallet needs enough ETH for the amount and network gas.";
    if (/fetch|http|timeout|network/i.test(error.message))
      return "Ethereum could not be reached. Try refreshing in a moment.";
    return error.shortMessage.slice(0, 220);
  }
  return error instanceof Error
    ? error.message
    : "Unable to complete the action. Try again.";
}
