const { chromium, webkit } = await import(process.argv[2] ?? "playwright");
const { default: AxeBuilder } = await import(
  process.argv[3] ?? "@axe-core/playwright"
);
import { writeFile } from "node:fs/promises";
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox"],
});
const context = await browser.newContext({
  viewport: { width: 390, height: 844 },
});
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
await page.goto("http://127.0.0.1:4173/");
await page
  .locator("#round-title")
  .filter({ hasText: /round #/ })
  .waitFor({ timeout: 30000 });
await page.screenshot({ path: "test/scratch/live-mobile.png", fullPage: true });
const live = await page.evaluate(() => ({
  scrollWidth: document.documentElement.scrollWidth,
  width: innerWidth,
  button: document
    .querySelector("button[type=submit]")
    .getBoundingClientRect()
    .toJSON(),
  spin: document.querySelector(".spin-button").getBoundingClientRect().toJSON(),
  body: document.body.innerText,
}));
const results = { live, errors, checks: [] };
const check = (name, passed) => {
  results.checks.push({ name, passed });
  if (!passed) throw new Error(name);
};
check(
  "live app reads without a wallet",
  live.body.includes("round #") && live.body.includes("in the pool"),
);
check("main action visible at 390", live.button.bottom < 776);
const axe = await new AxeBuilder({ page }).analyze();
results.axe = {
  violations: axe.violations.map((x) => ({
    id: x.id,
    impact: x.impact,
    description: x.description,
    nodes: x.nodes.map((n) => n.target),
  })),
};
await page.getByRole("button", { name: "connect", exact: true }).click();
check("wallet sheet opens", await page.getByRole("dialog").isVisible());
await page.keyboard.press("Escape");
check(
  "wallet sheet closes on Escape",
  !(await page.getByRole("dialog").count()),
);
await page.goto("http://127.0.0.1:4173/?demo=1#history");
check(
  "sample mode is labelled",
  await page
    .getByText("preview · sample events, transactions disabled")
    .isVisible(),
);
check(
  "history paginates at 25",
  (await page.locator(".history-row").count()) === 25,
);
await page.getByRole("button", { name: "next", exact: true }).click();
check(
  "second page contains remaining six",
  (await page.locator(".history-row").count()) === 6,
);
await page.getByRole("button", { name: "kept", exact: true }).click();
check("kept filter", (await page.locator(".history-row").count()) === 21);
await page.getByRole("button", { name: "eth", exact: true }).click();
check("ETH filter", (await page.locator(".history-row").count()) === 10);
await page.getByRole("button", { name: "awaiting sale", exact: true }).click();
check(
  "awaiting sale filter",
  (await page.locator(".history-row").count()) === 10,
);
await page.locator(".history-main").first().click();
check(
  "round detail shows all event fields",
  (await page.locator(".timeline>li").count()) >= 6,
);
await page.keyboard.press("Escape");
await page.locator('.bottom-nav a[href="#mine"]').click();
check(
  "mine claims are exact",
  (
    await page
      .locator(".mine-row")
      .filter({ hasText: "round #31" })
      .locator(".exact-amount")
      .innerText()
  )
    .replace(/\s+/g, " ")
    .trim() === "0.02764 ETH",
);
await page.locator('.bottom-nav a[href="#info"]').click();
await page.getByText("the team sale step", { exact: true }).waitFor();
check(
  "trust and sale queue visible",
  (await page.getByText("the team sale step", { exact: true }).isVisible()) &&
    (await page.locator(".awaiting-row").count()) === 10,
);
for (const width of [320, 360, 390, 760, 1440]) {
  await page.setViewportSize({ width, height: 900 });
  for (const tab of ["spin", "history", "mine", "info"]) {
    await page.goto(`http://127.0.0.1:4173/?demo=1#${tab}`);
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth > innerWidth,
    );
    check(`no overflow ${tab} at ${width}`, !overflow);
  }
}
await page.setViewportSize({ width: 1440, height: 1000 });
await page.goto("http://127.0.0.1:4173/?demo=1");
await page
  .locator(".win-reveal")
  .evaluate((e) => Promise.all(e.getAnimations().map((a) => a.finished)));
await page.screenshot({
  path: "test/scratch/demo-desktop.png",
  fullPage: true,
});
await page.setViewportSize({ width: 390, height: 844 });
await page.goto("http://127.0.0.1:4173/?demo=1");
await page
  .locator(".win-reveal")
  .evaluate((e) => Promise.all(e.getAnimations().map((a) => a.finished)));
await page.screenshot({ path: "test/scratch/demo-mobile.png", fullPage: true });
await page.emulateMedia({ reducedMotion: "reduce" });
check(
  "reduced motion disables win reveal",
  (await page
    .locator(".win-reveal")
    .evaluate((e) => getComputedStyle(e).animationName)) === "none",
);
const inApp = await browser.newContext({
  viewport: { width: 390, height: 844 },
  isMobile: true,
  hasTouch: true,
});
await inApp.addInitScript(() => {
  window.ethereum = { request: async () => [], on() {}, removeListener() {} };
});
const appPage = await inApp.newPage();
await appPage.goto("http://127.0.0.1:4173/?demo=1");
await appPage.getByRole("button", { name: "connect", exact: true }).click();
check(
  "generic injected provider stays available in mobile wallet browsers",
  await appPage
    .getByRole("button", { name: "browser wallet", exact: false })
    .isVisible(),
);
await inApp.close();
try {
  const w = await webkit.launch({ headless: true });
  await w.close();
  results.webkit = "launched";
} catch {
  results.webkit = "unavailable: browser runtime could not launch";
}
await writeFile(
  "test/scratch/browser-results.json",
  JSON.stringify(results, null, 2),
);
console.log(
  JSON.stringify(
    {
      checks: results.checks,
      axe: results.axe,
      errors,
      webkit: results.webkit,
    },
    null,
    2,
  ),
);
await browser.close();
