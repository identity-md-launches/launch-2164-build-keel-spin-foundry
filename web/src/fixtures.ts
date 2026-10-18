/** Explicit sample mode only (?demo=1). Never mixed into the live chain store. */
import { parseEther, zeroHash, type Address, type Hash } from "viem";
import { vault, router, deployment } from "./config";
import {
  type ChainEvent,
  type Round,
  type Snapshot,
  type VaultRound,
  Path,
  State,
  joinRound,
} from "./model";
const fwa = deployment.manifest.contracts[0].constructorArgs[1] as Address;
const hash = deployment.contracts[0].txHash as Hash;
const amount = (n: string) => parseEther(n);
export function fixtureEvents(now: number): ChainEvent[] {
  const out: ChainEvent[] = [];
  for (let i = 1; i <= 31; i++) {
    const id = BigInt(i),
      path = [
        Path.ObviousFloor,
        Path.Oracle,
        Path.FallbackFloor,
        Path.FallbackDefault,
        Path.External,
      ][(i - 1) % 5],
      kept = i % 3 !== 0;
    let logIndex = 0;
    const timestamp = now - (32 - i) * 3700;
    const push = (eventName: string, args: ChainEvent["args"]) =>
      out.push({
        eventName,
        args: { roundId: id, ...args },
        blockNumber: BigInt(26219918 + i),
        blockHash: hash,
        transactionHash: hash,
        logIndex: logIndex++,
        timestamp,
      });
    push("BetPlaced", {
      bettor: vault,
      amount: amount("0.02"),
      shares: amount("0.02"),
    });
    push("BetPlaced", {
      bettor: router,
      amount: amount("0.08"),
      shares: amount("0.08"),
    });
    push("RoundStateChanged", { state: State.Spinning });
    push("SpinRequested", {
      requestId: id,
      caller: vault,
      quote: amount("0.09"),
      reward: amount("0.0018"),
      refund: 0n,
    });
    push("RoundStateChanged", { state: State.Allocated });
    push("AllocationRecorded", {
      listingId: id,
      collection: fwa,
      tokenId: BigInt(8000 + i),
      deadline: BigInt(timestamp + 3000),
    });
    if (path === Path.Oracle) {
      push("OracleRequested", { requestId: zeroHash });
      push("OracleValueStored", {
        requestId: zeroHash,
        netOffer: amount("0.12"),
        expiresAt: BigInt(timestamp + 4000),
      });
    }
    push("Decision", {
      collection: fwa,
      tokenId: BigInt(8000 + i),
      ethBid: amount("0.075"),
      netOffer: amount("0.12"),
      keep: kept,
      path,
    });
    push("RoundStateChanged", {
      state: kept ? State.AwaitingSale : State.Settled,
    });
    if (kept && i !== 2) push("NFTForwarded", { recipient: vault });
    if (i % 3 === 1) {
      push("SaleProceeds", { saleTxHash: hash, amount: amount("0.13") });
      push("RoundSettled", { distributable: amount("0.1382"), fee: 0n });
    } else if (!kept)
      push("RoundSettled", { distributable: amount("0.0832"), fee: 0n });
  }
  return out;
}
export function fixtureSnapshot(now = Math.floor(Date.now() / 1000)): Snapshot {
  const events = fixtureEvents(now),
    rounds: Round[] = [];
  for (let i = 1; i <= 32; i++) {
    const open = i === 32,
      kept = i % 3 !== 0,
      sold = i % 3 === 1,
      path = [
        Path.ObviousFloor,
        Path.Oracle,
        Path.FallbackFloor,
        Path.FallbackDefault,
        Path.External,
      ][(i - 1) % 5];
    const state: VaultRound = {
      state: open
        ? State.Open
        : kept && !sold
          ? State.AwaitingSale
          : State.Settled,
      bettors: open ? 7 : 2,
      fee: 0,
      nftForwarded: kept && i !== 2,
      oracleFailed: false,
      kept: !open && kept,
      feeRecipient: vault,
      pool: fwa,
      collection: fwa,
      allocatedAt: BigInt(now - 3600),
      requestedAt: 0n,
      answerExpiresAt: 0n,
      totalShares: amount(open ? "0.064" : "0.1"),
      cash: amount(
        open ? "0.064" : sold ? "0.1382" : kept ? "0.0082" : "0.0832",
      ),
      requestId: open ? 0n : BigInt(i),
      listingId: open ? 0n : BigInt(i),
      tokenId: BigInt(8000 + i),
      backing: amount("0.1"),
      ethBid: amount("0.075"),
      netOffer: amount("0.12"),
      oracleRequestId: zeroHash,
      path: open ? Path.None : path,
    };
    const r = joinRound(BigInt(i), state, events);
    r.walletStake = amount(open ? "0.006" : "0.02");
    r.claimable = r.state === State.Settled ? r.cash / 5n : 0n;
    r.withdrawable = open ? amount("0.006") : 0n;
    r.nft = open
      ? undefined
      : {
          collectionName: "sample collection",
          name: `sample NFT #${r.tokenId}`,
        };
    rounds.push(r);
  }
  return {
    block: 26220000n,
    timestamp: now,
    receivedAt: Date.now(),
    gas: 4_200_000_000n,
    target: amount("0.0963"),
    quote: amount("0.09"),
    reward: amount("0.0018"),
    quoteValid: true,
    blackout: false,
    currentId: 32n,
    activeId: 0n,
    verified: true,
    wiring: true,
    rounds,
    params: {
      minBet: amount("0.001"),
      bufferBps: 500n,
      spinReward: amount("0.002"),
      maxSpinGasPrice: 100_000_000_000n,
      marginBps: 500n,
      haircutBps: 1500n,
      feeBps: 0n,
      lowImdThreshold: amount("2"),
      imdBalance: amount("8.5"),
      minOracleLead: 600n,
      oraclePrice: amount("0.5"),
      maxBettors: 500n,
      teamWallet: vault,
      fwa,
      router,
      betsPaused: false,
    },
  };
}
