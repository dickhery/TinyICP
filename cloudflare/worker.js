const SHORT_LINK_PREFIX = "/s/";

function normalizeOrigin(value) {
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
}

function getOrigins(env) {
  const frontendOrigin = normalizeOrigin(env.FRONTEND_ORIGIN);
  const backendOrigin = normalizeOrigin(env.BACKEND_ORIGIN);

  if (!frontendOrigin || !backendOrigin) {
    throw new Error(
      "FRONTEND_ORIGIN and BACKEND_ORIGIN must both be configured for the TinyICP router worker.",
    );
  }

  return { frontendOrigin, backendOrigin };
}

function isShortLinkRequest(url) {
  return url.pathname.startsWith(SHORT_LINK_PREFIX);
}

function buildUpstreamRequest(request, upstreamOrigin) {
  const incomingUrl = new URL(request.url);
  const upstreamUrl = new URL(`${incomingUrl.pathname}${incomingUrl.search}`, upstreamOrigin);
  const headers = new Headers(request.headers);

  // Let the upstream origin supply its own Host header.
  // We pass the public host separately so the backend can build canonical/OG URLs.
  headers.delete("host");
  headers.delete("x-tinyicp-forwarded-host");
  headers.delete("x-tinyicp-forwarded-proto");
  headers.delete("x-forwarded-host");
  headers.delete("x-forwarded-proto");
  headers.set("x-tinyicp-forwarded-host", incomingUrl.host);
  headers.set("x-tinyicp-forwarded-proto", incomingUrl.protocol.replace(":", ""));

  return new Request(upstreamUrl, {
    method: request.method,
    headers,
    body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
    redirect: "manual",
  });
}

export default {
  async fetch(request, env) {
    const incomingUrl = new URL(request.url);
    const { frontendOrigin, backendOrigin } = getOrigins(env);
    const upstreamOrigin = isShortLinkRequest(incomingUrl)
      ? backendOrigin
      : frontendOrigin;

    const response = await fetch(buildUpstreamRequest(request, upstreamOrigin));
    const headers = new Headers(response.headers);
    headers.set("x-tinyicp-router", isShortLinkRequest(incomingUrl) ? "backend" : "frontend");

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};
