import { CONFIG } from '../config';
import { logWarn } from '../utils/logging';
import type { Env, TurnstileVerifyResponse } from '../types';

/**
 * Cloudflare Turnstile server-side verification (siteverify).
 * Sends secret + response + remoteip; requires `success`
 * AND an allowlisted response `hostname` (skipped in development, where
 * dummy keys report placeholder hostnames). Fails closed on network errors.
 * @see https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
 */

const SITEVERIFY_URL = 'https://challenges.cloudflare.com/turnstile/v0/siteverify';

/**
 * How long siteverify may take before the challenge is treated as unverified.
 * Bounded for the same reason the llms-full fetch is: this call decides whether
 * a session is issued at all, so a request that hangs leaves the visitor
 * watching a solved challenge that never opens the chat. Failing fast turns
 * that into the 403 the caller already handles, and the visitor can retry.
 */
const SITEVERIFY_TIMEOUT_MS = 5_000;

export interface TurnstileVerdict {
	ok: boolean;
	errorCodes: string[];
}

/**
 * @example const verdict = await verifyTurnstileToken(env, token, clientIp);
 */
export async function verifyTurnstileToken(env: Env, token: string, remoteIp: string): Promise<TurnstileVerdict> {
	try {
		const response = await fetch(SITEVERIFY_URL, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				secret: env.TURNSTILE_SECRET_KEY,
				response: token,
				remoteip: remoteIp,
			}),
			signal: AbortSignal.timeout(SITEVERIFY_TIMEOUT_MS),
		});

		const data = (await response.json()) as TurnstileVerifyResponse;
		const errorCodes = data['error-codes'] ?? [];

		if (!data.success) {
			logWarn('turnstile_rejected', { errorCodes });
			return { ok: false, errorCodes };
		}

		const isDevelopment = env.ENVIRONMENT === 'development';
		const hostnameAllowed =
			isDevelopment ||
			(typeof data.hostname === 'string' &&
				(CONFIG.session.expectedHostnames as readonly string[]).includes(data.hostname));

		if (!hostnameAllowed) {
			logWarn('turnstile_hostname_mismatch', { hostname: data.hostname ?? null });
			return { ok: false, errorCodes: ['hostname-mismatch'] };
		}

		return { ok: true, errorCodes: [] };
	} catch (error) {
		logWarn('turnstile_siteverify_unreachable', { message: error instanceof Error ? error.message : String(error) });
		return { ok: false, errorCodes: ['internal-error'] };
	}
}
