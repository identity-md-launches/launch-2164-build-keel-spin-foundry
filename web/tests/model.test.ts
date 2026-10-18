import test from "node:test";
import assert from "node:assert/strict";
import {
  parseEther,
  decodeEventLog,
  encodeEventTopics,
  encodeAbiParameters,
  type AbiEvent,
} from "viem";
import { abi, vault } from "../src/config";
import { fixtureSnapshot, fixtureEvents } from "../src/fixtures";
import {
  State,
  Path,
  betError,
  blackoutWindow,
  decisionActions,
  eth,
  exactETH,
  joinRound,
  jsonDecode,
  jsonEncode,
  pathLabel,
  returnRate,
  status,
  spinReason,
  spinHistory,
} from "../src/model";
const e = parseEther;
const now = Date.UTC(2026, 9, 18, 10) / 1000;
const snapshot = () => fixtureSnapshot(now);
test("spin requires quote plus capped reward, rather than the buffer target", () => {
  const s = snapshot(),
    r = s.rounds.at(-1)!;
  r.cash = s.quote + s.reward;
  assert.equal(spinReason(s, r, now), undefined);
  r.cash -= 1n;
  assert.match(spinReason(s, r, now)!, /more ETH/);
  assert.ok(s.target > s.quote + s.reward);
});
test("gas cap allows equality and refuses one wei above", () => {
  const s = snapshot(),
    r = s.rounds.at(-1)!;
  r.cash = s.target;
  s.gas = s.params.maxSpinGasPrice;
  assert.equal(spinReason(s, r, now), undefined);
  s.gas++;
  assert.match(spinReason(s, r, now)!, /gas/);
});
test("both blackout windows have exact UTC boundaries, including midnight", () => {
  for (const hour of [11, 23]) {
    const t = Date.UTC(2026, 9, 18, hour, 45) / 1000;
    assert.equal(blackoutWindow(t - 1).closed, false);
    assert.equal(blackoutWindow(t).closed, true);
    assert.equal(blackoutWindow(t).opensIn, 900);
    assert.equal(blackoutWindow(t + 899).opensIn, 1);
    assert.equal(blackoutWindow(t + 900).closed, false);
  }
});
test("FWA blackout flag independently disables spin", () => {
  const s = snapshot(),
    r = s.rounds.at(-1)!;
  r.cash = s.target;
  s.blackout = true;
  assert.match(spinReason(s, r, now)!, /blackout/);
});
test("unverified code, wiring, active spin, wrong state and zero shares are gated", () => {
  const s = snapshot(),
    r = s.rounds.at(-1)!;
  r.cash = s.target;
  s.verified = false;
  assert.match(spinReason(s, r, now)!, /verification/);
  s.verified = true;
  s.wiring = false;
  assert.match(spinReason(s, r, now)!, /setup/);
  s.wiring = true;
  s.activeId = 1n;
  assert.match(spinReason(s, r, now)!, /resolving/);
  s.activeId = 0n;
  r.state = State.Settled;
  assert.match(spinReason(s, r, now)!, /add ETH/);
});
test("input validates minimum, exact precision and rejects exponent or signed input", () => {
  assert.equal(betError("0.001", e(".001")), undefined);
  for (const n of [
    "0",
    "-1",
    "1e2",
    "abc",
    "0.000999",
    "0.0010000000000000001",
  ])
    assert.ok(betError(n, e(".001")));
  assert.equal(betError("0.001000000000000001", e(".001")), undefined);
});
test("all decision paths and terminal outcomes exist in mock event fixture", () => {
  const s = snapshot();
  for (const path of [
    Path.ObviousFloor,
    Path.Oracle,
    Path.FallbackFloor,
    Path.FallbackDefault,
    Path.External,
  ])
    assert.ok(s.rounds.some((r) => r.path === path));
  assert.ok(s.rounds.some((r) => r.sale));
  assert.ok(s.rounds.some((r) => r.state === State.Settled && !r.kept));
  assert.ok(s.rounds.some((r) => r.state === State.AwaitingSale));
  assert.equal(s.rounds.filter((r) => r.requestId > 0n).length, 31);
  assert.equal(
    s.rounds.filter((r) => r.requestId > 0n).slice(0, 25).length,
    25,
  );
});
test("mock log ABI decoding joins bet, allocation, decision, sale and settlement", () => {
  const events = fixtureEvents(now),
    r = snapshot().rounds[0];
  const encoded = events
    .filter((ev) => ev.args.roundId === r.id)
    .map((ev) => {
      const a = abi.find(
        (a) => a.type === "event" && a.name === ev.eventName,
      ) as AbiEvent;
      const args = ev.args;
      const topics = encodeEventTopics({
        abi: [a],
        eventName: a.name,
        args: args as never,
      });
      const nonIndexed = a.inputs.filter((i) => !i.indexed);
      const data = encodeAbiParameters(
        nonIndexed,
        nonIndexed.map((i) => args[i.name!]),
      );
      const decoded = decodeEventLog({
        abi: [a],
        data,
        topics: topics as never,
      });
      return {
        ...ev,
        eventName: decoded.eventName,
        args: decoded.args as never,
      };
    });
  const joined = joinRound(r.id, r, encoded);
  assert.equal(joined.deposited, e(".1"));
  assert.equal(joined.originalBettors, 2);
  assert.equal(joined.price, e(".09"));
  assert.equal(joined.sale?.amount, e(".13"));
  assert.equal(joined.distributable, e(".1382"));
  assert.equal(returnRate(joined), e("1.382"));
});
test("oracle execution and fallback boundaries follow contract predicates", () => {
  const r = snapshot().rounds[0];
  r.state = State.DecisionReady;
  r.deadline = BigInt(now + 100);
  r.fallbackAt = BigInt(now - 10);
  r.answerExpiresAt = BigInt(now);
  assert.equal(decisionActions(r, now).execute, true);
  assert.equal(decisionActions(r, now).fallback, false);
  assert.equal(decisionActions(r, now + 1).execute, false);
  assert.equal(decisionActions(r, now + 1).fallback, true);
  r.answerExpiresAt = BigInt(now + 200);
  assert.equal(decisionActions(r, now + 100).execute, false);
  assert.equal(decisionActions(r, now + 100).fallback, true);
  r.state = State.OraclePending;
  r.oracleFailed = true;
  assert.equal(decisionActions(r, now - 1000).fallback, true);
});
test("withdrawals reduce the return denominator and claims do not erase historical return", () => {
  const s = snapshot(),
    r = s.rounds.find((r) => r.sale)!;
  const value = returnRate(r);
  r.totalShares = 0n;
  r.cash = 0n;
  r.paid = r.distributable!;
  assert.equal(returnRate(r), value);
  r.withdrawn = e(".01");
  assert.equal(returnRate(r), (r.distributable! * 10n ** 18n) / e(".09"));
});
test("ETH display has four significant digits while exact claim string preserves wei", () => {
  assert.equal(eth(e("1.23456789")), "1.235");
  assert.equal(eth(e("0.000012345")), "0.00001235");
  assert.equal(exactETH(1000000000000001n), "0.001000000000000001");
  assert.equal(eth(0n), "0");
});
test("cached events preserve bigint and addresses", () => {
  const events = fixtureEvents(now);
  const saved = jsonDecode(jsonEncode(events));
  assert.equal(saved[0].args.bettor, vault);
  assert.equal(saved[0].blockNumber, events[0].blockNumber);
  assert.equal(saved[0].args.amount, e(".02"));
});
test("path badges keep the three requested decision families distinct", () => {
  assert.equal(pathLabel(Path.ObviousFloor), "pre-check");
  assert.equal(pathLabel(Path.Oracle), "oracle");
  assert.equal(pathLabel(Path.FallbackDefault), "fallback");
});

