import React from "react";
import ReactDOM from "react-dom/client";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Route, Switch } from "wouter";
import { wagmiConfig } from "./config";
import { Layout } from "./components/Layout";
import { Home } from "./pages/Home";
import { NamePage } from "./pages/NamePage";
import { MyNames } from "./pages/MyNames";
import { Auctions } from "./pages/Auctions";
import "./styles.css";

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 15_000, retry: 1 } },
});

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <Layout>
          <Switch>
            <Route path="/" component={Home} />
            <Route path="/name/:label">
              {(params) => <NamePage label={decodeURIComponent(params.label)} />}
            </Route>
            <Route path="/my" component={MyNames} />
            <Route path="/mine" component={MyNames} />
            <Route path="/auctions" component={Auctions} />
            <Route>
              <div className="empty">Nothing here.</div>
            </Route>
          </Switch>
        </Layout>
      </QueryClientProvider>
    </WagmiProvider>
  </React.StrictMode>,
);
