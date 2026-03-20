// URL Shortener API service for interacting with the Motoko backend

import { canisterId } from './canisters.js';
import { building } from '$app/environment';

const getHostEnvironment = () => {
  if (typeof window === 'undefined') {
    return { kind: 'local', port: '4943', protocol: 'http:' };
  }

  const { hostname, port } = window.location;
  const isLocalHost =
    hostname === 'localhost' ||
    hostname === '127.0.0.1' ||
    hostname.endsWith('.localhost');

  return {
    kind: isLocalHost ? 'local' : 'ic',
    port: port || '4943',
  };
};

// Build the base URL based on environment
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


export class UrlApi {
  /**
   * Get all shortened URLs
   * @returns {Promise<Array>} Array of URL objects
   */
  static async getAllUrls() {
    const response = await fetch(`${getBaseUrl()}/urls`, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
      },
    });
    
    if (!response.ok) {
      throw new Error(`Failed to fetch URLs: ${response.status} ${response.statusText}`);
    }
    
    return await response.json();
  }

  /**
   * Create a shortened URL
   * @param {string} originalUrl - The original long URL
   * @param {string|null} customSlug - Optional custom short code
   * @returns {Promise<Object>} Created URL object
   */
  static async createShortUrl(originalUrl, customSlug = null) {
    if (!originalUrl || !originalUrl.trim()) {
      throw new Error('Original URL is required');
    }

    // Validate URL format
    try {
      new URL(originalUrl);
    } catch {
      throw new Error('Invalid URL format');
    }

    const body = customSlug 
      ? `url=${encodeURIComponent(originalUrl)}&slug=${encodeURIComponent(customSlug)}`
      : originalUrl;

    const response = await fetch(`${getBaseUrl()}/shorten`, {
      method: 'POST',
      headers: {
        'Content-Type': customSlug ? 'application/x-www-form-urlencoded' : 'text/plain',
      },
      body: body,
    });
    
    if (!response.ok) {
      const errorText = await response.text().catch(() => 'Unknown error');
      throw new Error(`Failed to create short URL: ${errorText}`);
    }
    
    return await response.json();
  }

  /**
   * Delete a shortened URL
   * @param {number} id - URL ID
   * @returns {Promise<void>}
   */
  static async deleteUrl(id) {
    const response = await fetch(`${getBaseUrl()}/urls/${id}`, {
      method: 'DELETE',
    });
    
    if (!response.ok) {
      if (response.status === 404) {
        throw new Error(`URL with ID ${id} not found`);
      }
      throw new Error(`Failed to delete URL: ${response.status} ${response.statusText}`);
    }
  }

  /**
   * Get the full short URL for a given short code
   * @param {string} shortCode - The short code
   * @returns {string} Full short URL
   */
  static getShortUrl(shortCode) {
    return `${getBaseUrl(false)}/s/${shortCode}`;
  }

  /**
   * Get URL statistics
   * @param {string} shortCode - The short code
   * @returns {Promise<Object>} URL statistics
   */
  static async getUrlStats(shortCode) {
    const response = await fetch(`${getBaseUrl()}/s/${shortCode}/stats`, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
      },
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
