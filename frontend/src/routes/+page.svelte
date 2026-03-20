<script>
    import "../index.scss";
    import { onMount } from "svelte";
    import UrlApi, { formatIcp } from "$lib/urlApi.js";
    import {
        getPrincipalText,
        isAuthenticated,
        login,
        logout
    } from "$lib/auth.js";
    import { resetBackendActor } from "$lib/backendActor.js";

    let urls = [];
    let wallet = null;
    let loading = false;
    let walletLoading = false;
    let authLoading = true;
    let authenticated = false;
    let principal = "";
    let error = "";
    let successMessage = "";
    let newUrl = "";
    let customSlug = "";
    let copiedShortUrl = "";
    let copiedWalletValue = "";
    let transferDestination = "";
    let transferAmount = "";
    let showPaymentModal = false;

    async function syncAuthState() {
        authLoading = true;
        error = "";

        try {
            authenticated = await isAuthenticated();
            resetBackendActor();
            principal = authenticated ? await getPrincipalText() : "";

            if (authenticated) {
                await Promise.all([loadUrls(), loadWallet()]);
            } else {
                urls = [];
                wallet = null;
            }
        } catch (err) {
            authenticated = false;
            principal = "";
            wallet = null;
            error = "Failed to initialize authentication: " + err.message;
        } finally {
            authLoading = false;
        }
    }

    async function loadUrls() {
        if (!authenticated) {
            urls = [];
            return;
        }

        loading = true;
        error = "";
        try {
            urls = await UrlApi.getAllUrls();
        } catch (err) {
            error = "Failed to load URLs: " + err.message;
        } finally {
            loading = false;
        }
    }

    async function loadWallet() {
        if (!authenticated) {
            wallet = null;
            return;
        }

        walletLoading = true;
        error = "";
        try {
            wallet = await UrlApi.getWalletInfo();
        } catch (err) {
            error = "Failed to load wallet: " + err.message;
        } finally {
            walletLoading = false;
        }
    }

    async function handleLogin() {
        authLoading = true;
        error = "";
        try {
            await login();
            showSuccess("Authenticated successfully. Loading your Tiny ICP dashboard...");
            await syncAuthState();
        } catch (err) {
            error = "Internet Identity sign in failed: " + err.message;
            authLoading = false;
        }
    }

    async function handleLogout() {
        authLoading = true;
        try {
            await logout();
            resetBackendActor();
            authenticated = false;
            principal = "";
            urls = [];
            wallet = null;
            showSuccess("Signed out successfully");
        } catch (err) {
            error = "Failed to sign out: " + err.message;
        } finally {
            authLoading = false;
        }
    }

    function requestShortenConfirmation() {
        if (!newUrl.trim()) {
            error = "Please enter a URL to shorten";
            return;
        }

        try {
            new URL(newUrl);
        } catch {
            error = "Please enter a valid URL (including http:// or https://)";
            return;
        }

        showPaymentModal = true;
    }

    async function confirmShortenUrl() {
        showPaymentModal = false;
        loading = true;
        error = "";

        try {
            const shortenedUrl = await UrlApi.createShortUrl(newUrl, customSlug || null);
            urls = [shortenedUrl, ...urls];
            newUrl = "";
            customSlug = "";
            await loadWallet();
            showSuccess(`Paid 1.0000 ICP and created ${UrlApi.getShortUrl(shortenedUrl.shortCode)}`);
        } catch (err) {
            error = "Failed to shorten URL: " + err.message;
        } finally {
            loading = false;
        }
    }

    async function transferFromWallet() {
        if (!transferDestination.trim()) {
            error = "Enter a destination principal or account identifier";
            return;
        }

        walletLoading = true;
        error = "";
        try {
            await UrlApi.transferFromWallet(transferDestination.trim(), transferAmount);
            await loadWallet();
            transferDestination = "";
            transferAmount = "";
            showSuccess("ICP transfer submitted from your Tiny ICP wallet.");
        } catch (err) {
            error = "Failed to transfer ICP: " + err.message;
        } finally {
            walletLoading = false;
        }
    }

    async function deleteUrl(id) {
        const urlItem = urls.find((u) => u.id === id);
        if (!confirm(`Are you sure you want to delete the short URL \"${urlItem?.shortCode || "this URL"}\"?`)) return;

        loading = true;
        error = "";
        try {
            await UrlApi.deleteUrl(id);
            urls = urls.filter((url) => url.id !== id);
            showSuccess(`Short URL deleted successfully`);
        } catch (err) {
            error = "Failed to delete URL: " + err.message;
        } finally {
            loading = false;
        }
    }

    function copyToClipboard(text) {
        navigator.clipboard.writeText(text).then(() => {
            copiedShortUrl = text;
            copiedWalletValue = text;
            showSuccess(`[COPY] ${text}`);
            setTimeout(() => {
                copiedShortUrl = "";
                copiedWalletValue = "";
            }, 2000);
        }).catch(() => {
            error = "Failed to copy to clipboard";
        });
    }

    function openUrl(url) {
        window.open(url, "_blank");
    }

    function clearError() {
        error = "";
    }

    function showSuccess(message) {
        successMessage = message;
        setTimeout(() => {
            successMessage = "";
        }, 3000);
    }

    function clearSuccess() {
        successMessage = "";
    }

    function formatDate(timestamp) {
        const milliseconds = Math.floor(timestamp / 1000000);
        return new Date(milliseconds).toLocaleString();
    }

    function isValidUrl(string) {
        try {
            new URL(string);
            return true;
        } catch {
            return false;
        }
    }

    onMount(() => {
        syncAuthState();
    });
