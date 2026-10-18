import { useState } from "react";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useSwitchChain,
  type Connector,
} from "wagmi";
import { chain, addressLink } from "../config";
import { plainError } from "../chain";
import { short } from "../model";
import { Dialog } from "./Dialog";
import { Icon } from "./Icons";
export function WalletControl({ onOpen }: { onOpen: () => void }) {
  const { address, isConnected, chainId } = useAccount(),
    { switchChain, isPending } = useSwitchChain();
  if (isConnected && chainId !== chain.id)
    return (
      <button
        className="wallet-control"
        onClick={() => switchChain({ chainId: chain.id })}
        disabled={isPending}
      >
        {isPending ? "switching…" : "switch to Ethereum"}
      </button>
    );
  return (
    <button className="wallet-control" onClick={onOpen}>
      <Icon name="wallet" size={18} />
      {address ? short(address) : "connect"}
    </button>
  );
}
function WalletMark({ connector }: { connector: Connector }) {
  if (connector.icon)
    return <img width="28" height="28" src={connector.icon} alt="" />;
  if (connector.id === "coinbaseWalletSDK")
    return (
      <svg aria-hidden="true" width="28" height="28" viewBox="0 0 28 28">
        <rect width="28" height="28" rx="7" fill="#2c5ff6" />
        <circle cx="14" cy="14" r="9" fill="white" />
        <rect x="10" y="10" width="8" height="8" rx="1" fill="#2c5ff6" />
      </svg>
    );
  if (connector.id === "walletConnect")
    return (
      <svg aria-hidden="true" width="28" height="28" viewBox="0 0 28 28">
        <rect width="28" height="28" rx="7" fill="#3b99fc" />
        <path
          d="M7 11q7-7 14 0M5 14l5 5 4-4 4 4 5-5"
          fill="none"
          stroke="white"
          strokeWidth="2.5"
        />
      </svg>
    );
  return <Icon name="wallet" size={28} />;
}
export function WalletSheet({ onClose }: { onClose: () => void }) {
  const { address, isConnected } = useAccount(),
    { connectAsync, connectors, isPending, variables } = useConnect(),
    { disconnect } = useDisconnect();
  const [error, setError] = useState(""),
    [copied, setCopied] = useState(false);
  const named = connectors.some(
    (c) => c.type === "injected" && c.id !== "injected",
  );
  const mobile =
    matchMedia("(pointer: coarse)").matches &&
    !("ethereum" in window && window.ethereum) &&
    !named;
  const listed = connectors
    .filter((c) => !(c.id === "injected" && named))
    .filter((c) => !mobile || c.type !== "injected")
    .sort(
      (a, b) => Number(b.type === "injected") - Number(a.type === "injected"),
    );
  const label = (c: Connector) =>
    c.id === "injected"
      ? "browser wallet"
      : c.id === "coinbaseWalletSDK" && mobile
        ? "Coinbase Smart Wallet"
        : c.name;
  const openIn = [
    {
      name: "MetaMask",
      href: `https://link.metamask.io/dapp/${location.href.replace(/^https?:\/\//, "")}`,
    },
    {
      name: "Coinbase Wallet",
      href: `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(location.href)}`,
    },
    {
      name: "Phantom",
      href: `https://phantom.app/ul/browse/${encodeURIComponent(location.href)}?ref=${encodeURIComponent(location.origin)}`,
    },
  ];
  return (
    <Dialog
      title={isConnected ? "your wallet" : "connect a wallet"}
      onClose={onClose}
    >
      {isConnected && address ? (
        <>
          <p className="muted">Ethereum mainnet</p>
          <a
            className="full-address"
            href={addressLink(address)}
            target="_blank"
            rel="noreferrer"
          >
            {address}
            <Icon name="arrow" size={16} />
          </a>
          <button
            className="button full"
            onClick={() => {
              disconnect();
              onClose();
            }}
          >
            disconnect
          </button>
        </>
      ) : (
        <>
          <p className="muted wallet-note">
            Connect to bet or claim. You can browse without a wallet.
          </p>
          {mobile && (
            <div className="wallet-options">
              {openIn.map((w) => (
                <a className="wallet-row" key={w.name} href={w.href}>
                  <Icon name="wallet" size={28} />
                  <span>open in {w.name}</span>
                  <Icon name="arrow" size={18} />
                </a>
              ))}
            </div>
          )}
          <div className="wallet-options">
            {listed.map((c) => (
              <button
                className="wallet-row"
                key={c.uid}
                disabled={isPending}
                onClick={async () => {
                  setError("");
                  try {
                    await connectAsync({ connector: c });
                    onClose();
                  } catch (e) {
                    setError(plainError(e));
                  }
                }}
              >
                <WalletMark connector={c} />
                <span>
                  {label(c)}
                  {isPending && variables?.connector === c ? " · opening…" : ""}
                </span>
                <Icon name="chevron" size={16} />
              </button>
            ))}
          </div>
          {mobile && (
            <>
              <p className="muted">
                Using Rabby? Open this page in its app browser.
              </p>
              <button
                className="button full"
                onClick={async () => {
                  try {
                    await navigator.clipboard.writeText(location.href);
                    setCopied(true);
                  } catch {
                    setError("Copy the page URL from your address bar.");
                  }
                }}
              >
                {copied ? "URL copied" : "copy page URL"}
              </button>
            </>
          )}
          <p role="status" className="error">
            {error}
          </p>
          <p className="fine">
            No token approval is needed. Each transaction is yours to review in
            your wallet.
          </p>
        </>
      )}
    </Dialog>
  );
}
