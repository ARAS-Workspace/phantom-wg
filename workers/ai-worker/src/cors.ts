import { CONFIG } from './config';
import type { Env } from './types';

/**
 * Origin-allowlist CORS. Never wildcard: every response (success AND error)
 * echoes the request origin only when allowlisted, always with Vary: Origin.
 */

function allowedOrigins(env: Env): readonly string[] {
	return env.ENVIRONMENT === 'development'
		? [...CONFIG.cors.allowedOrigins, ...CONFIG.cors.devOrigins]
		: CONFIG.cors.allowedOrigins;
}

/**
 * CORS headers for the given request. Returns Vary-only when the origin is
 * absent (same-origin/no-CORS request) or not allowlisted — the browser
 * blocks disallowed cross-origin reads on its own.
 * @example const cors = corsHeaders(request, env);
 */
export function corsHeaders(request: Request, env: Env): Record<string, string> {
	const origin = request.headers.get('Origin');
	const headers: Record<string, string> = { 'Vary': 'Origin' };

	if (origin && allowedOrigins(env).includes(origin)) {
		headers['Access-Control-Allow-Origin'] = origin;
		headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS';
		headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization';
		headers['Access-Control-Max-Age'] = String(CONFIG.cors.maxAgeSeconds);
	}

	return headers;
}

/**
 * Preflight response (OPTIONS).
 * @example if (request.method === 'OPTIONS') return preflightResponse(request, env);
 */
export function preflightResponse(request: Request, env: Env): Response {
	return new Response(null, { status: 204, headers: corsHeaders(request, env) });
}
