import { building } from "$app/environment";
import { safeGetCanisterEnv } from "@icp-sdk/core/agent/canister-env";

export const getBackendCanisterId = () => {
  const canisterEnv = safeGetCanisterEnv();
  const canisterId = canisterEnv?.["PUBLIC_CANISTER_ID:backend"];

  if (canisterId) {
    return canisterId;
  }

  if (building || process.env.NODE_ENV === "test") {
    return "backend";
  }

  throw new Error(
    "Missing backend canister id. Deploy with `icp deploy` so the frontend can read PUBLIC_CANISTER_ID:backend from the ic_env cookie.",
  );
};
