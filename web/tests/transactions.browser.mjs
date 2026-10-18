import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import {
  decodeFunctionData,
  encodeFunctionResult,
  encodeEventTopics,
  encodeAbiParameters,
  encodeErrorResult,
  toHex,
} from "viem";
import { abi, routerABI, fwaABI, vault, router } from "../src/config";
import { fixtureSnapshot, fixtureEvents } from "../src/fixtures";
const { chromium } = await import(process.argv[2] ?? "playwright");
const testNow = Math.floor(Date.now() / 864e5) * 86400 + 36e3;
const sample = fixtureSnapshot(testNow);
sample.rounds.at(-1).cash = sample.target;
const hash = sample.rounds[0].events[0].transactionHash;
const allEvents = fixtureEvents(testNow);
const artifacts = Object.fromEntries(
  await Promise.all(
    ["KeelSpinVault", "KeelFwaRouter"].map(async (name) => [
      name,
      JSON.parse(
        await readFile(
          new URL(
            `../../test/scratch/contracts/${name}.sol/${name}.json`,
            import.meta.url,
          ),
          "utf8",
        ),
      ),
    ]),
  ),
);
let sent = 0,
  reject = false,
  simulationError = false,
  claimReadValue = 12345678901234567n,
  receiptReady = false,
  emptyHistory = false,
  readFailure = false;
