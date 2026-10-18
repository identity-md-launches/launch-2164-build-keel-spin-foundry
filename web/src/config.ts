import { createConfig, fallback, http } from "wagmi";
import { injected, coinbaseWallet, walletConnect } from "wagmi/connectors";
import { mainnet } from "wagmi/chains";
import type { Abi, Address } from "viem";
import handoff from "./contracts/deployment.json";
import network from "./contracts/network.json";
import vaultAbi from "./contracts/KeelSpinVault.abi.json";
import routerAbi from "./contracts/KeelFwaRouter.abi.json";
import fwaAbi from "./contracts/FWAV2.abi.json";
export const deployment = handoff;
export const chain = {
  ...mainnet,
  name: network.network.name,
  rpcUrls: { default: { http: network.network.rpcUrls } },
  blockExplorers: {
    default: { name: "Etherscan", url: network.network.explorer },
  },
};
export const vault = handoff.contracts.find((c) => c.name === "KeelSpinVault")!
  .address as Address;
export const router = handoff.contracts.find((c) => c.name === "KeelFwaRouter")!
  .address as Address;
export const deploymentBlock = BigInt(
  handoff.contracts.find((c) => c.name === "KeelSpinVault")!.blockNumber,
);
export const abi = vaultAbi as Abi;
export const routerABI = routerAbi as Abi;
export const fwaABI = fwaAbi as Abi;
export const explorer = network.network.explorer;
export const rpcUrls = [
  import.meta.env?.VITE_RPC_URL,
  ...network.network.rpcUrls,
].filter((s): s is string => !!s);
export const transport = () =>
  fallback(
    rpcUrls.map((url) =>
      http(url, { batch: { wait: 25 }, timeout: 15_000, retryCount: 1 }),
    ),
  );
const projectId = import.meta.env?.VITE_WALLETCONNECT_PROJECT_ID?.trim();
export const config = createConfig({
  chains: [chain],
  multiInjectedProviderDiscovery: true,
  connectors: [
    injected(),
    coinbaseWallet({ appName: "Keel Spin", preference: "all" }),
    ...(projectId ? [walletConnect({ projectId, showQrModal: true })] : []),
  ],
  transports: { [chain.id]: transport() },
});
export const txLink = (hash: string) => `${explorer}/tx/${hash}`;
export const addressLink = (address: string) =>
  `${explorer}/address/${address}`;
