/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_HAWK_NETWORK?: string;
  readonly VITE_INDEXER_URL?: string;
  readonly VITE_WC_PROJECT_ID?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
