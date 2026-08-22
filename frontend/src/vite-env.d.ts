/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_PUBLIC_SHORTLINK_ORIGIN?: string;
  readonly VITE_SHARE_SHORTLINK_ORIGIN?: string;
  readonly VITE_INTERNET_IDENTITY_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
