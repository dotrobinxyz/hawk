import { useState } from "react";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useEnsName,
  useSwitchChain,
} from "wagmi";
import { CHAIN } from "../config";
import { shortAddress } from "../lib/format";

export function ConnectButton() {
  const { address, isConnected, chainId } = useAccount();
  const { connectors, connect, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const { data: primaryName } = useEnsName({
    address,
    chainId: CHAIN.id,
    query: { enabled: Boolean(address) },
  });
  const [open, setOpen] = useState(false);

  if (isConnected && address) {
    if (chainId !== CHAIN.id) {
      return (
        <button
          className="btn small danger"
          onClick={() => switchChain({ chainId: CHAIN.id })}
        >
          switch network
        </button>
      );
    }
    return (
      <button className="btn small secondary" onClick={() => disconnect()}>
        {primaryName ?? shortAddress(address)}
      </button>
    );
  }

  if (open) {
    return (
      <div className="row">
        {connectors.map((connector) => (
          <button
            key={connector.uid}
            className="btn small"
            disabled={isPending}
            onClick={() => {
              connect({ connector });
              setOpen(false);
            }}
          >
            {connector.name}
          </button>
        ))}
        <button className="btn small secondary" onClick={() => setOpen(false)}>
          ×
        </button>
      </div>
    );
  }

  return (
    <button
      className="btn small"
      onClick={() =>
        connectors.length === 1
          ? connect({ connector: connectors[0]! })
          : setOpen(true)
      }
    >
      connect
    </button>
  );
}
