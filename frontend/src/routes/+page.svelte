<script>
    import "../index.scss";
    import { onMount } from "svelte";
    import UrlApi, { formatIcp } from "$lib/urlApi.js";
    import { canisterId } from "$lib/canisters.js";
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
    let walletError = "";
    let authLoading = true;
    let authenticated = false;
    let principal = "";
    let error = "";
    let successMessage = "";
    let newUrl = "";
    let customSlug = "";
    let copiedShortUrl = "";
    let copiedWalletValue = "";
    let transferAccountId = "";
    let transferAmount = "";
    let transferring = false;

    function getBackendBaseUrl(raw = true) {
        const canisterIdAndRaw = raw ? `${canisterId}.raw` : canisterId;

        if (typeof window === "undefined") {
            return `http://${canisterIdAndRaw}.localhost:4943`;
        }

        const hostname = window.location.hostname;
        const port = window.location.port || "4943";
        const isLocal =
            hostname === "localhost" ||
            hostname === "127.0.0.1" ||
            hostname.endsWith(".localhost");

        if (isLocal) {
            return `http://${canisterIdAndRaw}.localhost:${port}`;
        }

        return `https://${canisterIdAndRaw}.icp0.io`;
    }

    $: curlCommand = (() => {
        const baseUrl = getBackendBaseUrl();

        if (!newUrl.trim()) {
            return `curl '${baseUrl}/shorten' \\
  -H 'Accept: */*' \\
  -H 'Content-Type: text/plain' \\
  -d 'https://example.com'`;
        }

        if (customSlug.trim()) {
            return `curl '${baseUrl}/shorten' \\
  -H 'Accept: */*' \\
  -H 'Content-Type: application/x-www-form-urlencoded' \\
  -d 'url=${encodeURIComponent(newUrl)}&slug=${encodeURIComponent(customSlug)}'`;
        }

        return `curl '${baseUrl}/shorten' \\
  -H 'Accept: */*' \\
  -H 'Content-Type: text/plain' \\
  -d '${newUrl}'`;
    })();

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
            walletError = "";
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
            console.error("Error loading URLs:", err);
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
        walletError = "";
        try {
            wallet = await UrlApi.getWalletInfo();
        } catch (err) {
            wallet = null;
            walletError = "Failed to load wallet: " + err.message;
            console.error("Error loading wallet:", err);
        } finally {
            walletLoading = false;
        }
    }

    async function handleLogin() {
        authLoading = true;
        error = "";
        try {
            await login();
            showSuccess("Authenticated successfully. Loading your Tiny URLs...");
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
            walletError = "";
            transferAccountId = "";
            transferAmount = "";
            showSuccess("Signed out successfully");
        } catch (err) {
            error = "Failed to sign out: " + err.message;
        } finally {
            authLoading = false;
        }
    }

    async function shortenUrl() {
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

        loading = true;
        error = "";
        try {
            const shortenedUrl = await UrlApi.createShortUrl(
                newUrl,
                customSlug || null
            );
            urls = [shortenedUrl, ...urls];
            newUrl = "";
            customSlug = "";

            const shortCode = shortenedUrl.shortCode;
            const fullShortUrl = getPublicShortUrl(shortCode);
            showSuccess(`[>] Short URL created: ${fullShortUrl}`);
        } catch (err) {
            error = "Failed to shorten URL: " + err.message;
            console.error("Error shortening URL:", err);
        } finally {
            loading = false;
        }
    }

    async function deleteUrl(id) {
        const urlItem = urls.find((u) => u.id === id);
        if (
            !confirm(
                `Are you sure you want to delete the short URL "${urlItem?.shortCode || "this URL"}"?`
            )
        )
            return;

        loading = true;
        error = "";
        try {
            await UrlApi.deleteUrl(id);
            urls = urls.filter((url) => url.id !== id);
            showSuccess(`Short URL deleted successfully`);
        } catch (err) {
            error = "Failed to delete URL: " + err.message;
            console.error("Error deleting URL:", err);
        } finally {
            loading = false;
        }
    }

    function getPublicShortUrl(shortCode) {
        if (typeof window === "undefined") {
            return `/s/${shortCode}`;
        }

        return `${window.location.origin}/s/${shortCode}`;
    }

    function copyWithExecCommand(text) {
        const textArea = document.createElement("textarea");
        textArea.value = text;
        textArea.setAttribute("readonly", "");
        textArea.style.position = "fixed";
        textArea.style.opacity = "0";
        textArea.style.pointerEvents = "none";
        document.body.appendChild(textArea);
        textArea.focus();
        textArea.select();
        textArea.setSelectionRange(0, text.length);

        try {
            return document.execCommand("copy");
        } finally {
            document.body.removeChild(textArea);
        }
    }

    async function copyToClipboard(text) {
        error = "";

        try {
            if (navigator.clipboard?.writeText) {
                await navigator.clipboard.writeText(text);
            } else if (!copyWithExecCommand(text)) {
                throw new Error("execCommand copy failed");
            }
        } catch (clipboardError) {
            if (!copyWithExecCommand(text)) {
                console.error("Clipboard copy failed:", clipboardError);
                error = "Failed to copy to clipboard. Please copy it manually.";
                return;
            }
        }

        copiedShortUrl = text;
        copiedWalletValue = text;
        showSuccess(`[C] Copied to clipboard: ${text}`);
        setTimeout(() => {
            copiedShortUrl = "";
            copiedWalletValue = "";
        }, 2000);
    }

    function openUrl(url) {
        window.open(url, "_blank");
    }

    function handleKeydown(event) {
        if (event.key === "Escape") {
            newUrl = "";
            customSlug = "";
            clearError();
        }
        if (authenticated && (event.ctrlKey || event.metaKey) && event.key === "r") {
            event.preventDefault();
            loadUrls();
        }
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

    function normalizeAccountId(value) {
        return value.trim().toLowerCase();
    }

    function isValidAccountId(value) {
        return /^[0-9a-f]{64}$/i.test(value.trim());
    }

    function parseIcpToE8s(value) {
        const normalized = value.trim();
        if (!/^\d+(\.\d{0,8})?$/.test(normalized)) {
            return null;
        }

        const [wholePart, fractionalPart = ""] = normalized.split(".");
        return Number(wholePart) * 100_000_000 + Number((fractionalPart + "00000000").slice(0, 8));
    }

    $: transferAmountE8s = parseIcpToE8s(transferAmount);
    $: transferFeeIcp = wallet ? formatIcp(wallet.transferFeeE8s) : formatIcp(0);
    $: transferCanSubmit = Boolean(
        wallet &&
            isValidAccountId(transferAccountId) &&
            transferAmountE8s &&
            transferAmountE8s > 0 &&
            transferAmountE8s + wallet.transferFeeE8s <= wallet.balanceE8s &&
            normalizeAccountId(transferAccountId) !==
                normalizeAccountId(wallet.depositAccountId)
    );

    async function transferIcp() {
        if (!wallet) {
            error = "Wallet is not available yet. Please refresh and try again.";
            return;
        }

        const destinationAccountId = normalizeAccountId(transferAccountId);
        if (!isValidAccountId(destinationAccountId)) {
            error = "Enter a valid 64-character destination account ID.";
            return;
        }

        if (!transferAmountE8s || transferAmountE8s <= 0) {
            error = "Enter a transfer amount greater than 0 ICP.";
            return;
        }

        if (destinationAccountId === normalizeAccountId(wallet.depositAccountId)) {
            error = "Destination account must be different from your Tiny ICP deposit account.";
            return;
        }

        if (transferAmountE8s + wallet.transferFeeE8s > wallet.balanceE8s) {
            error = `Insufficient balance. You need ${formatIcp(transferAmountE8s + wallet.transferFeeE8s)} ICP including the network fee.`;
            return;
        }

        transferring = true;
        error = "";
        try {
            const blockIndex = await UrlApi.transferIcp(destinationAccountId, transferAmountE8s);
            showSuccess(`ICP transferred successfully in ledger block ${blockIndex}.`);
            transferAmount = "";
            await loadWallet();
        } catch (err) {
            error = "Failed to transfer ICP: " + err.message;
            console.error("Error transferring ICP:", err);
        } finally {
            transferring = false;
        }
    }

    onMount(() => {
        syncAuthState();
        document.addEventListener("keydown", handleKeydown);

        return () => {
            document.removeEventListener("keydown", handleKeydown);
        };
    });
</script>

<main>
    <div class="header">
        <h1>Tiny ICP</h1>
        <p>
            Shorten URLs with HTTP-native features using <a
                href="https://mops.one/liminal"
                target="_blank">Liminal HTTP framework</a
            > for Motoko
        </p>
    </div>

    {#if error}
        <div class="error-message">
            <span>[!] {error}</span>
            <button class="close-error" on:click={clearError} type="button"
                >×</button
            >
        </div>
    {/if}

    {#if successMessage}
        <div class="success-message">
            <span>[OK] {successMessage}</span>
            <button class="close-success" on:click={clearSuccess} type="button"
                >×</button
            >
        </div>
    {/if}

    {#if authLoading && !authenticated}
        <section class="auth-shell">
            <div class="auth-card">
                <h2>Authenticating...</h2>
                <p>Checking Internet Identity session.</p>
            </div>
        </section>
    {:else if !authenticated}
        <section class="auth-shell">
            <div class="auth-card">
                <p class="auth-kicker">Secure personal URL dashboard</p>
                <h2>Sign in to view your Tiny URLs</h2>
                <p>
                    Authenticate with Internet Identity to access only the short
                    links you created in Tiny ICP.
                </p>
                <button
                    class="shorten-btn auth-btn"
                    type="button"
                    on:click={handleLogin}
                    disabled={authLoading}
                >
                    {authLoading ? "Connecting..." : "[>] Login with Internet Identity"}
                </button>
                <p class="auth-footnote">
                    After signing in, this screen disappears and your personal
                    dashboard loads automatically.
                </p>
            </div>
        </section>
    {:else}
        <section class="app-shell">
            <div class="session-bar">
                <div>
                    <strong>Authenticated principal:</strong>
                    <code>{principal}</code>
                </div>
                <button class="refresh-btn" type="button" on:click={handleLogout}
                    >Sign out</button
                >
            </div>

            <div class="wallet-section">
                <div class="section-header">
                    <h2>In-App ICP Wallet</h2>
                    <button
                        on:click={loadWallet}
                        disabled={walletLoading}
                        class="refresh-btn"
                    >
                        {walletLoading ? "Refreshing..." : "Refresh Wallet"}
                    </button>
                </div>
                <p class="wallet-help">
                    Fund your Tiny ICP wallet by sending ICP to the deposit
                    account below, then transfer ICP back out whenever you need
                    to.
                </p>
                {#if walletLoading && !wallet}
                    <div class="wallet-status">Loading your wallet details...</div>
                {:else if wallet}
                    <div class="wallet-grid">
                        <div class="wallet-card">
                            <span class="wallet-label">Available balance</span>
                            <strong>{formatIcp(wallet.balanceE8s)} ICP</strong>
                            <small>
                                Deposit ICP into your account ID below to fund
                                this wallet.
                            </small>
                        </div>
                        <div class="wallet-card">
                            <span class="wallet-label">Transfer fee</span>
                            <strong>{transferFeeIcp} ICP</strong>
                            <small>
                                Each outgoing ICP transfer includes the ICP
                                ledger network fee.
                            </small>
                        </div>
                        <div class="wallet-card full">
                            <span class="wallet-label">Deposit account ID</span>
                            <code>{wallet.depositAccountId}</code>
                            <small>
                                Send ICP to this account ID to fund your Tiny ICP
                                wallet balance.
                            </small>
                            <button
                                class="copy-btn small"
                                class:copied={copiedWalletValue === wallet.depositAccountId}
                                on:click={() => copyToClipboard(wallet.depositAccountId)}
                            >
                                {copiedWalletValue === wallet.depositAccountId
                                    ? "Copied ✓"
                                    : "Copy Account ID"}
                            </button>
                        </div>
                        <div class="wallet-card full">
                            <span class="wallet-label">Transfer ICP</span>
                            <div class="wallet-transfer-fields">
                                <div class="form-field wallet-form-field">
                                    <label for="transfer-account-id" class="form-label">Destination account ID</label>
                                    <input
                                        id="transfer-account-id"
                                        type="text"
                                        bind:value={transferAccountId}
                                        placeholder="64-character ICP account ID"
                                        class="form-input"
                                        autocapitalize="off"
                                        spellcheck="false"
                                        disabled={transferring}
                                    />
                                </div>
                                <div class="form-field wallet-form-field">
                                    <label for="transfer-amount" class="form-label">Amount (ICP)</label>
                                    <input
                                        id="transfer-amount"
                                        type="text"
                                        bind:value={transferAmount}
                                        placeholder="0.25"
                                        inputmode="decimal"
                                        class="form-input"
                                        disabled={transferring}
                                    />
                                </div>
                            </div>
                            <small>
                                You can transfer up to
                                {formatIcp(Math.max(wallet.balanceE8s - wallet.transferFeeE8s, 0))}
                                ICP after accounting for the {transferFeeIcp} ICP fee.
                            </small>
                            <div class="wallet-transfer-actions">
                                <button
                                    class="shorten-btn wallet-transfer-btn"
                                    type="button"
                                    on:click={transferIcp}
                                    disabled={!transferCanSubmit || transferring}
                                >
                                    {transferring ? "Sending..." : "Transfer ICP"}
                                </button>
                            </div>
                        </div>
                    </div>
                {:else}
                    <div class="wallet-status warning">
                        <strong>Wallet unavailable.</strong>
                        <div>{walletError || "We could not load your wallet details yet."}</div>
                        <small>Use Refresh Wallet to try again.</small>
                    </div>
                {/if}
            </div>

            <div class="shorten-section">
                <form on:submit|preventDefault={shortenUrl} class="shorten-form">
                    <div class="form-field">
                        <label for="new-url" class="form-label">Long URL</label>
                        <input
                            id="new-url"
                            type="url"
                            bind:value={newUrl}
                            placeholder="https://example.com/very/long/url..."
                            disabled={loading}
                            required
                            class="form-input url-input"
                        />
                    </div>

                    <div class="form-field">
                        <label for="custom-slug" class="form-label"
                            >Custom Short Code (Optional)</label
                        >
                        <input
                            id="custom-slug"
                            type="text"
                            bind:value={customSlug}
                            placeholder="my-link"
                            disabled={loading}
                            pattern="[a-zA-Z0-9_-]+"
                            maxlength="20"
                            class="form-input"
                        />
                        <small class="form-help"
                            >Letters, numbers, hyphens, and underscores only</small
                        >
                    </div>

                    <div class="action-row">
                        <button
                            type="submit"
                            disabled={loading || !newUrl.trim() || !isValidUrl(newUrl)}
                            class="shorten-btn"
                        >
                            {loading ? "Shortening..." : "[>] Shorten URL"}
                        </button>

                        <div
                            class="curl-alternative"
                            class:disabled={!newUrl.trim() || !isValidUrl(newUrl)}
                        >
                            <p class="curl-label">Or use curl:</p>
                            <div class="curl-command-container">
                                <code class="curl-command dynamic">{curlCommand}</code>
                                <button
                                    type="button"
                                    class="copy-btn"
                                    disabled={!newUrl.trim() || !isValidUrl(newUrl)}
                                    on:click={() => copyToClipboard(curlCommand)}
                                >
                                    [COPY] Copy curl
                                </button>
                            </div>
                        </div>
                    </div>
                </form>
            </div>

            <div class="urls-section">
                <div class="section-header">
                    <h2>Your Short URLs ({urls.length})</h2>
                    <button on:click={loadUrls} disabled={loading} class="refresh-btn">
                        {loading ? "[...] Loading..." : "Refresh"}
                    </button>
                </div>

                {#if loading && urls.length === 0}
                    <div class="loading">Loading URLs...</div>
                {:else if urls.length === 0}
                    <div class="empty-state">
                        <div class="empty-icon">⌁</div>
                        <p>No short URLs yet. Create your first one above!</p>
                    </div>
                {:else}
                    <div class="urls-grid">
                        {#each urls as url (url.id)}
                            <div class="url-card">
                                <div class="url-info">
                                    <div class="url-header">
                                        <h3 class="short-code">/{url.shortCode}</h3>
                                        <div class="url-actions">
                                            <button
                                                class="copy-btn small"
                                                class:copied={copiedShortUrl ===
                                                    getPublicShortUrl(url.shortCode)}
                                                on:click={() =>
                                                    copyToClipboard(
                                                        getPublicShortUrl(url.shortCode)
                                                    )}
                                            >
                                                {copiedShortUrl ===
                                                getPublicShortUrl(url.shortCode)
                                                    ? "Copied ✓"
                                                    : "Copy Url"}
                                            </button>
                                            <button
                                                class="visit-btn"
                                                on:click={() =>
                                                    openUrl(getPublicShortUrl(url.shortCode))}
                                            >
                                                ↗
                                            </button>
                                            <button
                                                on:click={() => deleteUrl(url.id)}
                                                disabled={loading}
                                                class="delete-btn"
                                            >
                                                X
                                            </button>
                                        </div>
                                    </div>

                                    <div class="url-details">
                                        <p class="short-url">
                                            <strong>Short:</strong>
                                            <a
                                                href={getPublicShortUrl(url.shortCode)}
                                                target="_blank"
                                                rel="noopener"
                                            >
                                                {getPublicShortUrl(url.shortCode)}
                                            </a>
                                        </p>
                                        <p class="original-url">
                                            <strong>Original:</strong>
                                            <a
                                                href={url.originalUrl}
                                                target="_blank"
                                                rel="noopener"
                                                class="original-link"
                                            >
                                                {url.originalUrl}
                                            </a>
                                        </p>
                                        <div class="url-stats">
                                            <span class="stat">[HITS] {url.clicks || 0} clicks</span>
                                            <span class="stat">[DATE] {formatDate(url.createdAt)}</span>
                                        </div>
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