</script>

<main>
    <div class="header">
        <h1>Tiny ICP</h1>
        <p>Paid URL shortening with a canister-managed ICP wallet.</p>
    </div>

    {#if error}
        <div class="error-message"><span>[!] {error}</span><button class="close-error" on:click={clearError} type="button">×</button></div>
    {/if}

    {#if successMessage}
        <div class="success-message"><span>[OK] {successMessage}</span><button class="close-success" on:click={clearSuccess} type="button">×</button></div>
    {/if}

    {#if showPaymentModal}
        <div class="modal-backdrop">
            <div class="modal-card">
                <p class="auth-kicker">Payment confirmation</p>
                <h2>Create this Tiny ICP URL for 1.0000 ICP?</h2>
                <p>This charge will be sent from your in-app wallet balance. Ledger network fees still apply.</p>
                <div class="modal-summary">
                    <div><strong>URL:</strong> {newUrl}</div>
                    <div><strong>Custom slug:</strong> {customSlug || "Auto-generated"}</div>
                    <div><strong>Destination account:</strong> <code>91cfa92ae9d2cb6f5fe0db77f7017dff6c3f86ccca2fdf564d1348b56347be18</code></div>
                </div>
                <div class="modal-actions">
                    <button class="refresh-btn" type="button" on:click={() => (showPaymentModal = false)}>Cancel</button>
                    <button class="shorten-btn" type="button" on:click={confirmShortenUrl}>Confirm 1 ICP Payment</button>
                </div>
            </div>
        </div>
    {/if}

    {#if authLoading && !authenticated}
        <section class="auth-shell"><div class="auth-card"><h2>Authenticating...</h2><p>Checking Internet Identity session.</p></div></section>
    {:else if !authenticated}
        <section class="auth-shell">
            <div class="auth-card">
                <p class="auth-kicker">Secure paid URL dashboard</p>
                <h2>Sign in to fund your Tiny ICP wallet</h2>
                <p>Authenticate with Internet Identity to deposit ICP, withdraw ICP, and pay 1.0 ICP per shortened URL.</p>
                <button class="shorten-btn auth-btn" type="button" on:click={handleLogin} disabled={authLoading}>{authLoading ? "Connecting..." : "[>] Login with Internet Identity"}</button>
            </div>
        </section>
    {:else}
        <section class="app-shell">
            <div class="session-bar">
                <div><strong>Authenticated principal:</strong> <code>{principal}</code></div>
                <button class="refresh-btn" type="button" on:click={handleLogout}>Sign out</button>
            </div>

            <div class="wallet-section">
                <div class="section-header">
                    <h2>In-App ICP Wallet</h2>
                    <button on:click={loadWallet} disabled={walletLoading} class="refresh-btn">{walletLoading ? "Refreshing..." : "Refresh Wallet"}</button>
                </div>
                {#if wallet}
                    <div class="wallet-grid">
                        <div class="wallet-card"><span class="wallet-label">Available balance</span><strong>{formatIcp(wallet.balanceE8s)} ICP</strong><small>Need at least {formatIcp(wallet.tinyUrlPriceE8s + wallet.transferFeeE8s)} ICP to buy one Tiny URL.</small></div>
                        <div class="wallet-card"><span class="wallet-label">Canister principal (PID)</span><code>{wallet.canisterPrincipal}</code><button class="copy-btn small" on:click={() => copyToClipboard(wallet.canisterPrincipal)}>{copiedWalletValue === wallet.canisterPrincipal ? "Copied ✓" : "Copy PID"}</button></div>
                        <div class="wallet-card full"><span class="wallet-label">Deposit account ID</span><code>{wallet.depositAccountId}</code><small>Send ICP to this account ID to fund your in-app wallet.</small><button class="copy-btn small" on:click={() => copyToClipboard(wallet.depositAccountId)}>{copiedWalletValue === wallet.depositAccountId ? "Copied ✓" : "Copy Account ID"}</button></div>
                        <div class="wallet-card full"><span class="wallet-label">Wallet subaccount</span><code>{wallet.subaccountHex}</code><small>Derived from your principal and managed by this canister.</small></div>
                    </div>
                    <form class="transfer-form" on:submit|preventDefault={transferFromWallet}>
                        <div class="form-field"><label class="form-label" for="transfer-destination">Transfer to PID or account ID</label><input id="transfer-destination" class="form-input" bind:value={transferDestination} placeholder="Principal ID or 64-char account ID" /></div>
                        <div class="form-field"><label class="form-label" for="transfer-amount">Amount (ICP)</label><input id="transfer-amount" class="form-input" type="number" min="0.0001" step="0.0001" bind:value={transferAmount} placeholder="1.2500" /></div>
                        <small class="form-help">Outgoing transfers also pay the {formatIcp(wallet.transferFeeE8s)} ICP ledger fee from your wallet balance.</small>
                        <button class="shorten-btn" type="submit" disabled={walletLoading}>Send ICP</button>
                    </form>
                {/if}
            </div>

            <div class="shorten-section">
                <form on:submit|preventDefault={requestShortenConfirmation} class="shorten-form">
                    <div class="form-field"><label for="new-url" class="form-label">Long URL</label><input id="new-url" type="url" bind:value={newUrl} placeholder="https://example.com/very/long/url..." disabled={loading} required class="form-input url-input" /></div>
                    <div class="form-field"><label for="custom-slug" class="form-label">Custom Short Code (Optional)</label><input id="custom-slug" type="text" bind:value={customSlug} placeholder="my-link" disabled={loading} pattern="[a-zA-Z0-9_-]+" maxlength="20" class="form-input" /><small class="form-help">Letters, numbers, hyphens, and underscores only</small></div>
                    <div class="action-row"><button type="submit" disabled={loading || !newUrl.trim() || !isValidUrl(newUrl)} class="shorten-btn">{loading ? "Processing..." : "[>] Shorten URL (1 ICP)"}</button></div>
                </form>
            </div>

            <div class="urls-section">
                <div class="section-header"><h2>Your Short URLs ({urls.length})</h2><button on:click={loadUrls} disabled={loading} class="refresh-btn">{loading ? "[...] Loading..." : "Refresh"}</button></div>
                {#if loading && urls.length === 0}
                    <div class="loading">Loading URLs...</div>
                {:else if urls.length === 0}
                    <div class="empty-state"><div class="empty-icon">⌁</div><p>No paid short URLs yet. Fund your wallet and create your first one above.</p></div>
                {:else}
                    <div class="urls-grid">
                        {#each urls as url (url.id)}
                            <div class="url-card">
                                <div class="url-info">
                                    <div class="url-header">
                                        <h3 class="short-code">/{url.shortCode}</h3>
                                        <div class="url-actions">
                                            <button class="copy-btn small" class:copied={copiedShortUrl === UrlApi.getShortUrl(url.shortCode)} on:click={() => copyToClipboard(UrlApi.getShortUrl(url.shortCode))}>{copiedShortUrl === UrlApi.getShortUrl(url.shortCode) ? "Copied ✓" : "Copy Url"}</button>
                                            <button class="visit-btn" on:click={() => openUrl(UrlApi.getShortUrl(url.shortCode))}>↗</button>
                                            <button on:click={() => deleteUrl(url.id)} disabled={loading} class="delete-btn">X</button>
                                        </div>
                                    </div>
                                    <div class="url-details">
                                        <p class="short-url"><strong>Short:</strong> <a href={UrlApi.getShortUrl(url.shortCode)} target="_blank" rel="noopener">{UrlApi.getShortUrl(url.shortCode)}</a></p>
                                        <p class="original-url"><strong>Original:</strong> <a href={url.originalUrl} target="_blank" rel="noopener" class="original-link">{url.originalUrl}</a></p>
                                        <div class="url-stats"><span class="stat">[HITS] {url.clicks || 0} clicks</span><span class="stat">[DATE] {formatDate(url.createdAt)}</span></div>
                                    </div>
                                </div>
                            </div>
                        {/each}
                    </div>
                {/if}
            </div>
        </section>
    {/if}
</main>
