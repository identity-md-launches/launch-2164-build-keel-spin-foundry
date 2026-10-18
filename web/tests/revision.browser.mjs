import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
const { chromium } = await import(process.argv[2] ?? "playwright");
const { default: AxeBuilder } = await import(
  process.argv[3] ?? "@axe-core/playwright"
);
const handoff = JSON.parse(
  await readFile(new URL("../src/contracts/deployment.json", import.meta.url), "utf8"),
);
const rpcPattern = /https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?$/;
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const checks = [], errors = [], scans = [];
const check = (name, passed) => {
  checks.push({ name, passed });
  assert.ok(passed, name);
};
const text = async (locator) => (await locator.innerText()).replace(/\s+/g, " ").trim();
try {
  const context = await browser.newContext({ viewport: { width: 360, height: 800 } });
  const page = await context.newPage();
  page.on("pageerror", (error) => errors.push(error.message));
  const scan = async (name) => {
    const names = await new AxeBuilder({ page })
      .withRules(["label-content-name-mismatch"]).analyze();
    const all = await new AxeBuilder({ page }).include("main").analyze();
    scans.push({ name, labelViolations: names.violations, violations: all.violations });
    check(`${name}: no visible-label violations or axe violations in main`,
      names.violations.length === 0 && all.violations.length === 0);
  };
  await page.goto("http://127.0.0.1:4173/?demo=1#history");
  await page.locator(".history-main").first().waitFor();
  check("history shows 25 spins per page", await page.locator(".history-main").count() === 25);
  check("visible NFT, token, round and outcome name the history button",
    await page.getByRole("button", { name: /sample collection #8031.*round #31.*sold/ }).count() === 1);
  await scan("history at 360");
  const row = page.locator(".history-main").first();
  await row.focus();
  await page.keyboard.press("Enter");
  const event = (name) => page.locator(".timeline > li").filter({
    has: page.locator(".section-head > strong", { hasText: new RegExp(`^${name}$`) }),
  });
  const field = (name, key, index = 0) => event(name).nth(index)
    .locator(".event-args > div").filter({
      has: page.locator("dt", { hasText: new RegExp(`^${key}$`) }),
    }).locator("dd");
  check("bet, quote, reward, sale, distribution and fee carry ETH units",
    await text(field("bet placed", "amount")) === "0.02 ETH" &&
    await text(field("bet placed", "shares")) === "0.02 ETH" &&
    await text(field("spin requested", "quote")) === "0.09 ETH" &&
    await text(field("spin requested", "reward")) === "0.0018 ETH" &&
    await text(field("sale proceeds", "amount")) === "0.13 ETH" &&
    await text(field("round settled", "distributable")) === "0.1382 ETH" &&
    await text(field("round settled", "fee")) === "0 ETH");
  const deadline = field("allocation recorded", "deadline").locator("time");
  const iso = await deadline.getAttribute("datetime");
  check("allocation deadline is relative with an exact UTC hover",
    /ago|just now|^in /.test(await deadline.innerText()) &&
    await deadline.getAttribute("title") === new Date(iso).toUTCString());
  check("round-state and decision-path values have plain labels",
    await text(field("round state changed", "state", 0)) === "waiting for randomness" &&
    await text(field("round state changed", "state", 1)) === "deciding" &&
    await text(field("round state changed", "state", 2)) === "awaiting sale" &&
    await text(field("decision", "path")) === "pre-check");
  check("token IDs, listing IDs, request IDs, addresses and hashes stay intact",
    await text(field("allocation recorded", "token id")) === "8031" &&
    await text(field("allocation recorded", "listing id")) === "31" &&
    await text(field("spin requested", "request id")) === "31" &&
    await text(field("bet placed", "bettor")) === handoff.contracts[0].address &&
    await text(field("sale proceeds", "sale tx hash")) === handoff.contracts[0].txHash);
  await page.keyboard.press("Escape");
  check("detail sheet restores keyboard focus", await row.evaluate((el) => el === document.activeElement));
  await page.getByRole("button", { name: /sample collection #8027.*round #27/ }).click();
  check("oracle expiry uses relative time with an exact UTC hover",
    /GMT$/.test(await field("oracle value stored", "expires at").locator("time").getAttribute("title")));
  check("oracle value is ETH and oracle path is labelled",
    await text(field("oracle value stored", "net offer")) === "0.12 ETH" &&
    await text(field("decision", "path")) === "oracle");
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "next", exact: true }).click();
  check("history second page has six spins", await page.locator(".history-main").count() === 6);
  for (const [name, expected] of [["kept", 21], ["eth", 10], ["awaiting sale", 10], ["mine", 31]]) {
    await page.getByRole("button", { name, exact: true }).click();
    check(`${name} filter paginates its results`,
      await page.locator(".history-main").count() === Math.min(25, expected) &&
      (await text(page.locator(".feed-header"))).startsWith(`${expected} spins`));
  }
  await page.locator('.bottom-nav a[href="#spin"]').click();
  check("recent spins use the visible NFT name too",
    await page.getByRole("button", { name: /sample collection #8031.*round #31.*sold/ }).count() === 1);
  await scan("recent spins at 360");
  await page.emulateMedia({ reducedMotion: "reduce" });
  check("reduced motion stops the allocation reveal",
    await page.locator(".win-reveal").evaluate((el) => getComputedStyle(el).animationName) === "none");
  for (const width of [320, 360, 390, 760, 1440]) {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    for (const tab of ["spin", "history", "mine", "info"]) {
      await page.goto(`http://127.0.0.1:4173/?demo=1#${tab}`);
      await page.locator("main").waitFor();
      check(`${tab} has no horizontal overflow at ${width}`,
        await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      if (width === 390 && tab === "spin") {
        check("main action appears on the first 390px screen",
          await page.locator('button[type="submit"]').evaluate((el) => el.getBoundingClientRect().bottom < 776));
        await page.screenshot({ path: "test/scratch/revision-mobile.png" });
      }
      if (width === 1440 && tab === "spin")
        await page.screenshot({ path: "test/scratch/revision-desktop.png" });
    }
  }
  await page.setViewportSize({ width: 360, height: 800 });
  await page.goto("http://127.0.0.1:4173/?demo=1#history");
  await page.locator(".history-main").first().click();
  check("round detail sheet does not overflow at 360",
    await page.getByRole("dialog").evaluate((el) => el.scrollWidth <= el.clientWidth));
  await page.screenshot({ path: "test/scratch/revision-timeline.png" });
  await page.getByRole("dialog").getByText("deadline", { exact: true }).scrollIntoViewIfNeeded();
  await page.screenshot({ path: "test/scratch/revision-deadline.png" });

  const unavailable = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const offline = await unavailable.newPage();
  offline.on("pageerror", (error) => errors.push(error.message));
  let releaseErrors;
  const errorGate = new Promise((resolve) => { releaseErrors = resolve; });
  await offline.route(rpcPattern, async (route) => {
    await errorGate;
    const req = route.request().postDataJSON();
    const fail = (r) => ({ jsonrpc: "2.0", id: r.id, error: { code: -32000, message: "review unavailable" } });
    await route.fulfill({ json: Array.isArray(req) ? req.map(fail) : fail(req) });
  });
  await offline.goto("http://127.0.0.1:4173/#history");
  await offline.getByText("reading the full history", { exact: true }).waitFor();
  check("history count stays unknown while the first read is pending",
    (await text(offline.locator(".feed-header"))).startsWith("— spins") &&
    await offline.getByText("no spins here yet", { exact: true }).count() === 0);
  releaseErrors();
  await offline.getByText("Ethereum is unavailable", { exact: true }).waitFor({ timeout: 45000 });
  check("failed first read reports unavailable history and an unknown count",
    await offline.getByText("spin history unavailable", { exact: true }).isVisible() &&
    await offline.getByText("Retry the Ethereum connection.", { exact: true }).isVisible() &&
    (await text(offline.locator(".feed-header"))).startsWith("— spins") &&
    await offline.getByText("no spins here yet", { exact: true }).count() === 0);
  const retryRequest = offline.waitForRequest((request) => rpcPattern.test(request.url()));
  await offline.getByRole("button", { name: "retry", exact: true }).click();
  await retryRequest;
  check("retry makes another Ethereum request", true);
  await offline.locator('.bottom-nav a[href="#spin"]').click();
  check("latest and recent spins report unavailable rather than verified emptiness",
    await offline.getByText("latest spin unavailable", { exact: true }).isVisible() &&
    (await text(offline.locator(".quiet-row"))).includes("Spin history unavailable.") &&
    !(await text(offline.locator("main"))).includes("No spins recorded yet.") &&
    !(await text(offline.locator("main"))).includes("a quiet start"));
  await offline.screenshot({ path: "test/scratch/revision-unavailable.png", fullPage: true });
  await offline.locator(".latest-panel").scrollIntoViewIfNeeded();
  await offline.screenshot({ path: "test/scratch/revision-unavailable-latest.png" });
  check("no uncaught page errors", errors.length === 0);
  console.log(JSON.stringify({ checks, scans: scans.map(({ name, labelViolations, violations }) => ({ name, labelViolations: labelViolations.length, violations: violations.length })), errors }, null, 2));
} finally {
  await writeFile("test/scratch/revision-results.json", JSON.stringify({ checks, scans, errors }, null, 2) + "\n");
  await browser.close();
}