const calls = [];
let unlockReceipt;
const receiptGate = new Promise((resolve) => {
  unlockReceipt = resolve;
});
let unlockSimulation;
const simulationGate = new Promise((resolve) => {
  unlockSimulation = resolve;
});
function result(abi2, functionName, value) {
  return encodeFunctionResult({ abi: abi2, functionName, result: value });
}
const params = sample.params;
const block = {
  number: toHex(sample.block),
  hash,
  parentHash: hash,
  timestamp: toHex(testNow),
  gasLimit: toHex(3e7),
  gasUsed: toHex(1e6),
  baseFeePerGas: toHex(1e9),
  difficulty: "0x0",
  extraData: "0x",
  miner: vault,
  mixHash: hash,
  nonce: "0x0000000000000000",
  sha3Uncles: hash,
  transactionsRoot: hash,
  stateRoot: hash,
  receiptsRoot: hash,
  logsBloom: `0x${"0".repeat(512)}`,
  size: "0x100",
  totalDifficulty: "0x0",
  transactions: [],
  uncles: [],
};
async function rpc(req) {
  calls.push({ method: req.method });
  if (readFailure) throw new Error("review unavailable");
  switch (req.method) {
    case "eth_chainId":
      return "0x1";
    case "eth_blockNumber":
      return toHex(sample.block);
    case "eth_gasPrice":
      return toHex(sample.gas);
    case "eth_getBalance":
      return toHex(10n ** 20n);
    case "eth_getTransactionCount":
      return "0x1";
    case "eth_estimateGas":
      return "0x493e0";
    case "eth_getCode":
      return artifacts[
        String(req.params[0]).toLowerCase() === vault.toLowerCase()
          ? "KeelSpinVault"
          : "KeelFwaRouter"
      ].deployedBytecode.object;
    case "eth_getBlockByNumber":
      return {
        ...block,
        number: req.params[0] === "latest" ? block.number : req.params[0],
      };
    case "eth_getLogs": {
      if (emptyHistory) return [];
      const filter = req.params[0];
      return allEvents
        .filter(
          (e) =>
            e.blockNumber >= BigInt(filter.fromBlock) &&
            e.blockNumber <= BigInt(filter.toBlock),
        )
        .map((e) => {
          const a = abi.find(
            (a2) => a2.type === "event" && a2.name === e.eventName,
          );
          return {
            address: vault,
            blockHash: hash,
            blockNumber: toHex(e.blockNumber),
            data: encodeAbiParameters(
              a.inputs.filter((i) => !i.indexed),
              a.inputs.filter((i) => !i.indexed).map((i) => e.args[i.name]),
            ),
            topics: encodeEventTopics({
              abi: [a],
              eventName: a.name,
              args: e.args,
            }),
            transactionHash: hash,
            transactionIndex: "0x0",
            logIndex: toHex(e.logIndex + Number(e.args.roundId) * 100),
            removed: false,
          };
        });
    }
    case "eth_call": {
      const call = req.params[0];
      const contractABI =
        call.to.toLowerCase() === vault.toLowerCase()
          ? abi
          : call.to.toLowerCase() === router.toLowerCase()
            ? routerABI
            : fwaABI;
      const decoded = decodeFunctionData({ abi: contractABI, data: call.data }),
        f = decoded.functionName,
        args = decoded.args ?? [];
      calls.push({ method: "call", functionName: f, args });
      const values = {
        ...params,
        currentRoundId: sample.currentId,
        roundCount: 32n,
        activeRoundId: 0n,
        liveTarget: sample.target,
        effectiveSpinReward: sample.reward,
        quoteAcquisitionPrice: [sample.quote, 0n, sample.quote],
        isPurchaseBlackout: false,
        vault,
        pool: params.fwa,
      };
      if (f === "rounds")
        return result(
          abi,
          f,
          sample.rounds.find((r) => r.id === args[0]),
        );
      if (f === "stake") return result(abi, f, parseStake(args[0]));
      if (f === "claimable") return result(abi, f, claimReadValue);
      if (f === "withdrawable") return result(abi, f, parseStake(args[0]));
      if (f === "listings")
        throw new Error("metadata is intentionally unavailable in this test");
      if (f in values) return result(contractABI, f, values[f]);
      if (["bet", "spin", "claim", "withdraw"].includes(f)) {
        if (f === "bet") await simulationGate;
        if (simulationError)
          return {
            rpcError: {
              code: 3,
              message: "execution reverted",
              data: encodeErrorResult({ abi, errorName: "GasPriceTooHigh" }),
            },
          };
        return "0x";
      }
      throw new Error(`unexpected eth_call ${f}`);
    }
    case "eth_getTransactionReceipt":
      await receiptGate;
      return sent && receiptReady
        ? {
            transactionHash: hash,
            transactionIndex: "0x0",
            blockHash: hash,
            blockNumber: toHex(sample.block),
            from: vault,
            to: vault,
            cumulativeGasUsed: "0x493e0",
            gasUsed: "0x493e0",
            effectiveGasPrice: toHex(sample.gas),
            contractAddress: null,
            logs: [],
            logsBloom: `0x${"0".repeat(512)}`,
            status: "0x1",
            type: "0x0",
          }
        : null;
    case "eth_getTransactionByHash":
      return null;
    default:
      throw new Error(`unexpected RPC ${req.method}`);
  }
}
function parseStake(id) {
  return sample.rounds.find((r) => r.id === id)?.walletStake ?? 0n;
}
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox"],
});
const context = await browser.newContext({
  viewport: { width: 390, height: 844 },
  isMobile: true,
  hasTouch: true,
});
await context.addInitScript(
  ({ vault: vault2, hash: hash2 }) => {
    let connected = false;
    const provider = {
      on() {},
      removeListener() {},
      async request({ method }) {
        if (method === "eth_chainId") return "0x1";
        if (method === "eth_accounts") return connected ? [vault2] : [];
        if (method === "eth_requestAccounts") {
          connected = true;
          return [vault2];
        }
        if (method === "wallet_requestPermissions")
          return [{ parentCapability: "eth_accounts" }];
        if (method === "wallet_getCapabilities") return {};
        if (method === "eth_sendTransaction") {
          const response = await fetch("/__wallet_send", { method: "POST" });
          const data = await response.json();
          if (data.rejected)
            throw Object.assign(new Error("User rejected the request"), {
              code: 4001,
            });
          return hash2;
        }
        throw new Error(`unexpected wallet method ${method}`);
      },
    };
    Object.defineProperty(window, "ethereum", { value: provider });
    addEventListener("eip6963:requestProvider", () =>
      dispatchEvent(
        new CustomEvent("eip6963:announceProvider", {
          detail: {
            info: {
              uuid: "3c18d774-2d27-42aa-9d19-f28870d89edf",
              name: "test wallet",
              icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg"/>',
              rdns: "test.keel.wallet",
            },
            provider,
          },
        }),
      ),
    );
  },
  { vault, hash },
);
const page = await context.newPage();
await page.route("**/__wallet_send", async (route) => {
  if (reject) return route.fulfill({ json: { rejected: true } });
  sent++;
  return route.fulfill({ json: { hash } });
});
await page.route(
  /https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?$/,
  async (route) => {
    const request = route.request().postDataJSON();
    const run = async (r) => {
      try {
        const value = await rpc(r);
        if (value && typeof value === "object" && "rpcError" in value)
          return { id: r.id, jsonrpc: "2.0", error: value.rpcError };
        return { id: r.id, jsonrpc: "2.0", result: value };
      } catch (e) {
        return {
          id: r.id,
          jsonrpc: "2.0",
          error: {
            code: -32e3,
            message: e instanceof Error ? e.message : "mock error",
          },
        };
      }
    };
    await route.fulfill({
      json: Array.isArray(request)
        ? await Promise.all(request.map(run))
        : await run(request),
    });
  },
);
const passed = [];
try {
  await page.goto("http://127.0.0.1:4173/");
  await page.getByText("round #32", { exact: true }).waitFor();
  await page.getByRole("button", { name: "connect", exact: true }).click();
  await page.getByRole("button", { name: "test wallet", exact: false }).click();
  await page.getByRole("button", { name: "add ETH", exact: false }).waitFor();
  await page.locator("#bet").fill("0.0001");
  await page.getByRole("button", { name: "add ETH", exact: false }).click();
  await page.getByText("minimum bet is 0.001 ETH", { exact: true }).waitFor();
  assert.equal(sent, 0);
  passed.push("invalid bet is blocked with an inline error");
  await page.locator("#bet").fill("0.01");
  await page.getByRole("button", { name: "add ETH", exact: false }).click();
  await page.getByText("checking transaction…", { exact: true }).waitFor();
  const dismiss = page.getByRole("button", {
    name: "dismiss transaction status",
  });
  assert.ok(await dismiss.isDisabled());
  await dismiss.evaluate((button) => button.click());
  assert.equal(await page.locator(".tx-status").count(), 1);
  assert.ok(await page.locator('button[type="submit"]').isDisabled());
  assert.equal(sent, 0);
  passed.push("simulation status cannot be dismissed or unlock another payment");
  unlockSimulation();
  await page.getByText("transaction pending", { exact: true }).waitFor();
  assert.equal(sent, 1);
  passed.push("bet is simulated, then sent, then shown pending");
  assert.ok(await dismiss.isDisabled());
  await dismiss.evaluate((button) => button.click());
  assert.equal(await page.locator(".tx-status").count(), 1);
  assert.ok(await page.locator('button[type="submit"]').isDisabled());
  await page.locator('button[type="submit"]').evaluate((button) => button.click());
  assert.equal(sent, 1);
  assert.equal(
    await page.locator(".tx-status a").getAttribute("href"),
    `https://etherscan.io/tx/${hash}`,
  );
  passed.push("pending status, explorer link and payment lock survive dismissal attempts");
  const sendIndex = calls.findIndex((c) => c.functionName === "bet");
  assert.ok(sendIndex >= 0);
  receiptReady = true;
  sample.block++;
  block.number = toHex(sample.block);
  unlockReceipt();
  await page
    .getByText("transaction confirmed", { exact: true })
    .waitFor({ timeout: 15e3 });
  passed.push("confirmation refreshes contract data and links Etherscan");
  assert.ok(
    (await page.locator(".tx-status a").getAttribute("href")) ===
      `https://etherscan.io/tx/${hash}`,
  );
  assert.ok(await dismiss.isEnabled());
  await page
    .getByRole("button", { name: "dismiss transaction status" })
    .click();
  await page.locator('.bottom-nav a[href="#mine"]').click();
  await page.locator(".exact-amount").first().waitFor();
  await page.waitForFunction(() =>
    [...document.querySelectorAll(".mine-row")]
      .find((e) => e.textContent.includes("round #31"))
      ?.querySelector(".exact-amount")
      ?.textContent.includes("0.012345678901234567"),
  );
  assert.ok(
    (
      await page
        .locator(".mine-row")
        .filter({ hasText: "round #31" })
        .locator(".exact-amount")
        .innerText()
    ).includes("0.012345678901234567"),
  );
  passed.push(
    "claim text preserves all 18 decimals returned by claimable, without local share arithmetic",
  );
  await page
    .locator(".mine-row")
    .filter({ hasText: "round #31" })
    .getByRole("button", { name: "claim ETH", exact: true })
    .click();
  await page
    .getByText("transaction confirmed", { exact: true })
    .waitFor({ timeout: 15e3 });
  assert.ok(
    calls.some((c) => c.functionName === "claim" && c.args?.[0] === 31n),
  );
  passed.push("claim simulates the selected round before sending");
  await page
    .getByRole("button", { name: "dismiss transaction status" })
    .click();
  await page.locator('.bottom-nav a[href="#spin"]').click();
  await page
    .getByRole("button", { name: "spin the pool", exact: true })
    .click();
  await page
    .getByText("transaction confirmed", { exact: true })
    .waitFor({ timeout: 15000 });
  assert.ok(calls.some((c) => c.functionName === "spin" && c.args[0] === 32n));
  passed.push("a funded round simulates and sends the selected spin");
  await page
    .getByRole("button", { name: "dismiss transaction status" })
    .click();
  reject = true;
  await page.getByRole("button", { name: "add ETH", exact: false }).click();
  await page
    .getByText("The wallet request was cancelled.", { exact: true })
    .waitFor();
  assert.equal(sent, 3);
  passed.push("wallet rejection is a recoverable failed state");
  assert.ok(await dismiss.isEnabled());
  await page
    .getByRole("button", { name: "dismiss transaction status" })
    .click();
  reject = false;
  simulationError = true;
  await page.getByRole("button", { name: "add ETH", exact: false }).click();
  await page
    .getByText("Gas is above the vault limit. Try again when it falls.", {
      exact: true,
    })
    .waitFor();
  assert.equal(sent, 3);
  passed.push(
    "decoded simulation errors prevent the wallet send and explain the contract failure",
  );
  emptyHistory = true;
  await page.evaluate(() => localStorage.clear());
  await page.reload();
  await page.getByText("round #32", { exact: true }).waitFor();
  assert.ok(await page.getByText("No spins recorded yet.", { exact: true }).isVisible());
  assert.ok(await page.getByText("a quiet start", { exact: true }).isVisible());
  await page.locator('.bottom-nav a[href="#history"]').click();
  assert.ok((await page.locator(".feed-header").innerText()).startsWith("0 spins"));
  assert.ok(await page.getByText("no spins here yet", { exact: true }).isVisible());
  passed.push("a successful empty snapshot still shows a verified zero and empty states");
  readFailure = true;
  await page.getByText("chain connection interrupted", { exact: true }).waitFor({ timeout: 25000 });
  assert.ok((await page.locator(".feed-header").innerText()).startsWith("0 spins"));
  assert.ok(await page.getByText("no spins here yet", { exact: true }).isVisible());
  assert.equal(await page.getByText("spin history unavailable", { exact: true }).count(), 0);
  passed.push("later read failure retains the last successful snapshot with its connection warning");
  await writeFile(
    "test/scratch/transaction-results.json",
    JSON.stringify(
      {
        passed,
        sent,
        simulated: calls
          .filter((c) => c.method === "call")
          .map((c) => c.functionName),
      },
      null,
      2,
    ) + "\n",
  );
  console.log(JSON.stringify({ passed, sent }, null, 2));
} catch (e) {
  console.log(
    "test state:",
    await page
      .locator(".tx-status")
      .innerText()
      .catch(() => "no transaction status"),
  );
  console.log("last mock calls:", calls.slice(-20));
  throw e;
} finally {
  await browser.close();
}
