// noinspection JSUnusedGlobalSymbols

/**
 * Phantom-WG — Check Worker
 *
 * IP geolocation + DNS leak test subdomain generator.
 * Domain: check.phantom.tc
 *
 * Endpoints:
 *   GET  /ip           → Client IP + geolocation
 *   POST /dns/generate → Generate HMAC-signed subdomains for DNS leak test
 *   POST /dns/lookup   → Enrich resolver IPs with geolocation (MaxMind GeoLite)
 *   GET  /health       → Health check
 *
 * DNS leak test results are returned directly by the DNS server via HTTPS,
 * not through this worker.
 *
 * Copyright (c) 2025 Rıza Emre ARAS
 * Licensed under AGPL-3.0
 */

interface Env {
	SHARED_SECRET: string;
	DNS_ZONE: string;
	TURNSTILE_SECRET: string;
	MAXMIND_ACCOUNT_ID: string;
	MAXMIND_LICENSE_KEY: string;
}

const CORS_HEADERS = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
	'Access-Control-Allow-Headers': 'Content-Type, CF-Turnstile-Token',
};

const QUERY_COUNT = 6;

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		if (request.method === 'OPTIONS') {
			return new Response(null, { headers: CORS_HEADERS });
		}

		const url = new URL(request.url);

		try {
			switch (url.pathname) {
				case '/ip':
					return handleIP(request);
				case '/dns/generate':
					return await handleDnsGenerate(request, env);
				case '/dns/lookup':
					return await handleDnsLookup(request, env);
				case '/health':
					return json({ status: 'ok' });
				default:
					return json({ error: 'not found' }, 404);
			}
		} catch {
			return json({ error: 'internal error' }, 500);
		}
	},
};

// ── /ip ──────────────────────────────────────────────────

function handleIP(request: Request): Response {
	const cf = (request as any).cf || {};

	return json({
		ip: request.headers.get('CF-Connecting-IP') || 'unknown',
		country: cf.country || null,
		city: cf.city || null,
		region: cf.region || null,
		isp: cf.asOrganization || null,
		asn: cf.asn ? `AS${cf.asn}` : null,
	});
}

// ── /dns/start ───────────────────────────────────────────

async function handleDnsGenerate(request: Request, env: Env): Promise<Response> {
	if (request.method !== 'POST') {
		return json({ error: 'method not allowed' }, 405);
	}

	// Turnstile verification
	const turnstileToken = request.headers.get('CF-Turnstile-Token');
	if (!turnstileToken) {
		return json({ error: 'missing turnstile token' }, 403);
	}

	const turnstileOk = await verifyTurnstile(turnstileToken, env.TURNSTILE_SECRET);
	if (!turnstileOk) {
		return json({ error: 'invalid turnstile token' }, 403);
	}

	const domains: string[] = [];

	const timestamp = Math.floor(Date.now() / 1000).toString();

	for (let i = 0; i < QUERY_COUNT; i++) {
		const random = crypto.randomUUID().replace(/-/g, '').slice(0, 16);
		const hmac = await computeHMAC(random + timestamp, env.SHARED_SECRET);
		domains.push(`${random}-${hmac}-${timestamp}.${env.DNS_ZONE}`);
	}

	return json({ domains });
}

// ── /dns/lookup ──────────────────────────────────────────

interface LookupRequest {
	ips: string[];
}

interface GeoResult {
	ip: string;
	country_code: string | null;
	location: string | null;
	isp: string | null;
	asn: string | null;
}

async function handleDnsLookup(request: Request, env: Env): Promise<Response> {
	if (request.method !== 'POST') {
		return json({ error: 'method not allowed' }, 405);
	}

	const turnstileToken = request.headers.get('CF-Turnstile-Token');
	if (!turnstileToken) {
		return json({ error: 'missing turnstile token' }, 403);
	}
	if (!(await verifyTurnstile(turnstileToken, env.TURNSTILE_SECRET))) {
		return json({ error: 'invalid turnstile token' }, 403);
	}

	const body = (await request.json()) as LookupRequest;
	if (!body.ips || !Array.isArray(body.ips) || body.ips.length === 0) {
		return json({ error: 'missing ips array' }, 400);
	}

	// Limit to 20 IPs per request
	const ips = [...new Set(body.ips)].slice(0, 20);
	const auth = btoa(`${env.MAXMIND_ACCOUNT_ID}:${env.MAXMIND_LICENSE_KEY}`);

	const results: GeoResult[] = await Promise.all(
		ips.map(async (ip): Promise<GeoResult> => {
			try {
				const resp = await fetch(`https://geolite.info/geoip/v2.1/city/${ip}`, {
					headers: { Authorization: `Basic ${auth}` },
				});

				if (!resp.ok) {
					return { ip, country_code: null, location: null, isp: null, asn: null };
				}

				const data = (await resp.json()) as any;

				const city = data.city?.names?.en;
				const country = data.country?.names?.en;
				const location = city && country ? `${city}, ${country}` : country || city || null;

				return {
					ip,
					country_code: data.country?.iso_code || null,
					location,
					isp: data.traits?.autonomous_system_organization || null,
					asn: data.traits?.autonomous_system_number ? `AS${data.traits.autonomous_system_number}` : null,
				};
			} catch {
				return { ip, country_code: null, location: null, isp: null, asn: null };
			}
		}),
	);

	return json({ results });
}

// ── Helpers ──────────────────────────────────────────────

async function verifyTurnstile(token: string, secret: string): Promise<boolean> {
	const resp = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: `secret=${encodeURIComponent(secret)}&response=${encodeURIComponent(token)}`,
	});
	const data = (await resp.json()) as { success: boolean };
	return data.success;
}

async function computeHMAC(payload: string, secret: string): Promise<string> {
	const key = await crypto.subtle.importKey(
		'raw',
		new TextEncoder().encode(secret),
		{ name: 'HMAC', hash: 'SHA-256' },
		false,
		['sign'],
	);
	const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload));
	const hex = Array.from(new Uint8Array(sig))
		.map((b) => b.toString(16).padStart(2, '0'))
		.join('');
	return hex.slice(0, 16);
}

function json(data: unknown, status = 200): Response {
	return new Response(JSON.stringify(data), {
		status,
		headers: {
			'Content-Type': 'application/json',
			...CORS_HEADERS,
		},
	});
}
