import { AuthClient } from "@icp-sdk/auth/client";
import { building } from "$app/environment";

const MAINNET_II_URL = "https://id.ai/authorize";
const FRONTEND_CANISTER_ORIGIN = "https://srbli-5iaaa-aaaab-aga5q-cai.icp0.io";

let authClient;

const getIdentityProvider = () => {
  if (building || typeof window === "undefined") {
    return MAINNET_II_URL;
  }

  const configured = import.meta.env.VITE_INTERNET_IDENTITY_URL;
  if (configured) {
    return configured;
  }

  return MAINNET_II_URL;
};

export const getAuthClient = () => {
  if (!authClient) {
    authClient = new AuthClient({
      identityProvider: getIdentityProvider(),
      derivationOrigin: FRONTEND_CANISTER_ORIGIN,
    });
  }

  return authClient;
};

export const isAuthenticated = async () => getAuthClient().isAuthenticated();

export const getIdentity = async () => getAuthClient().getIdentity();

export const login = async () => {
  return getAuthClient().signIn({
    maxTimeToLive: BigInt(8) * BigInt(3_600_000_000_000),
    windowOpenerFeatures:
      "toolbar=0,location=0,menubar=0,width=520,height=705,left=100,top=100",
  });
};

export const logout = async () => {
  await getAuthClient().signOut();
};

export const getPrincipalText = async () => {
  const identity = await getIdentity();
  return identity.getPrincipal().toText();
};
