import { building } from '$app/environment';
import { canisterId } from './canisters.js';
import { getBackendActor } from './backendActor.js';

const getHostEnvironment = () => {
  if (typeof window === 'undefined') {
    return { kind: 'local', port: '4943' };
  }

  const { hostname, port } = window.location;
  const isLocalHost =
    hostname === 'localhost' ||
    hostname === '127.0.0.1' ||
    hostname.endsWith('.localhost');

  return {
    kind: isLocalHost ? 'local' : 'ic',
    port: port || '4943'
  };
};

const getBaseUrl = (raw = true) => {
  if (building || process.env.NODE_ENV === 'test') {
    return '/';
  }

  const { kind, port } = getHostEnvironment();
  const canisterIdAndRaw = raw ? `${canisterId}.raw` : canisterId;

  if (kind === 'local') {
    return `http://${canisterIdAndRaw}.localhost:${port}`;
  }

  return `https://${canisterIdAndRaw}.icp0.io`;
};

const unwrapResult = (result, action) => {
  if ('ok' in result) {
    return result.ok;
  }

  throw new Error(result.err || `Failed to ${action}`);
};

const normalizeUrl = (url) => ({
  ...url,
  id: Number(url.id),
  clicks: Number(url.clicks),
  createdAt: Number(url.createdAt)
});

const normalizeWallet = (wallet) => ({
  ...wallet,
  canisterPrincipal: wallet.canisterPrincipal.toText(),
  balanceE8s: Number(wallet.balanceE8s),
  transferFeeE8s: Number(wallet.transferFeeE8s),
  tinyUrlPriceE8s: Number(wallet.tinyUrlPriceE8s)
});

export const formatIcp = (e8s) => (Number(e8s) / 100_000_000).toFixed(4);

export class UrlApi {
  static async getAllUrls() {
    const actor = await getBackendActor();
    const urls = await actor.list_my_urls();
    return urls.map(normalizeUrl);
  }

  static async getWalletInfo() {
    const actor = await getBackendActor();
    return normalizeWallet(await actor.get_wallet_info());
  }

  static async createShortUrl(originalUrl, customSlug = null) {
    if (!originalUrl || !originalUrl.trim()) {
      throw new Error('Original URL is required');
    }

    try {
      new URL(originalUrl);
    } catch {
      throw new Error('Invalid URL format');
    }

    const actor = await getBackendActor();
    const result = await actor.create_my_url({
      originalUrl,
      customSlug: customSlug ? [customSlug] : []
    });

    return normalizeUrl(unwrapResult(result, 'create short URL'));
  }

  static async transferFromWallet(destination, amountIcp) {
    const parsed = Number(amountIcp);
    if (!Number.isFinite(parsed) || parsed <= 0) {
      throw new Error('Enter a valid ICP amount greater than zero');
    }

    const actor = await getBackendActor();
    const e8s = BigInt(Math.round(parsed * 100_000_000));
    const result = await actor.transfer_from_wallet(destination, e8s);
    return unwrapResult(result, 'transfer ICP from wallet');
  }

  static async deleteUrl(id) {
    const actor = await getBackendActor();
    const result = await actor.delete_my_url(BigInt(id));
    unwrapResult(result, 'delete URL');
  }

  static getShortUrl(shortCode) {
    return `${getBaseUrl(false)}/s/${shortCode}`;
  }

  static async getUrlStats(shortCode) {
    const response = await fetch(`${getBaseUrl()}/s/${shortCode}/stats`, {
      method: 'GET',
      headers: {
        Accept: 'application/json'
      }
    });

    if (!response.ok) {
      if (response.status === 404) {
        throw new Error(`Short URL ${shortCode} not found`);
      }
      throw new Error(`Failed to fetch URL stats: ${response.status} ${response.statusText}`);
    }

    return await response.json();
  }
}

export default UrlApi;
