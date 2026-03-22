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
    let showPurchaseModal = false;
    let pendingRequest = null;
    let withdrawalAccountId = "";
    let withdrawalAmountIcp = "";
    let refreshingPreviewIds = [];
    let purchasedClicks = 10_000;
    let topUpClicksByUrl = {};
    let topUpUrlId = null;
    const clickRefreshTimers = new Map();
    const customSlugPattern = /^[A-Za-z0-9_-]+$/;
    const DEFAULT_CLICK_BUNDLE_SIZE = 10_000;
    const DEFAULT_CLICK_BUNDLE_PRICE_E8S = 10_000_000;
    const DEFAULT_MINIMUM_PURCHASE_CLICKS = 10_000;
    const DEFAULT_LEDGER_FEE_E8S = 10_000;

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

        if (!authenticated) {
            error = "Please authenticate with Internet Identity before creating a short URL.";
            return;
        }

        if (customSlug.trim() && !customSlugPattern.test(customSlug.trim())) {
            error =
                "Custom short codes can use only letters, numbers, hyphens, and underscores.";
            return;
        }

        if (!isValidClickPurchase(purchasedClicks)) {
            error = `Choose at least ${formatClicks(minimumPurchaseClicks)} prepaid clicks in ${formatClicks(clickBundleSize)}-click increments.`;
            return;
        }

        error = "";
        pendingRequest = {
            originalUrl: newUrl.trim(),
            customSlug: customSlug.trim() || null,
            purchasedClicks
        };
        showPurchaseModal = true;
    }

    function cancelPurchase() {
        showPurchaseModal = false;
        pendingRequest = null;
    }

    async function confirmPurchase() {
        if (!pendingRequest) {
            showPurchaseModal = false;
            return;
        }

        loading = true;
        error = "";

        try {
            const latestWallet = await UrlApi.getWalletInfo();
            wallet = latestWallet;
            const requiredBalance =
                getClickPurchaseCostE8s(pendingRequest.purchasedClicks) +
                latestWallet.transferFeeE8s;

            if (latestWallet.balanceE8s < requiredBalance) {
                throw new Error(
                    `You need at least ${formatIcp(requiredBalance)} ICP in your in-app wallet to cover this click bundle purchase and the ledger fee.`
                );
            }

            const shortenedUrl = await UrlApi.createShortUrl(
                pendingRequest.originalUrl,
                pendingRequest.customSlug,
                pendingRequest.purchasedClicks
            );
            const hydratedUrl = await maybeHydratePreview(shortenedUrl);
            urls = [hydratedUrl, ...urls];
            newUrl = "";
            customSlug = "";
            purchasedClicks = minimumPurchaseClicks;
            showPurchaseModal = false;
            pendingRequest = null;
            await loadWallet();

            const shortCode = hydratedUrl.shortCode;
            const fullShortUrl = getPublicShortUrl(shortCode);
            showSuccess(
                `[>] Short URL created with ${formatClicks(hydratedUrl.allowance.remainingClicks)} prepaid clicks: ${fullShortUrl}`
            );
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

    async function refreshUrlPreview(id) {
        refreshingPreviewIds = [...refreshingPreviewIds, id];
        error = "";

        try {
            const refreshedUrl = await refreshUrlPreviewWithFallback(id);
            urls = urls.map((url) => (url.id === id ? refreshedUrl : url));
            showSuccess(`Preview refreshed for /${refreshedUrl.shortCode}`);
        } catch (err) {
            error = "Failed to refresh preview metadata: " + err.message;
            console.error("Error refreshing preview metadata:", err);
        } finally {
            refreshingPreviewIds = refreshingPreviewIds.filter(
                (refreshingId) => refreshingId !== id
            );
        }
    }

    async function maybeHydratePreview(url) {
        if (!url || getPreviewStatus(url) !== "missing") {
            return url;
        }

        try {
            return await syncPreviewViaBrowser(url);
        } catch (previewError) {
            console.warn("Browser preview hydration failed:", previewError);
            return url;
        }
    }

    async function refreshUrlPreviewWithFallback(id) {
        const existingUrl = urls.find((url) => url.id === id);

        try {
            return await UrlApi.refreshUrlMetadata(id);
        } catch (backendError) {
            if (!existingUrl) {
                throw backendError;
            }

            try {
                return await syncPreviewViaBrowser(existingUrl);
            } catch (browserError) {
                throw new Error(
                    `${backendError.message} Browser fallback also failed: ${browserError.message}`
                );
            }
        }
    }

    async function syncPreviewViaBrowser(url) {
        const metadata = await UrlApi.harvestMetadataInBrowser(url.originalUrl);
        return await UrlApi.saveUrlMetadata(url.id, metadata);
    }

    function formatClicks(value) {
        return Number(value || 0).toLocaleString();
    }

    function isValidClickPurchase(value) {
        const numericValue = Number(value);
        return (
            Number.isInteger(numericValue) &&
            numericValue >= minimumPurchaseClicks &&
            numericValue % clickBundleSize === 0
        );
    }

    function getClickPurchaseCostE8s(clickCount) {
        return (Number(clickCount) / clickBundleSize) * clickBundlePriceE8s;
    }

    function getClickPurchaseCostIcp(clickCount) {
        return formatIcp(getClickPurchaseCostE8s(clickCount));
    }

    function getPurchaseTotalDebitIcp(clickCount) {
        return formatIcp(
            getClickPurchaseCostE8s(clickCount) +
                (wallet?.transferFeeE8s ?? DEFAULT_LEDGER_FEE_E8S)
        );
    }

    function getUrlStatusLabel(url) {
        return url.allowance?.isActive ? "Active" : "Paused";
    }

    function getUrlStatusClass(url) {
        return url.allowance?.isActive ? "active" : "paused";
    }

    function getUrlStatusMessage(url) {
        if (url.allowance?.isActive) {
            return `${formatClicks(url.allowance.remainingClicks)} prepaid clicks remaining before this URL pauses.`;
        }

        return "This URL is paused because its prepaid click balance is empty. Top it up to reactivate it.";
    }

    function getTopUpClicksValue(urlId) {
        return topUpClicksByUrl[urlId] ?? minimumPurchaseClicks;
    }

    function setTopUpClicksValue(urlId, value) {
        const numericValue = Number(value);
        topUpClicksByUrl = {
            ...topUpClicksByUrl,
            [urlId]:
                Number.isFinite(numericValue) && numericValue > 0
                    ? Math.round(numericValue)
                    : minimumPurchaseClicks
        };
    }

    async function topUpUrl(id) {
        const clickCount = getTopUpClicksValue(id);
        const currentUrl = urls.find((url) => url.id === id);
        const wasActive = currentUrl?.allowance?.isActive ?? true;

        if (!isValidClickPurchase(clickCount)) {
            error = `Top-ups must be at least ${formatClicks(minimumPurchaseClicks)} clicks and use ${formatClicks(clickBundleSize)}-click increments.`;
            return;
        }

        loading = true;
        topUpUrlId = id;
        error = "";

        try {
            const latestWallet = await UrlApi.getWalletInfo();
            wallet = latestWallet;
            const requiredBalance =
                getClickPurchaseCostE8s(clickCount) + latestWallet.transferFeeE8s;

            if (latestWallet.balanceE8s < requiredBalance) {
                throw new Error(
                    `You need at least ${formatIcp(requiredBalance)} ICP in your in-app wallet to cover this top-up and the ledger fee.`
                );
            }

            const updatedUrl = await UrlApi.topUpUrl(id, clickCount);
            updateUrlInList(updatedUrl);
            topUpClicksByUrl = {
                ...topUpClicksByUrl,
                [id]: minimumPurchaseClicks
            };
            await loadWallet();

            showSuccess(
                wasActive
                    ? `Added ${formatClicks(clickCount)} clicks to /${updatedUrl.shortCode}.`
                    : `Reactivated /${updatedUrl.shortCode} with ${formatClicks(clickCount)} new clicks.`
            );
        } catch (err) {
            error = "Failed to top up URL clicks: " + err.message;
            console.error("Error topping up URL clicks:", err);
        } finally {
            loading = false;
            topUpUrlId = null;
        }
    }

    function updateUrlInList(updatedUrl) {
        urls = urls.map((url) => (url.id === updatedUrl.id ? updatedUrl : url));
    }

    function scheduleClickRefresh(shortCode) {
        if (!shortCode || typeof window === "undefined") {
            return;
        }

        const existingTimer = clickRefreshTimers.get(shortCode);
        if (existingTimer) {
            window.clearTimeout(existingTimer);
        }

        const timeoutId = window.setTimeout(async () => {
            clickRefreshTimers.delete(shortCode);

            try {
                const updatedUrl = await UrlApi.getPublicUrl(shortCode);
                if (updatedUrl) {
                    updateUrlInList(updatedUrl);
                }
            } catch (refreshError) {
                console.warn("Failed to refresh click count:", refreshError);
            }
        }, 1200);

        clickRefreshTimers.set(shortCode, timeoutId);
    }

    function getPublicShortUrl(shortCode) {
        return UrlApi.getPublicShortUrl(shortCode);
    }

    function getPreviewShortUrl(shortCode) {
        return UrlApi.getBackendShortUrl(shortCode);
    }

    function getUrlOptions(url) {
        const options = [
            {
                key: "preview",
                label: "Preview URL",
                description: "Longer, allows link previews",
                href: getPreviewShortUrl(url.shortCode)
            },
            {
                key: "tinyicp",
                label: "TinyICP URL",
                description: "Shorter, no link previews",
                href: getPublicShortUrl(url.shortCode)
            },
            {
                key: "original",
                label: "Original URL",
                description: "Direct destination URL",
                href: url.originalUrl
            }
        ];

        const seen = new Set();
        return options.filter((option) => {
            if (!hasText(option.href) || seen.has(option.href)) {
                return false;
            }

            seen.add(option.href);
            return true;
        });
    }

    function hasText(value) {
        return typeof value === "string" && value.trim().length > 0;
    }

    function getPreviewStatus(url) {
        const metadata = url.metadata;
        if (!metadata) {
            return "missing";
        }

        const hasTextMetadata =
            hasText(metadata.title) ||
            hasText(metadata.description) ||
            hasText(metadata.siteName) ||
            hasText(metadata.canonicalUrl);

        if (!hasTextMetadata) {
            return "missing";
        }

        return hasText(metadata.imageUrl) ? "ready" : "partial";
    }

    function getPreviewStatusLabel(url) {
        const status = getPreviewStatus(url);

        if (status === "ready") {
            return "Preview ready";
        }

        if (status === "partial") {
            return "Preview missing image";
        }

        return "Preview missing metadata";
    }

    function isRefreshingPreview(id) {
        return refreshingPreviewIds.includes(id);
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
            if (!copyWithExecCommand(text)) {
                if (navigator.clipboard?.writeText) {
                    await navigator.clipboard.writeText(text);
                } else {
                    throw new Error("execCommand copy failed");
                }
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

    function openUrl(url, shortCode = null) {
        window.open(url, "_blank", "noopener");
        scheduleClickRefresh(shortCode);
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

    async function withdrawFromWallet() {
        if (!wallet) {
            error = "Load your wallet before withdrawing ICP.";
            return;
        }

        const destinationAccountId = withdrawalAccountId.trim();
        const amountIcp = Number(withdrawalAmountIcp);

        if (!destinationAccountId) {
            error = "Enter a destination account ID to withdraw ICP.";
            return;
        }

        if (!Number.isFinite(amountIcp) || amountIcp <= 0) {
            error = "Enter a valid ICP amount greater than zero.";
            return;
        }

        const amountE8s = Math.round(amountIcp * 100_000_000);
        const totalDebitE8s = amountE8s + wallet.transferFeeE8s;
        if (wallet.balanceE8s < totalDebitE8s) {
            error = `You need at least ${formatIcp(totalDebitE8s)} ICP in your in-app wallet to cover this withdrawal and the ledger fee.`;
            return;
        }

        loading = true;
        error = "";
        try {
            await UrlApi.withdrawFromWallet(destinationAccountId, amountE8s);
            withdrawalAccountId = "";
            withdrawalAmountIcp = "";
            await loadWallet();
            showSuccess(`Withdrawn ${formatIcp(amountE8s)} ICP from your in-app wallet.`);
        } catch (err) {
            error = "Failed to withdraw ICP: " + err.message;
            console.error("Error withdrawing ICP:", err);
        } finally {
            loading = false;
        }
    }

    $: clickBundleSize = wallet
        ? wallet.clickBundleSize
        : DEFAULT_CLICK_BUNDLE_SIZE;
    $: clickBundlePriceE8s = wallet
        ? wallet.clickBundlePriceE8s
        : DEFAULT_CLICK_BUNDLE_PRICE_E8S;
    $: minimumPurchaseClicks = wallet
        ? wallet.minimumPurchaseClicks
        : DEFAULT_MINIMUM_PURCHASE_CLICKS;
    $: clickBundlePriceIcp = formatIcp(clickBundlePriceE8s);
    $: minimumPurchaseCostIcp = wallet
        ? formatIcp(wallet.minimumPurchaseCostE8s)
        : formatIcp(DEFAULT_CLICK_BUNDLE_PRICE_E8S);
    $: ledgerFeeIcp = wallet
        ? formatIcp(wallet.transferFeeE8s)
        : formatIcp(DEFAULT_LEDGER_FEE_E8S);
    $: if (!Number.isInteger(purchasedClicks) || purchasedClicks < minimumPurchaseClicks) {
        purchasedClicks = minimumPurchaseClicks;
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
        document.addEventListener("keydown", handleKeydown);

        return () => {
            document.removeEventListener("keydown", handleKeydown);
            for (const timeoutId of clickRefreshTimers.values()) {
                window.clearTimeout(timeoutId);
            }
            clickRefreshTimers.clear();
        };
    });
</script>

<svelte:head>
    <title>Tiny ICP</title>
    <meta
        name="description"
        content="Tiny ICP lets you create prepaid short URLs with click tracking, wallet funding, and instant top-ups on TinyICP.com."
    />
    <link rel="canonical" href="https://tinyicp.com/" />

    <meta property="og:type" content="website" />
    <meta property="og:title" content="Tiny ICP" />
    <meta
        property="og:description"
        content="Create prepaid short URLs with click tracking, wallet funding, and instant top-ups on TinyICP.com."
    />
    <meta property="og:url" content="https://tinyicp.com/" />
    <meta property="og:site_name" content="Tiny ICP" />
    <meta property="og:image" content="https://tinyicp.com/og-preview.png" />
    <meta property="og:image:type" content="image/png" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta
        property="og:image:alt"
        content="Tiny ICP app preview card showing the Tiny ICP name and URL."
    />

    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="Tiny ICP" />
    <meta
        name="twitter:description"
        content="Create prepaid short URLs with click tracking, wallet funding, and instant top-ups on TinyICP.com."
    />
    <meta name="twitter:image" content="https://tinyicp.com/og-preview.png" />
</svelte:head>

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
                    Your Tiny ICP wallet funds prepaid click bundles for every
                    short URL. TinyICP charges {clickBundlePriceIcp} ICP per
                    {formatClicks(clickBundleSize)} clicks, and URLs pause
                    automatically whenever their prepaid clicks run out until
                    you top them up again.
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
                            <span class="wallet-label">Click bundle pricing</span>
                            <strong>{clickBundlePriceIcp} ICP</strong>
                            <small>
                                Buys {formatClicks(clickBundleSize)} clicks.
                                Minimum purchase: {formatClicks(minimumPurchaseClicks)}
                                clicks ({minimumPurchaseCostIcp} ICP).
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
                    </div>

                    <div class="wallet-withdraw">
                        <h3>Transfer ICP out of your wallet</h3>
                        <div class="withdraw-grid">
                            <div class="form-field">
                                <label for="withdraw-account" class="form-label">Destination Account ID</label>
                                <input
                                    id="withdraw-account"
                                    type="text"
                                    bind:value={withdrawalAccountId}
                                    placeholder="Enter 64-character account ID"
                                    disabled={loading}
                                    class="form-input"
                                />
                            </div>
                            <div class="form-field">
                                <label for="withdraw-amount" class="form-label">Amount (ICP)</label>
                                <input
                                    id="withdraw-amount"
                                    type="number"
                                    min="0.0001"
                                    step="0.0001"
                                    bind:value={withdrawalAmountIcp}
                                    placeholder="0.2500"
                                    disabled={loading}
                                    class="form-input"
                                />
                            </div>
                        </div>
                        <div class="action-row wallet-actions">
                            <small class="wallet-help">
                                Withdrawals are sent from your derived in-app wallet subaccount and include the standard {ledgerFeeIcp} ICP ledger fee.
                            </small>
                            <button type="button" class="refresh-btn" on:click={withdrawFromWallet} disabled={loading}>
                                {loading ? "Sending..." : "Transfer ICP Out"}
                            </button>
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
                            maxlength="20"
                            class="form-input"
                        />
                        <small class="form-help"
                            >Letters, numbers, hyphens, and underscores only</small
                        >
                    </div>

                    <div class="form-field">
                        <label for="purchased-clicks" class="form-label"
                            >Prepaid Clicks</label
                        >
                        <input
                            id="purchased-clicks"
                            type="number"
                            min={minimumPurchaseClicks}
                            step={clickBundleSize}
                            bind:value={purchasedClicks}
                            disabled={loading}
                            class="form-input"
                        />
                        <small class="form-help">
                            {clickBundlePriceIcp} ICP per {formatClicks(clickBundleSize)}
                            clicks. URLs pause automatically when they hit 0
                            remaining clicks and can be reactivated any time
                            with a top-up.
                        </small>
                    </div>

                    <div class="action-row">
                        <button
                            type="submit"
                            disabled={loading ||
                                !newUrl.trim() ||
                                !isValidUrl(newUrl) ||
                                !isValidClickPurchase(purchasedClicks)}
                            class="shorten-btn"
                        >
                            {loading ? "Shortening..." : "[>] Shorten URL"}
                        </button>
                    </div>
                    <p class="form-help preview-note">
                        New short URLs are created through the authenticated
                        wallet flow, include prepaid clicks up front, and pause
                        automatically whenever their allowance runs out until
                        you top them up again.
                    </p>
                </form>
            </div>


            {#if showPurchaseModal}
                <div class="modal-backdrop" role="presentation">
                    <div
                        class="confirm-modal"
                        role="dialog"
                        aria-modal="true"
                        aria-labelledby="purchase-modal-title"
                    >
                        <p class="auth-kicker">Purchase confirmation</p>
                        <h2 id="purchase-modal-title">Confirm Tiny URL creation</h2>
                        <p>
                            Creating this short URL will transfer
                            <strong>{getClickPurchaseCostIcp(pendingRequest?.purchasedClicks || minimumPurchaseClicks)} ICP</strong>
                            from your in-app wallet to prepay
                            <strong>{formatClicks(pendingRequest?.purchasedClicks || minimumPurchaseClicks)} clicks</strong>.
                            If those clicks run out, the URL pauses until it is
                            topped up.
                        </p>
                        <div class="wallet-status">
                            <div><strong>Long URL:</strong> {pendingRequest?.originalUrl}</div>
                            <div>
                                <strong>Custom short code:</strong>
                                {pendingRequest?.customSlug || "Auto-generate one for me"}
                            </div>
                            <div><strong>Prepaid clicks:</strong> {formatClicks(pendingRequest?.purchasedClicks || minimumPurchaseClicks)}</div>
                            <div><strong>Price:</strong> {getClickPurchaseCostIcp(pendingRequest?.purchasedClicks || minimumPurchaseClicks)} ICP</div>
                            <div><strong>Ledger fee:</strong> {ledgerFeeIcp} ICP</div>
                            <div><strong>Wallet balance:</strong> {wallet ? `${formatIcp(wallet.balanceE8s)} ICP` : "Loading..."}</div>
                            <div><strong>Needed to proceed:</strong> {getPurchaseTotalDebitIcp(pendingRequest?.purchasedClicks || minimumPurchaseClicks)} ICP</div>
                        </div>
                        <div class="action-row modal-actions">
                            <button type="button" class="refresh-btn" on:click={cancelPurchase} disabled={loading}>
                                Cancel
                            </button>
                            <button type="button" class="shorten-btn" on:click={confirmPurchase} disabled={loading}>
                                {loading
                                    ? "Processing payment..."
                                    : `Confirm & Pay ${getClickPurchaseCostIcp(pendingRequest?.purchasedClicks || minimumPurchaseClicks)} ICP`}
                            </button>
                        </div>
                    </div>
                </div>
            {/if}

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
                                                class="visit-btn"
                                                on:click={() =>
                                                    openUrl(
                                                        getPublicShortUrl(url.shortCode),
                                                        url.shortCode
                                                    )}
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
                                        <a
                                            href={getPublicShortUrl(url.shortCode)}
                                            target="_blank"
                                            rel="noopener"
                                            class="url-primary-link"
                                            on:click={() =>
                                                scheduleClickRefresh(url.shortCode)}
                                        >
                                            {getPublicShortUrl(url.shortCode)}
                                        </a>
                                        <div class="url-stats">
                                            <span class={`stat stat-status ${getUrlStatusClass(url)}`}>
                                                [STATUS] {getUrlStatusLabel(url)}
                                            </span>
                                            <span class="stat">
                                                [REMAINING] {formatClicks(url.allowance.remainingClicks)} clicks
                                            </span>
                                            <span class="stat">[HITS] {formatClicks(url.clicks)} clicks</span>
                                            <span class="stat">[DATE] {formatDate(url.createdAt)}</span>
                                        </div>
                                        <details class="url-section-toggle">
                                            <summary class="url-section-summary">
                                                <span
                                                    class={`allowance-badge ${getUrlStatusClass(
                                                        url
                                                    )}`}
                                                >
                                                    {getUrlStatusLabel(url)}
                                                </span>
                                                <span class="url-section-hint">
                                                    {formatClicks(url.allowance.remainingClicks)}
                                                    prepaid clicks left
                                                </span>
                                            </summary>
                                            <div class="billing-panel">
                                                <p class="preview-meta">
                                                    <strong>Prepaid clicks purchased:</strong>
                                                    {formatClicks(
                                                        url.allowance.totalPurchasedClicks
                                                    )}
                                                </p>
                                                <p class="preview-meta">
                                                    <strong>Remaining clicks:</strong>
                                                    {formatClicks(
                                                        url.allowance.remainingClicks
                                                    )}
                                                </p>
                                                <p class="preview-meta">
                                                    <strong>Status:</strong>
                                                    {getUrlStatusMessage(url)}
                                                </p>
                                                <div class="billing-topup-grid">
                                                    <div class="form-field">
                                                        <label
                                                            for={`top-up-clicks-${url.id}`}
                                                            class="form-label"
                                                        >
                                                            Top Up Clicks
                                                        </label>
                                                        <input
                                                            id={`top-up-clicks-${url.id}`}
                                                            type="number"
                                                            min={minimumPurchaseClicks}
                                                            step={clickBundleSize}
                                                            value={getTopUpClicksValue(url.id)}
                                                            class="form-input"
                                                            disabled={loading}
                                                            on:input={(event) =>
                                                                setTopUpClicksValue(
                                                                    url.id,
                                                                    event.currentTarget
                                                                        .valueAsNumber
                                                                )}
                                                        />
                                                    </div>
                                                    <div class="action-row billing-actions">
                                                        <small class="wallet-help">
                                                            {clickBundlePriceIcp} ICP per
                                                            {formatClicks(clickBundleSize)} clicks.
                                                            Every top-up also includes the
                                                            {ledgerFeeIcp} ICP ledger fee.
                                                        </small>
                                                        <button
                                                            type="button"
                                                            class="refresh-btn"
                                                            on:click={() =>
                                                                topUpUrl(url.id)}
                                                            disabled={loading ||
                                                                !isValidClickPurchase(
                                                                    getTopUpClicksValue(
                                                                        url.id
                                                                    )
                                                                )}
                                                        >
                                                            {topUpUrlId === url.id
                                                                ? "Processing..."
                                                                : url.allowance.isActive
                                                                    ? `Top Up ${getClickPurchaseCostIcp(
                                                                            getTopUpClicksValue(
                                                                                url.id
                                                                            )
                                                                        )} ICP`
                                                                    : `Reactivate for ${getClickPurchaseCostIcp(
                                                                            getTopUpClicksValue(
                                                                                url.id
                                                                            )
                                                                        )} ICP`}
                                                        </button>
                                                    </div>
                                                </div>
                                            </div>
                                        </details>
                                        <details class="url-section-toggle">
                                            <summary class="url-section-summary">
                                                <span>Link options ({getUrlOptions(url).length})</span>
                                                <span class="url-section-hint"
                                                    >Expand to copy or view all URLs</span
                                                >
                                            </summary>
                                            <div class="url-links">
                                                {#each getUrlOptions(url) as option (option.key)}
                                                    <div class="url-link-row">
                                                        <div class="url-link-top">
                                                            <div class="url-link-meta">
                                                                <strong class="url-link-label"
                                                                    >{option.label}</strong
                                                                >
                                                                <span class="url-link-description"
                                                                    >{option.description}</span
                                                                >
                                                            </div>
                                                            <button
                                                                type="button"
                                                                class="copy-btn small"
                                                                class:copied={copiedShortUrl ===
                                                                    option.href}
                                                                on:click={() =>
                                                                    copyToClipboard(option.href)}
                                                            >
                                                                {copiedShortUrl === option.href
                                                                    ? "Copied ✓"
                                                                    : "Copy URL"}
                                                            </button>
                                                        </div>
                                                        <a
                                                            href={option.href}
                                                            target="_blank"
                                                            rel="noopener"
                                                            class="url-link-anchor"
                                                            class:original-link={option.key ===
                                                                "original"}
                                                            on:click={() =>
                                                                scheduleClickRefresh(
                                                                    option.key === "original"
                                                                        ? null
                                                                        : url.shortCode
                                                                )}
                                                        >
                                                            {option.href}
                                                        </a>
                                                    </div>
                                                {/each}
                                            </div>
                                        </details>
                                        <details class="url-section-toggle">
                                            <summary class="url-section-summary">
                                                <span
                                                    class={`preview-badge ${getPreviewStatus(
                                                        url
                                                    )}`}
                                                    >{getPreviewStatusLabel(url)}</span
                                                >
                                                <span class="url-section-hint"
                                                    >Expand to view preview details</span
                                                >
                                            </summary>
                                            <div class="preview-panel">
                                                <div class="preview-panel-header">
                                                    <button
                                                        type="button"
                                                        class="refresh-btn preview-refresh-btn"
                                                        on:click={() =>
                                                            refreshUrlPreview(url.id)}
                                                        disabled={loading ||
                                                            isRefreshingPreview(url.id)}
                                                    >
                                                        {isRefreshingPreview(url.id)
                                                            ? "Refreshing..."
                                                            : "Refresh Preview"}
                                                    </button>
                                                </div>
                                                {#if url.metadata}
                                                    {#if url.metadata.title}
                                                        <p class="preview-meta">
                                                            <strong>Title:</strong>
                                                            {url.metadata.title}
                                                        </p>
                                                    {/if}
                                                    {#if url.metadata.description}
                                                        <p class="preview-meta">
                                                            <strong>Description:</strong>
                                                            {url.metadata.description}
                                                        </p>
                                                    {/if}
                                                    {#if url.metadata.imageUrl}
                                                        <p class="preview-meta">
                                                            <strong>Image:</strong>
                                                            <a
                                                                href={url.metadata.imageUrl}
                                                                target="_blank"
                                                                rel="noopener"
                                                            >
                                                                {url.metadata.imageUrl}
                                                            </a>
                                                        </p>
                                                    {/if}
                                                {:else}
                                                    <p class="preview-meta">
                                                        Preview metadata has not been captured yet.
                                                    </p>
                                                {/if}
                                            </div>
                                        </details>
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
