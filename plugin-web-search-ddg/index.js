/**
 * DuckDuckGo Lite search provider for dsh's web capability seam (`ctx.web`).
 * No API key required; scrapes the HTML Lite endpoint and maps rows to
 * `WebSearchSource`. From networks where DuckDuckGo is unreachable, set the
 * plugin's `endpoint` config to a reachable mirror/proxy of the same shape.
 * @module @local/web-search-ddg
 */
import z from "@deepseek-ai/schemastery";
import { WebError } from "@deepseek-ai/dsh-web";

/** Stable id this provider registers under. */
const DDG_PROVIDER_ID = "ddg-lite";
/** DuckDuckGo Lite base endpoint; `/lite` is appended. */
const DDG_DEFAULT_ENDPOINT = "https://lite.duckduckgo.com";
/** Default upper bound applied at the request layer (cost/latency optimization). */
const DDG_DEFAULT_MAX_RESULTS = 8;
/** Default per-search timeout in milliseconds. */
const DDG_DEFAULT_TIMEOUT_MS = 15000;
/** Attribution header sent on every request. Bump with the package version. */
const USER_AGENT = "deepseek-harness-web-search-ddg/1.0.0";

/** Decode the handful of HTML entities the Lite endpoint emits. */
function decodeEntities(text) {
	return text
		.replaceAll("&amp;", "&")
		.replaceAll("&lt;", "<")
		.replaceAll("&gt;", ">")
		.replaceAll("&quot;", '"')
		.replaceAll("&#x27;", "'")
		.replaceAll("&#39;", "'")
		.replaceAll("&nbsp;", " ");
}

/** Strip tags, collapse whitespace. */
function cleanHtml(text) {
	return decodeEntities(text.replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim();
}

/**
 * Resolve a Lite result link to a plain target URL. Lite wraps targets in
 * `/l/?uddg=<urlencoded>` redirects; unwrap them so sources carry the real URL.
 */
function resolveTarget(href) {
	try {
		const url = new URL(href, DDG_DEFAULT_ENDPOINT);
		const uddg = url.searchParams.get("uddg");
		if (uddg != null && uddg.length > 0) return decodeEntities(uddg);
		return url.toString();
	} catch {
		return href;
	}
}

/**
 * Parse the Lite results page. Each row is `<tr>` pairs: a link row
 * (`a.result-link`) followed by a snippet row (`td.result-snippet`).
 * Returns deduped `{ url, title, snippet }` triples in page order.
 */
function parseLitePage(html) {
	const sources = [];
	const seen = new Set();
	const rowRe = /class="result-link"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g;
	const snippetRe = /class="result-snippet"[^>]*>([\s\S]*?)<\/td>/g;
	const links = [];
	let match;
	while ((match = rowRe.exec(html)) != null) links.push({ href: match[1], title: cleanHtml(match[2]) });
	const snippets = [];
	while ((match = snippetRe.exec(html)) != null) snippets.push(cleanHtml(match[1]));
	for (let i = 0; i < links.length; i += 1) {
		const url = resolveTarget(links[i].href);
		if (url.length === 0 || seen.has(url)) continue;
		seen.add(url);
		sources.push({
			url,
			...(links[i].title.length > 0 ? { title: links[i].title } : {}),
			...(snippets[i] != null && snippets[i].length > 0 ? { snippet: snippets[i] } : {})
		});
	}
	return sources;
}

/** True for a fetch/`AbortSignal` abort, surfaced as `WEB_ABORTED`. */
function isAbortError(error) {
	return error instanceof DOMException && error.name === "AbortError";
}

/** Wrap cancellation while retaining the caller's reason. */
function searchAborted(signal, fallback) {
	return new WebError("DuckDuckGo search aborted", "WEB_ABORTED", {
		cause: signal?.aborted === true ? signal.reason : fallback
	});
}

/** Resolved options for one search operation: `{ endpoint, maxResults, timeoutMs }`. */

/**
 * The DuckDuckGo Lite-backed search provider. `resolveOptions` is a thunk so
 * config changes between searches never require re-registering the provider.
 */
export class DuckDuckGoSearchProvider {
	#resolveOptions;
	id = DDG_PROVIDER_ID;

	constructor(resolveOptions) {
		this.#resolveOptions = resolveOptions;
	}

	available() {
		// Cheap local check only: the provider needs no credentials, so it is
		// always usable; unreachable networks surface as WEB_PROVIDER_ERROR.
		return true;
	}

	async search(request, signal) {
		const options = this.#resolveOptions();
		const query = request.query.trim();
		if (query.length === 0) {
			throw new WebError("DuckDuckGo search query is empty", "WEB_PROVIDER_ERROR");
		}
		const body = new URLSearchParams({ q: query });
		const timeout = AbortSignal.timeout(options.timeoutMs);
		const composed = signal != null ? AbortSignal.any([signal, timeout]) : timeout;
		let response;
		try {
			response = await fetch(`${options.endpoint}/lite`, {
				method: "POST",
				headers: {
					"content-type": "application/x-www-form-urlencoded",
					"user-agent": USER_AGENT,
					accept: "text/html"
				},
				body: body.toString(),
				signal: composed
			});
		} catch (error) {
			if (isAbortError(error)) throw searchAborted(signal, error);
			throw new WebError(
				`DuckDuckGo search request failed: ${error?.message ?? String(error)}`,
				"WEB_PROVIDER_ERROR",
				{ cause: error }
			);
		}
		if (!response.ok) {
			throw new WebError(
				`DuckDuckGo search returned HTTP ${response.status}`,
				"WEB_PROVIDER_ERROR"
			);
		}
		const html = await response.text();
		const all = parseLitePage(html);
		const bound = request.maxResults ?? options.maxResults;
		const sources = all.slice(0, bound);
		if (sources.length === 0) {
			throw new WebError(
				"DuckDuckGo search returned no parsable results (endpoint may be blocked or serving an anomaly page)",
				"WEB_PROVIDER_ERROR"
			);
		}
		// The seam owns final truncation and sets `truncated`; providers stay false.
		return { sources, truncated: false };
	}
}

/** Cordis plugin name used by loader diagnostics. */
const name = "web-search-ddg";
/** The web seam this provider registers into. */
const inject = ["web"];
const Config = z.object({
	/** Lite endpoint base; `/lite` is appended. Point at a mirror/proxy when DDG is unreachable. */
	endpoint: z.string().default(DDG_DEFAULT_ENDPOINT).volatile(),
	/** Request-layer result bound when the caller omits `maxResults`. */
	maxResults: z.number().step(1).min(1).max(20).default(DDG_DEFAULT_MAX_RESULTS).volatile(),
	/** Per-search timeout in milliseconds. */
	timeoutMs: z.number().step(1).min(1000).default(DDG_DEFAULT_TIMEOUT_MS).volatile()
});

/** Project one config section into the options the provider serves its next search with. */
function resolveOptions(config) {
	return {
		endpoint: config.endpoint.get(),
		maxResults: config.maxResults.get(),
		timeoutMs: config.timeoutMs.get()
	};
}

/** Register the DuckDuckGo search provider with `ctx.web`. */
function apply(ctx, config) {
	const unregister = ctx.web.registerSearchProvider(
		new DuckDuckGoSearchProvider(() => resolveOptions(config))
	);
	return unregister;
}

export { Config, DDG_DEFAULT_ENDPOINT, DDG_PROVIDER_ID, apply, inject, name };
