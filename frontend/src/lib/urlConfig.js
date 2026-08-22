import { building } from "$app/environment";
import { getBackendCanisterId } from "./canisters.js";

const DEFAULT_PUBLIC_SHORTLINK_ORIGIN = "https://tinyicp.com";

export const isLocalHost = (hostname) =>
  hostname === "localhost" ||
  hostname === "127.0.0.1" ||
  hostname.endsWith(".localhost");

const normalizeOrigin = (value) => {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }

  try {
    return new URL(trimmed).origin;
  } catch {
    return null;
  }
};

export const getHostEnvironment = () => {
  if (typeof window === "undefined") {
    return { kind: "local", port: "" };
  }

  const { hostname, port } = window.location;

  return {
    kind: isLocalHost(hostname) ? "local" : "ic",
    port,
  };
};

export const getBackendOrigin = (raw = true) => {
  if (building || process.env.NODE_ENV === "test") {
    return "/";
  }

  const { kind, port } = getHostEnvironment();
  const canisterId = getBackendCanisterId();
  const canisterIdAndRaw = raw ? `${canisterId}.raw` : canisterId;

  if (kind === "local") {
    const localPort = port || "8000";
    return `http://${canisterIdAndRaw}.localhost:${localPort}`;
  }

  return `https://${canisterIdAndRaw}.icp0.io`;
};

export const getPublicShortLinkOrigin = () => {
  if (building || process.env.NODE_ENV === "test") {
    return "/";
  }

  const { kind } = getHostEnvironment();
  if (kind === "local") {
    return getBackendOrigin(false);
  }

  return (
    normalizeOrigin(import.meta.env.VITE_PUBLIC_SHORTLINK_ORIGIN) ??
    DEFAULT_PUBLIC_SHORTLINK_ORIGIN
  );
};

export const getShareShortLinkOrigin = () => {
  if (building || process.env.NODE_ENV === "test") {
    return "/";
  }

  return (
    normalizeOrigin(import.meta.env.VITE_SHARE_SHORTLINK_ORIGIN) ??
    getPublicShortLinkOrigin()
  );
};

export const buildShortLink = (origin, shortCode) => {
  const path = `/s/${encodeURIComponent(shortCode)}`;

  if (origin === "/") {
    return path;
  }

  return `${origin.replace(/\/+$/, "")}${path}`;
};

export const buildShortLinkPrefix = (origin) => {
  if (origin === "/") {
    return "/s/";
  }

  return `${origin.replace(/\/+$/, "")}/s/`;
};
