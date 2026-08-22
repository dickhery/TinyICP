import { safeGetCanisterEnv } from "@icp-sdk/core/agent/canister-env";
import { createActor } from "../bindings/backend";
import { getBackendCanisterId } from "./canisters.js";
import { getIdentity } from "./auth.js";

let actorPromise;

const getAgentOptions = async () => {
  const identity = await getIdentity();
  const canisterEnv = safeGetCanisterEnv();

  return {
    identity,
    rootKey: canisterEnv?.IC_ROOT_KEY,
  };
};

export const getBackendActor = async () => {
  if (!actorPromise) {
    actorPromise = (async () => {
      return createActor(getBackendCanisterId(), {
        agentOptions: await getAgentOptions(),
      });
    })();
  }

  return actorPromise;
};

export const resetBackendActor = () => {
  actorPromise = undefined;
};