test("fixture distinguishes kept NFT from awaiting sale and sold", () => {
  const rounds = snapshot().rounds;
  assert.ok(rounds.some((r) => status(r) === "kept nft"));
  assert.ok(rounds.some((r) => status(r) === "awaiting sale"));
  assert.ok(rounds.some((r) => status(r) === "sold"));
  assert.ok(rounds.some((r) => status(r) === "took ETH bid"));
});

test("history counts active bettors at spin, excluding full withdrawals", () => {
  const r = snapshot().rounds[0];
  const events = fixtureEvents(now).filter((ev) => ev.args.roundId === r.id);
  const spinIndex = events.findIndex((ev) => ev.eventName === "SpinRequested");
  events.splice(spinIndex, 0, {
    ...events[0],
    eventName: "Withdrawn",
    args: {
      roundId: r.id,
      bettor: vault,
      recipient: vault,
      amount: e(".02"),
      shares: e(".02"),
    },
  });
  const ordered = events.map((ev, logIndex) => ({ ...ev, logIndex }));
  assert.equal(joinRound(r.id, r, ordered).originalBettors, 1);
});

test("refunded and repeated acquisitions get separate history rows with distinct costs and links", () => {
  const round = snapshot().rounds[0];
  const requestIndex = round.events.findIndex(
    (e) => e.eventName === "SpinRequested",
  );
  const request = round.events[requestIndex];
  const events = [...round.events];
  events.splice(
    requestIndex + 1,
    0,
    {
      ...request,
      eventName: "AcquisitionRefunded",
      args: {
        roundId: round.id,
        requestId: round.requestId,
        refund: e(".088"),
        remainingCash: e(".0962"),
      },
    },
    {
      ...request,
      args: {
        ...request.args,
        requestId: round.requestId + 1n,
        quote: e(".1"),
      },
    },
  );
  const ordered = events.map((event, logIndex) => ({
    ...event,
    logIndex,
    timestamp: request.timestamp + logIndex,
  }));
  const entries = spinHistory([
    joinRound(round.id, { ...round, requestId: round.requestId + 1n }, ordered),
  ]);
  assert.equal(entries.length, 2);
  assert.equal(entries[0].attempt, 2);
  assert.equal(entries[0].price, e(".1"));
  assert.equal(entries[1].price, e(".09"));
  assert.equal(status(entries[1]), "refunded");
  assert.equal(entries[1].sale, undefined);
  assert.equal(entries[1].nft, undefined);
  assert.notEqual(entries[0].spinKey, entries[1].spinKey);
  assert.equal(entries[0].id, entries[1].id);
});

test("history orders by spin block rather than round id", () => {
  const rounds = snapshot().rounds;
  const olderRoundSpinsLater = {
    ...rounds[0],
    events: rounds[0].events.map((event) => ({
      ...event,
      blockNumber: rounds[30].events[0].blockNumber + 1n,
    })),
  };
  assert.equal(spinHistory([rounds[30], olderRoundSpinsLater])[0].id, 1n);
});
