import {
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  type FormEvent,
  type ReactNode,
} from "react";
import { useAccount, useWalletClient } from "wagmi";
import { formatGwei, parseEther, type Hash } from "viem";
import { addressLink, chain, router, txLink, vault } from "./config";
import {
  getStore,
  plainError,
  refresh,
  sendAction,
  setWallet,
  start,
  subscribe,
  type Action,
} from "./chain";
import {
  blackoutWindow,
  betError,
  countdown,
  decisionActions,
  eth,
  exactETH,
  pathLabel,
  relative,
  returnRate,
  short,
  spinReason,
  spinHistory,
  type SpinEntry,
  type ChainEvent,
  status,
  stateLabel,
  State,
  type Round,
  type Snapshot,
} from "./model";
import { fixtureSnapshot } from "./fixtures";
import { Fawn, Icon, NFTArt } from "./components/Icons";
import { Dialog } from "./components/Dialog";
import { WalletControl, WalletSheet } from "./components/Wallet";
type Tab = "spin" | "history" | "mine" | "info";
type Tx = {
  action: Action;
  id?: bigint;
  phase: "simulating" | "pending" | "confirmed" | "failed";
  hash?: Hash;
  error?: string;
};
const tabs: Tab[] = ["spin", "history", "mine", "info"];
const isDemo = new URLSearchParams(location.search).get("demo") === "1";
const sample = isDemo ? fixtureSnapshot() : undefined;
function Amount({
  value,
  unit = "ETH",
  exact = false,
}: {
  value?: bigint;
  unit?: string;
  exact?: boolean;
}) {
  return (
    <span
      className="amount"
      title={value !== undefined ? `${exactETH(value)} ${unit}` : undefined}
    >
      {exact && value !== undefined ? exactETH(value) : eth(value)}
      <span className="unit"> {unit}</span>
    </span>
  );
}
function Time({ timestamp, now }: { timestamp?: number; now: number }) {
  return timestamp ? (
    <time
      dateTime={new Date(timestamp * 1000).toISOString()}
      title={new Date(timestamp * 1000).toUTCString()}
    >
      {timestamp > now
        ? `in ${countdown(timestamp - now)}`
        : relative(timestamp, now)}
    </time>
  ) : (
    <span>—</span>
  );
}
function ELink({ hash, children }: { hash: string; children: ReactNode }) {
  return (
    <a href={txLink(hash)} target="_blank" rel="noreferrer">
      {children}
      <Icon name="arrow" size={14} />
    </a>
  );
}
function Empty({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="empty">
      <Fawn />
      <h3>{title}</h3>
      <p className="muted">{children}</p>
    </div>
  );
}
export default function App() {
  const live = useSyncExternalStore(subscribe, getStore),
    s = sample ?? live.snapshot;
  const { address, chainId, isConnected } = useAccount(),
    { data: walletClient } = useWalletClient();
  const [tab, setTab] = useState<Tab>(() =>
    tabs.includes(location.hash.slice(1) as Tab)
      ? (location.hash.slice(1) as Tab)
      : "spin",
  );
  const [walletOpen, setWalletOpen] = useState(false),
    [detail, setDetail] = useState<bigint>(),
    [tx, setTx] = useState<Tx>(),
    [now, setNow] = useState(Math.floor(Date.now() / 1000));
  const [bet, setBet] = useState("0.01"),
    [formError, setFormError] = useState(""),
    [filter, setFilter] = useState("all"),
    [page, setPage] = useState(1);
  useEffect(() => {
    if (!isDemo) start();
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    const hash = () =>
      setTab(
        tabs.includes(location.hash.slice(1) as Tab)
          ? (location.hash.slice(1) as Tab)
          : "spin",
      );
    addEventListener("hashchange", hash);
    return () => {
      clearInterval(id);
      removeEventListener("hashchange", hash);
    };
  }, []);
  useEffect(() => {
    if (!isDemo) setWallet(address);
  }, [address]);
  const current = s?.rounds.find((r) => r.id === s.currentId);
  const historyUnavailable = !s && !!live.error;
  const spins = useMemo(() => spinHistory(s?.rounds ?? []), [s]);
  const latest = spins[0];
  const joined =
    s?.rounds
      .filter(
        (r) =>
          r.participants.includes(
            (isDemo ? vault : (address ?? "")).toLowerCase(),
          ) || r.walletStake > 0n,
      )
      .sort((a, b) => (a.id > b.id ? -1 : 1)) ?? [];
  const [spinId, setSpinId] = useState<bigint>();
  const openFunded =
    s?.rounds
      .filter((r) => r.state === State.Open && r.totalShares > 0n)
      .sort((a, b) => {
        const aReady = a.cash >= s.quote + s.reward;
        const bReady = b.cash >= s.quote + s.reward;
        return aReady !== bReady ? (aReady ? -1 : 1) : a.id < b.id ? -1 : 1;
      }) ?? [];
  const spinRound =
    s?.rounds.find((r) => r.id === spinId && r.state === State.Open) ??
    openFunded[0] ??
    current;
  const clock = s
    ? s.timestamp + Math.max(0, Math.floor((now * 1000 - s.receivedAt) / 1000))
    : now;
  const stale = !!s && now * 1000 - s.receivedAt > 60_000 && !isDemo;
  const reason = stale
    ? "live data is stale; refresh before spinning"
    : spinReason(s, spinRound, clock);
  const pending = tx?.phase === "pending" || tx?.phase === "simulating";
  const writeReady =
    !!s && !stale && s.verified && s.wiring && !isDemo && !pending;
  const wrongChain = isConnected && chainId !== chain.id;
  async function act(action: Action, id?: bigint, value?: bigint) {
    if (isDemo) return;
    if (!isConnected || !address || !walletClient) {
      setWalletOpen(true);
      return;
    }
    if (wrongChain) {
      setWalletOpen(true);
      return;
    }
    if (!writeReady) return;
    setTx({ action, id, phase: "simulating" });
    let hash: Hash | undefined;
    try {
      const receipt = await sendAction(
        walletClient,
        address,
        action,
        id,
        value,
        (h) => {
          hash = h;
          setTx({ action, id, phase: "pending", hash: h });
        },
      );
      setTx({ action, id, phase: "confirmed", hash: receipt });
    } catch (e) {
      setTx({ action, id, phase: "failed", hash, error: plainError(e) });
    }
  }
  function submit(e: FormEvent) {
    e.preventDefault();
    if (!s) return;
    const error = betError(bet, s.params.minBet);
    setFormError(error ?? "");
    if (error) return;
    void act("bet", undefined, parseEther(bet));
  }
  useEffect(() => {
    document.querySelector(".app-shell")?.scrollTo({ top: 0 });
    window.scrollTo({ top: 0 });
  }, [tab]);
  function nav(t: Tab) {
    location.hash = t;
    setTab(t);
  }
  const history = useMemo(() => {
    const rows = spins;
    return rows.filter(
      (r) =>
        filter === "all" ||
        (filter === "kept" && r.kept) ||
        (filter === "eth" && r.state === State.Settled && !r.kept) ||
        (filter === "awaiting sale" && r.state === State.AwaitingSale) ||
        (filter === "mine" &&
          r.participants.includes(
            (isDemo ? vault : (address ?? "")).toLowerCase(),
          )),
    );
  }, [spins, filter, address]);
  const selected = s?.rounds.find((r) => r.id === detail);
  function actionButton(action: Action, id: bigint, label: string) {
    return (
      <button
        className="button"
        disabled={!writeReady || wrongChain}
        onClick={() => void act(action, id)}
      >
        {pending && tx?.action === action && tx.id === id ? "working…" : label}
      </button>
    );
  }
  return (
    <>
      <a
        className="skip"
        href="#main"
        onClick={(e) => {
          e.preventDefault();
          document.getElementById("main")?.focus();
        }}
      >
        skip to content
      </a>
      <div className="app-shell">
        <header className="header">
          <a href="#spin" className="brand" aria-label="Keel Spin home">
            <span className="brand-leaf">
              <Icon name="leaf" size={28} />
            </span>
            <span>
              keel<span className="brand-light"> spin</span>
            </span>
          </a>
          <nav className="desktop-nav" aria-label="main">
            {tabs.map((t) => (
              <a
                key={t}
                href={`#${t}`}
                aria-current={tab === t ? "page" : undefined}
              >
                {t}
              </a>
            ))}
          </nav>
          <WalletControl onOpen={() => setWalletOpen(true)} />
        </header>
        {isDemo && (
          <div className="preview-banner">
            preview · sample events, transactions disabled{" "}
            <a href={location.pathname}>
              view live app <Icon name="arrow" size={14} />
            </a>
          </div>
        )}
        <main id="main" tabIndex={-1}>
          <div className="page-heading">
            <div>
              <h1>
                {tab === "spin"
                  ? "a shared spin."
                  : tab === "history"
                    ? "every spin, onchain."
                    : tab === "mine"
                      ? "your part of the pool."
                      : "a clear view."}
              </h1>
              <p className="muted">
                {tab === "spin"
                  ? "Pool ETH for an NFT. Share the return."
                  : tab === "history"
                    ? "From the first bet to the final return."
                    : tab === "mine"
                      ? "Follow your stakes and collect your returns."
                      : "The numbers, the process, the trust."}
              </p>
            </div>
            <span className="network">
              <span className="status-dot" />
              Ethereum
            </span>
          </div>
          {!isDemo && live.error && (
            <div className="notice warning" role="status">
              <div>
                <strong>
                  {s
                    ? "chain connection interrupted"
                    : "Ethereum is unavailable"}
                </strong>
                <p>
                  {live.error}
                  {s ? " Showing the last successful read." : ""}
                </p>
              </div>
              <button className="button" onClick={() => void refresh()}>
                retry
              </button>
            </div>
          )}
          {s && !s.wiring && tab !== "spin" && (
            <div className="notice warning">
              The vault’s router setup is incomplete. Transactions are disabled
              until the team configures it.
            </div>
          )}
          {wrongChain && (
            <div className="notice warning">
              Switch to Ethereum using the wallet control before sending a
              transaction.
            </div>
          )}
          {tab === "spin" && (
            <>
              <div className="spin-layout">
                <section
                  className="round-panel panel"
                  aria-labelledby="round-title"
                >
                  <div className="section-head">
                    <h2 id="round-title">
                      round {current ? `#${current.id}` : "—"}
                    </h2>
                    <span className="badge">
                      {current?.state === State.Open ? "open" : "loading"}
                    </span>
                  </div>
                  <div className="pool-amount">
                    <div>
                      <p className="muted">in the pool</p>
                      <div className="big-number">
                        <Amount value={current?.cash} />
                      </div>
                    </div>
                    <div className="pool-mark" aria-hidden="true">
                      <Icon name="leaf" size={34} />
                    </div>
                  </div>
                  <div className="progress-meta">
                    <span>
                      target <Amount value={s?.target} />
                    </span>
                    <span>
                      {s && current
                        ? `${Math.min(100, Number((current.cash * 1000n) / s.target) / 10).toFixed(1)}%`
                        : "—"}
                    </span>
                  </div>
                  <progress
                    max="100"
                    value={
                      s && current
                        ? Math.min(
                            100,
                            Number((current.cash * 10000n) / s.target) / 100,
                          )
                        : 0
                    }
                    aria-label="round funding"
                  />
                  <div className="round-metrics">
                    <div>
                      <span className="muted">bettors</span>
                      <strong>{current?.bettors ?? "—"}</strong>
                    </div>
                    <div>
                      <span className="muted">your stake</span>
                      <strong>
                        <Amount
                          value={
                            address || isDemo
                              ? current?.withdrawable
                              : undefined
                          }
                        />
                      </strong>
                    </div>
                    <div>
                      <span className="muted">min bet</span>
                      <strong>
                        <Amount value={s?.params.minBet} />
                      </strong>
                    </div>
                  </div>
                  <form onSubmit={submit} noValidate>
                    <label htmlFor="bet">add to the pool</label>
                    <div className={`bet-field ${formError ? "invalid" : ""}`}>
                      <input
                        id="bet"
                        name="bet"
                        type="text"
                        inputMode="decimal"
                        autoComplete="off"
                        value={bet}
                        onChange={(e) => {
                          setBet(e.target.value);
                          setFormError("");
                        }}
                        aria-invalid={!!formError}
                        aria-describedby="bet-help bet-error"
                      />
                      <span>ETH</span>
                      <button
                        type="button"
                        className="min-button"
                        disabled={!s}
                        onClick={() => {
                          if (s) setBet(exactETH(s.params.minBet));
                        }}
                      >
                        min
                      </button>
                    </div>
                    <p id="bet-error" className="error" role="status">
                      {formError}
                    </p>
                    <button
                      className="button primary full"
                      type="submit"
                      disabled={
                        !s ||
                        isDemo ||
                        !!s?.params.betsPaused ||
                        pending ||
                        stale ||
                        !s?.verified ||
                        !s?.wiring ||
                        wrongChain
                      }
                    >
                      {s && !s.wiring
                        ? "betting not open"
                        : s?.params.betsPaused
                          ? "bets are paused"
                          : pending && tx?.action === "bet"
                            ? "adding ETH…"
                            : isConnected
                              ? "add ETH"
                              : "connect to bet"}
                      <Icon name="arrow" size={18} />
                    </button>
                    <p className="fine" id="bet-help">
                      {s && !s.wiring ? (
                        "The team must configure the vault router before betting opens."
                      ) : s?.params.betsPaused ? (
                        "The team has paused new deposits."
                      ) : (
                        <>
                          Excess ETH carries into the next round. Withdraw while
                          open.
                        </>
                      )}
                    </p>
                  </form>
                  {current &&
                    current.walletStake > 0n &&
                    current.state === State.Open && (
                      <button
                        className="text-button"
                        disabled={!writeReady || wrongChain}
                        onClick={() => void act("withdraw", current.id)}
                      >
                        withdraw <Amount value={current.withdrawable} />
                      </button>
                    )}
                  <div className="spin-action">
                    {openFunded.length > 1 && (
                      <label className="select-label">
                        spin round
                        <select
                          value={String(spinRound?.id)}
                          onChange={(e) => setSpinId(BigInt(e.target.value))}
                        >
                          {openFunded.map((r) => (
                            <option key={String(r.id)} value={String(r.id)}>
                              round #{r.id} · {eth(r.cash)} ETH
                            </option>
                          ))}
                        </select>
                      </label>
                    )}
                    <div className="section-head">
                      <span>
                        ready to spin
                        {spinRound && spinRound.id !== current?.id
                          ? ` #${spinRound.id}`
                          : ""}
                        ?
                      </span>
                      <span className="muted">
                        earn <Amount value={s?.reward} />
                      </span>
                    </div>
                    <button
                      className="button spin-button full"
                      disabled={!!reason || !writeReady || wrongChain}
                      onClick={() => void act("spin", spinRound?.id)}
                    >
                      <Icon name="spin" size={20} />
                      {pending && tx?.action === "spin"
                        ? "spinning…"
                        : "spin the pool"}
                    </button>
                    <p className="fine spin-reason">
                      {reason ??
                        (isDemo
                          ? "sample mode · return to the live app to spin"
                          : "Anyone can spin. The caller earns the reward.")}
                    </p>
                    {blackoutWindow(clock).closed && (
                      <p className="fine">
                        opens in {countdown(blackoutWindow(clock).opensIn)}
                      </p>
                    )}
                    {s && s.blackout && !blackoutWindow(clock).closed && (
                      <p className="fine">
                        The protocol blackout is active. UTC window opens in{" "}
                        {countdown(blackoutWindow(clock).closesIn + 900)}; live
                        permission may differ.
                      </p>
                    )}
                  </div>
                </section>
                <div className="spin-side">
                  <section className="latest-panel panel">
                    <div className="section-head">
                      <h2>latest spin</h2>
                      {latest && (
                        <button
                          className="text-button"
                          onClick={() => setDetail(latest.id)}
                        >
                          #{latest.id}
                          <Icon name="arrow" size={14} />
                        </button>
                      )}
                    </div>
                    {latest ? (
                      <>
                        <div
                          className="win-reveal"
                          key={String(latest.listingId)}
                        >
                          <NFTArt
                            image={latest.nft?.image}
                            name={latest.nft?.name}
                          />
                          {latest.listingId > 0n && (
                            <Fawn
                              size={45}
                              style={{
                                position: "absolute",
                                right: 12,
                                bottom: 12,
                              }}
                            />
                          )}
                        </div>
                        <div className="latest-caption">
                          <div>
                            <h3>
                              {latest.listingId > 0n
                                ? (latest.nft?.collectionName ??
                                  short(latest.collection))
                                : latest.refunded
                                  ? "the spin was refunded"
                                  : "the pool is spinning"}
                            </h3>
                            <p className="muted">
                              {latest.listingId > 0n
                                ? `token #${latest.tokenId}`
                                : latest.refunded
                                  ? "remaining ETH stays in the open round"
                                  : "FWA is processing randomness"}
                            </p>
                          </div>
                          <span className="badge">{status(latest)}</span>
                        </div>
                        {latest.listingId > 0n && (
                          <div className="round-metrics two">
                            <div>
                              <span className="muted">backing</span>
                              <strong>
                                <Amount value={latest.backing} />
                              </strong>
                            </div>
                            <div>
                              <span className="muted">ETH bid</span>
                              <strong>
                                <Amount value={latest.bid} />
                              </strong>
                            </div>
                          </div>
                        )}
                        {[
                          State.Allocated,
                          State.OraclePending,
                          State.DecisionReady,
                        ].includes(latest.state) && (
                          <p className="fine">
                            decision deadline{" "}
                            {countdown(Number(latest.deadline) - clock)} ·{" "}
                            {latest.state === State.OraclePending
                              ? "oracle pending"
                              : latest.state === State.DecisionReady
                                ? "oracle done"
                                : "oracle not requested"}
                          </p>
                        )}
                        <div className="decision-actions">
                          {decisionActions(latest, clock).sync && (
                            <div>
                              {actionButton(
                                "syncRound",
                                latest.id,
                                "sync allocation",
                              )}
                              <p className="fine">
                                Bring FWA’s allocation or refund into this
                                round.
                              </p>
                            </div>
                          )}
                          {decisionActions(latest, clock).request && (
                            <div>
                              {actionButton(
                                "requestDecision",
                                latest.id,
                                "request decision",
                              )}
                              <p className="fine">
                                Check the floor first, then ask the oracle using
                                vault IMD.
                              </p>
                            </div>
                          )}
                          {decisionActions(latest, clock).execute && (
                            <div>
                              {actionButton(
                                "executeDecision",
                                latest.id,
                                "execute decision",
                              )}
                              <p className="fine">
                                Apply the valid oracle answer and settle the NFT
                                choice.
                              </p>
                            </div>
                          )}
                          {decisionActions(latest, clock).fallback && (
                            <div>
                              {actionButton(
                                "settleFallback",
                                latest.id,
                                "settle fallback",
                              )}
                              <p className="fine">
                                Use a fresh floor or the vault’s default choice.
                              </p>
                            </div>
                          )}
                        </div>
                        <button
                          className="text-button"
                          onClick={() => setDetail(latest.id)}
                        >
                          view round details
                          <Icon name="chevron" size={16} />
                        </button>
                      </>
                    ) : (
                      <Empty
                        title={
                          !s
                            ? historyUnavailable
                              ? "latest spin unavailable"
                              : "finding the latest spin"
                            : "a quiet start"
                        }
                      >
                        {!s
                          ? historyUnavailable
                            ? "Retry the Ethereum connection."
                            : "Reading the vault’s events."
                          : "The first spin will appear here when a funded round spins."}
                      </Empty>
                    )}
                  </section>
                  <div className="pool-note">
                    <Icon name="info" size={20} />
                    <p>
                      Kept NFTs go to the team for sale. Your return depends on
                      the sale proceeds.{" "}
                      <button
                        className="text-button inline"
                        onClick={() => nav("info")}
                      >
                        how it works
                      </button>
                    </p>
                  </div>
                </div>
              </div>
              <section className="recent-section">
                <div className="section-head">
                  <h2>recent spins</h2>
                  <button
                    className="text-button"
                    onClick={() => nav("history")}
                  >
                    view history
                    <Icon name="arrow" size={15} />
                  </button>
                </div>
                {s?.rounds.some((r) => r.requestId > 0n) ? (
                  <div className="feed">
                    {spins.slice(0, 3).map((r) => (
                      <HistoryRow
                        key={r.spinKey}
                        round={r}
                        now={now}
                        onOpen={() => setDetail(r.id)}
                      />
                    ))}
                  </div>
                ) : (
                  <div className="quiet-row">
                    <span className="muted">
                      {!s
                        ? historyUnavailable
                          ? "Spin history unavailable."
                          : "Reading spin events…"
                        : "No spins recorded yet."}
                    </span>
                    <span className="muted">
                      {historyUnavailable
                        ? "Retry the Ethereum connection."
                        : "all rounds live here"}
                    </span>
                  </div>
                )}
              </section>
            </>
          )}
          {tab === "history" && (
            <section>
              <div className="filter-bar" aria-label="filter history">
                {["all", "kept", "eth", "awaiting sale", "mine"].map((f) => (
                  <button
                    key={f}
                    aria-pressed={filter === f}
                    onClick={() => {
                      setFilter(f);
                      setPage(1);
                    }}
                  >
                    {f}
                  </button>
                ))}
              </div>
              <div className="feed-header">
                <span>
                  {s ? history.length : "—"}{" "}
                  {s && history.length === 1 ? "spin" : "spins"}
                </span>
                <span>newest first</span>
              </div>
              {!s ? (
                <Empty
                  title={
                    historyUnavailable
                      ? "spin history unavailable"
                      : "reading the full history"
                  }
                >
                  {historyUnavailable
                    ? "Retry the Ethereum connection."
                    : (live.progress ??
                      "Reading vault events from the deployment block.")}
                </Empty>
              ) : filter === "mine" && !address && !isDemo ? (
                <Empty title="your spins live here">
                  Connect a wallet to filter the feed to your rounds.{" "}
                  <button
                    className="text-button"
                    onClick={() => setWalletOpen(true)}
                  >
                    connect wallet
                  </button>
                </Empty>
              ) : history.length ? (
                <>
                  <div className="feed">
                    {history.slice((page - 1) * 25, page * 25).map((r) => (
                      <HistoryRow
                        key={r.spinKey}
                        round={r}
                        now={now}
                        onOpen={() => setDetail(r.id)}
                      />
                    ))}
                  </div>
                  <div className="pagination">
                    <button
                      className="button"
                      disabled={page <= 1}
                      onClick={() => {
                        setPage((p) => p - 1);
                        document
                          .querySelector(".app-shell")
                          ?.scrollTo({ top: 0 });
                        window.scrollTo({ top: 0 });
                      }}
                    >
                      previous
                    </button>
                    <span>
                      page {page} of {Math.ceil(history.length / 25)}
                    </span>
                    <button
                      className="button"
                      disabled={page * 25 >= history.length}
                      onClick={() => {
                        setPage((p) => p + 1);
                        document
                          .querySelector(".app-shell")
                          ?.scrollTo({ top: 0 });
                        window.scrollTo({ top: 0 });
                      }}
                    >
                      next
                    </button>
                  </div>
                </>
              ) : (
                <Empty title="no spins here yet">
                  Try another filter or come back after the next spin.
                </Empty>
              )}
            </section>
          )}
          {tab === "mine" && (
            <section>
              {!address && !isDemo ? (
                <Empty title="a place for your share">
                  Connect a wallet to see your rounds and exact claimable ETH.
                  <button
                    className="button"
                    onClick={() => setWalletOpen(true)}
                  >
                    connect wallet
                  </button>
                </Empty>
              ) : joined.length ? (
                <>
                  <div className="mine-summary">
                    <div>
                      <span className="muted">claimable</span>
                      <div className="summary-number">
                        <Amount
                          value={joined.reduce((v, r) => v + r.claimable, 0n)}
                          exact
                        />
                      </div>
                    </div>
                    <div>
                      <span className="muted">open carry-over</span>
                      <div className="summary-number">
                        <Amount
                          value={joined
                            .filter((r) => r.state === State.Open)
                            .reduce((v, r) => v + r.withdrawable, 0n)}
                        />
                      </div>
                    </div>
                  </div>
                  <p className="fine">
                    Amounts come directly from the vault. Open balances remain
                    withdrawable until spun.
                  </p>
                  <div className="mine-rounds">
                    {joined.map((r) => (
                      <article className="mine-row" key={String(r.id)}>
                        <div className="section-head">
                          <button
                            className="text-button"
                            onClick={() => setDetail(r.id)}
                          >
                            round #{r.id}
                            <Icon name="arrow" size={15} />
                          </button>
                          <span className="badge">{status(r)}</span>
                        </div>
                        <div className="round-metrics">
                          <div>
                            <span className="muted">stake (shares)</span>
                            <strong>
                              <Amount value={r.walletStake} unit="shares" />
                            </strong>
                          </div>
                          <div>
                            <span className="muted">pool share</span>
                            <strong>
                              {r.totalShares > 0n
                                ? `${Number((r.walletStake * 10000n) / r.totalShares) / 100}%`
                                : "0%"}
                            </strong>
                          </div>
                          <div>
                            <span className="muted">deposited</span>
                            <strong>
                              <Amount
                                value={r.events
                                  .filter(
                                    (e) =>
                                      e.eventName === "BetPlaced" &&
                                      String(e.args.bettor).toLowerCase() ===
                                        (isDemo
                                          ? vault
                                          : (address ?? "")
                                        ).toLowerCase(),
                                  )
                                  .reduce(
                                    (v, e) => v + BigInt(e.args.amount),
                                    0n,
                                  )}
                              />
                            </strong>
                          </div>
                        </div>
                        <div className="claim-row">
                          <div>
                            <span className="muted">claimable ETH</span>
                            <p className="exact-amount">
                              <Amount value={r.claimable} exact />
                            </p>
                          </div>
                          {r.state === State.Settled && r.walletStake > 0n ? (
                            actionButton(
                              "claim",
                              r.id,
                              r.claimable === 0n ? "close stake" : "claim ETH",
                            )
                          ) : r.state === State.Open && r.walletStake > 0n ? (
                            actionButton("withdraw", r.id, "withdraw")
                          ) : (
                            <span className="muted">
                              {r.walletStake === 0n
                                ? "claimed / withdrawn"
                                : "waiting for settlement"}
                            </span>
                          )}
                        </div>
                      </article>
                    ))}
                  </div>
                </>
              ) : (
                <Empty title="your first round is waiting">
                  You haven’t joined a round with this wallet.
                  <button className="button" onClick={() => nav("spin")}>
                    go to the pool
                  </button>
                </Empty>
              )}
            </section>
          )}
          {tab === "info" && (
            <Info snapshot={s} now={now} onRound={setDetail} />
          )}
        </main>
        <footer className="footer">
          <span>small stakes. shared possibilities.</span>
          <span>
            {isDemo ? (
              "sample event preview"
            ) : s ? (
              <>
                block{" "}
                <a
                  href={`https://etherscan.io/block/${s.block}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  {s.block.toLocaleString()}
                </a>{" "}
                · <Time timestamp={Math.floor(s.receivedAt / 1000)} now={now} />
              </>
            ) : live.loading ? (
              "connecting to Ethereum…"
            ) : (
              "chain read unavailable"
            )}
          </span>
        </footer>
      </div>
      <nav className="bottom-nav" aria-label="mobile main">
        {tabs.map((t) => (
          <a
            key={t}
            href={`#${t}`}
            aria-current={tab === t ? "page" : undefined}
          >
            <Icon name={t} size={21} />
            <span>{t}</span>
          </a>
        ))}
      </nav>
      {tx && (
        <div className={`tx-status ${tx.phase}`} role="status">
          <div>
            <strong>
              {tx.phase === "simulating"
                ? "checking transaction…"
                : tx.phase === "pending"
                  ? "transaction pending"
                  : tx.phase === "confirmed"
                    ? "transaction confirmed"
                    : "transaction failed"}
            </strong>
            <p>
              {tx.phase === "simulating"
                ? "Review the request in your wallet."
                : (tx.error ??
                  (tx.phase === "pending"
                    ? "Waiting for Ethereum confirmation."
                    : "Your transaction is onchain. Round data is refreshing."))}
            </p>
            {tx.hash && <ELink hash={tx.hash}>view transaction</ELink>}
          </div>
          <button
            className="icon-button"
            aria-label="dismiss transaction status"
            disabled={pending}
            onClick={() => setTx(undefined)}
          >
            <Icon name="close" size={18} />
          </button>
        </div>
      )}
      {walletOpen && <WalletSheet onClose={() => setWalletOpen(false)} />}
      {selected && (
        <RoundDetail
          round={selected}
          now={now}
          onClose={() => setDetail(undefined)}
        />
      )}
    </>
  );
}
function HistoryRow({
  round: r,
  now,
  onOpen,
}: {
  round: SpinEntry;
  now: number;
  onOpen: () => void;
}) {
  return (
    <article className="history-row">
      <button className="history-main" onClick={onOpen}>
        <NFTArt image={r.nft?.image} name={r.nft?.name} small />
        <span className="history-name">
          <span className="row-title">
            {r.nft?.collectionName ??
              (r.listingId > 0n
                ? short(r.collection)
                : r.refunded
                  ? "spin refunded"
                  : "spin pending")}
            {r.listingId > 0n && <span className="muted"> #{r.tokenId}</span>}
          </span>
          <span className="row-meta">
            round #{r.id}
            {r.attempt > 1 ? ` · attempt ${r.attempt}` : ""} ·{" "}
            {r.originalBettors || r.bettors} bettors ·{" "}
            <Time timestamp={r.spinTime} now={now} />
          </span>
        </span>
        <span className="history-result">
          <span>
            {r.sale ? (
              <>
                sold <Amount value={r.sale.amount} />
              </>
            ) : r.state === State.Settled && !r.kept ? (
              <>
                ETH bid <Amount value={r.ethBid} />
              </>
            ) : (
              status(r)
            )}
          </span>
          <span className="row-meta">
            {returnRate(r) !== undefined ? (
              <>
                <Amount value={returnRate(r)} /> / 1 ETH
              </>
            ) : (
              "return pending"
            )}
          </span>
        </span>
        <Icon name="chevron" size={16} />
      </button>
      <div className="history-sub">
        <span className="badge subtle">
          {r.refunded ? "no decision" : pathLabel(r.path)}
        </span>
        <span>
          spin <Amount value={r.price} />
        </span>
        {r.sale && <ELink hash={r.sale.hash}>sale tx</ELink>}
        <ELink hash={r.spinHash}>Etherscan</ELink>
      </div>
    </article>
  );
}
const eventAmounts: Record<string, readonly string[]> = {
  BetPlaced: ["amount", "shares"],
  Withdrawn: ["amount", "shares"],
  SpinRequested: ["quote", "reward", "refund"],
  AcquisitionRefunded: ["refund", "remainingCash"],
  OracleValueStored: ["netOffer"],
  Decision: ["ethBid", "netOffer"],
  SaleProceeds: ["amount"],
  RoundSettled: ["distributable", "fee"],
  Claimed: ["amount"],
};
function EventValue({
  eventName,
  field,
  value,
  now,
}: {
  eventName: string;
  field: string;
  value: ChainEvent["args"][string];
  now: number;
}) {
  if (eventAmounts[eventName]?.includes(field))
    return <Amount value={BigInt(value)} />;
  if (
    (eventName === "AllocationRecorded" && field === "deadline") ||
    (eventName === "OracleValueStored" && field === "expiresAt")
  )
    return <Time timestamp={Number(value)} now={now} />;
  if (eventName === "RoundStateChanged" && field === "state")
    return stateLabel(Number(value)) || "not started";
  if (eventName === "Decision" && field === "path")
    return pathLabel(Number(value)) ?? "unknown";
  return typeof value === "boolean" ? (value ? "yes" : "no") : String(value);
}
function RoundDetail({
  round: r,
  now,
  onClose,
}: {
  round: Round;
  now: number;
  onClose: () => void;
}) {
  return (
    <Dialog title={`round #${r.id}`} onClose={onClose}>
      <div className="detail-nft">
        <NFTArt image={r.nft?.image} name={r.nft?.name} small />
        <div>
          <h3>{r.nft?.collectionName ?? "NFT allocation"}</h3>
          <p className="muted">
            {r.listingId > 0n ? `token #${r.tokenId}` : "no allocation yet"}
          </p>
        </div>
        <span className="badge">{status(r)}</span>
      </div>
      {r.listingId > 0n && (
        <a
          className="full-address"
          href={addressLink(r.collection)}
          target="_blank"
          rel="noreferrer"
        >
          {r.collection}
          <Icon name="arrow" size={16} />
        </a>
      )}
      <dl className="detail-values">
        <div>
          <dt>
            {r.events.filter((e) => e.eventName === "SpinRequested").length > 1
              ? "total spin cost"
              : "spin price"}
          </dt>
          <dd>
            <Amount value={r.price} />
          </dd>
        </div>
        <div>
          <dt>decision path</dt>
          <dd>{pathLabel(r.path)}</dd>
        </div>
        <div>
          <dt>backing</dt>
          <dd>
            <Amount value={r.backing} />
          </dd>
        </div>
        <div>
          <dt>ETH bid</dt>
          <dd>
            <Amount value={r.bid} />
          </dd>
        </div>
        <div>
          <dt>return per 1 ETH staked</dt>
          <dd>
            <Amount value={returnRate(r)} />
          </dd>
        </div>
        {r.sale && (
          <div>
            <dt>sale proceeds</dt>
            <dd>
              <ELink hash={r.sale.hash}>
                <Amount value={r.sale.amount} />
              </ELink>
            </dd>
          </div>
        )}
      </dl>
      <h3 className="timeline-title">round events · {r.events.length}</h3>
      <ol className="timeline">
        {r.events.map((e) => (
          <li key={`${e.transactionHash}:${e.logIndex}`}>
            <div className="section-head">
              <strong>
                {e.eventName
                  .replace(/([A-Z])/g, " $1")
                  .trim()
                  .toLowerCase()}
              </strong>
              <Time timestamp={e.timestamp} now={now} />
            </div>
            <dl className="event-args">
              {Object.entries(e.args)
                .filter(([k]) => k !== "roundId")
                .map(([k, v]) => (
                  <div key={k}>
                    <dt>{k.replace(/([A-Z])/g, " $1").toLowerCase()}</dt>
                    <dd>
                      <EventValue
                        eventName={e.eventName}
                        field={k}
                        value={v}
                        now={now}
                      />
                    </dd>
                  </div>
                ))}
            </dl>
            <ELink hash={e.transactionHash}>
              transaction · block {e.blockNumber.toLocaleString()}
            </ELink>
          </li>
        ))}
      </ol>
    </Dialog>
  );
}
function Info({
  snapshot: s,
  now,
  onRound,
}: {
  snapshot?: Snapshot;
  now: number;
  onRound: (id: bigint) => void;
}) {
  const spins = s?.rounds.filter((r) => r.requestId > 0n) ?? [],
    settled = spins.filter((r) => r.distributable !== undefined),
    awaiting = spins.filter((r) => r.state === State.AwaitingSale);
  const volume = spins.reduce((v, r) => v + r.price, 0n),
    returned = settled.reduce((v, r) => v + (r.distributable ?? 0n), 0n),
    denom = settled.reduce((v, r) => v + r.deposited - r.withdrawn, 0n);
  const stats: [string, ReactNode][] = [
    [
      "spins",
      s
        ? spins.reduce(
            (v, r) =>
              v +
              r.events.filter((e) => e.eventName === "SpinRequested").length,
            0,
          )
        : "—",
    ],
    ["ETH spin volume", <Amount value={s ? volume : undefined} />],
    ["ETH returned", <Amount value={s ? returned : undefined} />],
    ["NFTs kept", s ? spins.filter((r) => r.kept).length : "—"],
    ["NFTs sold", s ? spins.filter((r) => r.sale).length : "—"],
    [
      "avg return / 1 ETH",
      <Amount
        value={s && denom > 0n ? (returned * 10n ** 18n) / denom : undefined}
      />,
    ],
  ];
  return (
    <>
      <section className="stats-grid">
        {stats.map(([k, v]) => (
          <div key={k}>
            <p className="muted">{k}</p>
            <strong>{v}</strong>
          </div>
        ))}
      </section>
      <p className="fine">
        Returned ETH is the distributable amount at settlement, before claims.
        Average return weights settled stakes by ETH deposited, less
        withdrawals. Unsettled rounds are excluded.
      </p>
      <div className="info-layout">
        <section>
          <h2>from a bet to a return</h2>
          <ol className="steps">
            {[
              [
                "bet",
                "Add ETH to an open round. Excess carries into the next round.",
              ],
              [
                "spin",
                "Anyone can spin when funded, within the gas limit and outside FWA blackouts. The caller earns a reward.",
              ],
              [
                "keep or take ETH",
                "A clear floor, an oracle answer or a fallback decides between the NFT and the ETH bid.",
              ],
              [
                "sale",
                "Kept NFTs go to the team wallet. The team sells them and records proceeds and the sale transaction onchain.",
              ],
              [
                "claim",
                "Once settled, claim your share of the round’s ETH. Network gas is paid by your wallet.",
              ],
            ].map(([title, body], i) => (
              <li key={title}>
                <span className="step-number">{i + 1}</span>
                <div>
                  <h3>{title}</h3>
                  <p className="muted">{body}</p>
                </div>
              </li>
            ))}
          </ol>
        </section>
        <section className="trust-section">
          <h2>the team sale step</h2>
          <p className="muted">
            Kept NFTs go to the Keel team wallet and are sold by the team. You
            rely on the team to sell and return the proceeds; there is no
            guaranteed sale time or return.
          </p>
          <p className="fine">team wallet</p>
          {s ? (
            <a
              className="full-address"
              href={addressLink(s.params.teamWallet)}
              target="_blank"
              rel="noreferrer"
            >
              {s.params.teamWallet}
              <Icon name="arrow" size={16} />
            </a>
          ) : (
            <p className="muted">waiting for live address</p>
          )}
          <div className="section-head waiting-head">
            <h3>awaiting sale</h3>
            <span className="muted">{awaiting.length} rounds</span>
          </div>
          {awaiting.length ? (
            awaiting.map((r) => (
              <button
                className="awaiting-row"
                key={String(r.id)}
                onClick={() => onRound(r.id)}
              >
                <span>round #{r.id}</span>
                <span>
                  {r.keptSince
                    ? `waiting ${countdown(now - r.keptSince)}`
                    : "waiting for sale"}
                </span>
                <Icon name="chevron" size={16} />
              </button>
            ))
          ) : (
            <p className="fine">
              {s
                ? "No rounds are waiting for a team sale."
                : "Waiting for chain data."}
            </p>
          )}
        </section>
      </div>
      <section className="parameters-section">
        <h2>live vault settings</h2>
        <div className="settings-grid">
          {(["bufferBps", "marginBps", "haircutBps", "feeBps"] as const).map(
            (key, i) => (
              <div key={key}>
                <span className="muted">
                  {["buffer", "margin", "haircut", "fee"][i]}
                </span>
                <strong>{s ? `${Number(s.params[key]) / 100}%` : "—"}</strong>
              </div>
            ),
          )}
          <div>
            <span className="muted">spin reward cap</span>
            <strong>
              <Amount value={s?.params.spinReward} />
            </strong>
          </div>
          <div>
            <span className="muted">gas limit</span>
            <strong>
              {s ? formatGwei(s.params.maxSpinGasPrice) : "—"} gwei
            </strong>
          </div>
          <div>
            <span className="muted">vault IMD</span>
            <strong>
              <Amount value={s?.params.imdBalance} unit="IMD" />
            </strong>
          </div>
          <div>
            <span className="muted">oracle cost</span>
            <strong>
              <Amount value={s?.params.oraclePrice} unit="IMD" />
            </strong>
          </div>
        </div>
        {s && s.params.imdBalance < s.params.lowImdThreshold && (
          <p className="notice warning">
            low IMD balance · the vault needs an IMD top-up for oracle requests.
            The fallback remains available.
          </p>
        )}
        <p className="fine">
          Caller reward is capped at 2% of the live quote. Blackouts:
          11:45–12:00 and 23:45–00:00 UTC. Bets stay open during blackouts.
        </p>
      </section>
      <section className="contracts-section">
        <h2>follow the contracts</h2>
        <a
          className="contract-row"
          href={addressLink(vault)}
          target="_blank"
          rel="noreferrer"
        >
          <span>KeelSpinVault</span>
          <span>{vault}</span>
          <Icon name="arrow" size={18} />
        </a>
        <a
          className="contract-row"
          href={addressLink(router)}
          target="_blank"
          rel="noreferrer"
        >
          <span>KeelFwaRouter</span>
          <span>{router}</span>
          <Icon name="arrow" size={18} />
        </a>
        <p className="fine">
          All balances and history come from Ethereum. This app has no backend.
          A bet can lose value; claims depend on the round’s actual proceeds.
        </p>
      </section>
    </>
  );
}
