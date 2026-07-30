import { CONFIG } from '../config';
import type { SessionPayload } from '../types';

/**
 * HMAC-signed session tokens (WebCrypto, no JWT library, stateless verify).
 * Format: base64url(payloadJson) + '.' + base64url(HMAC-SHA-256(base64url(payloadJson))).
 * The signature covers the ENCODED payload string, so there is no
 * canonicalization surface — the exact bytes the client echoes are signed.
 */

const encoder = new TextEncoder();

function base64urlEncode(bytes: Uint8Array): string {
	let binary = '';
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64urlDecode(value: string): Uint8Array | null {
	try {
		const base64 = value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (value.length % 4)) % 4);
		const binary = atob(base64);
		return Uint8Array.from(binary, (c) => c.charCodeAt(0));
	} catch {
		return null;
	}
}

async function hmacKey(signingKey: string): Promise<CryptoKey> {
	return crypto.subtle.importKey('raw', encoder.encode(signingKey), { name: 'HMAC', hash: 'SHA-256' }, false, [
		'sign',
		'verify',
	]);
}

async function signPayload(encodedPayload: string, signingKey: string): Promise<Uint8Array> {
	const key = await hmacKey(signingKey);
	const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(encodedPayload));
	return new Uint8Array(signature);
}

/**
 * Issue a fresh session token.
 * @example const { token, payload } = await issueSessionToken(env.SESSION_SIGNING_KEY);
 */
export async function issueSessionToken(signingKey: string): Promise<{ token: string; payload: SessionPayload }> {
	const now = Math.floor(Date.now() / 1000);
	const payload: SessionPayload = {
		sid: crypto.randomUUID(),
		iat: now,
		exp: now + CONFIG.session.ttlSeconds,
	};

	const encodedPayload = base64urlEncode(encoder.encode(JSON.stringify(payload)));
	const signature = await signPayload(encodedPayload, signingKey);

	return { token: `${encodedPayload}.${base64urlEncode(signature)}`, payload };
}

/**
 * Verify signature + expiry; constant-time signature comparison. Returns the
 * payload or null, which the caller maps to 401.
 *
 * The order is load-bearing: the HMAC is checked before the payload is decoded
 * and parsed, so attacker-supplied bytes never reach `JSON.parse`.
 * @example const payload = await verifySessionToken(bearer, env.SESSION_SIGNING_KEY);
 */
export async function verifySessionToken(token: string, signingKey: string): Promise<SessionPayload | null> {
	const parts = token.split('.');
	if (parts.length !== 2 || !parts[0] || !parts[1]) {
		return null;
	}
	const [encodedPayload, encodedSignature] = parts;

	const givenSignature = base64urlDecode(encodedSignature);
	if (givenSignature === null || givenSignature.length !== 32) {
		return null;
	}

	const expectedSignature = await signPayload(encodedPayload, signingKey);
	if (!crypto.subtle.timingSafeEqual(expectedSignature, givenSignature)) {
		return null;
	}

	const payloadBytes = base64urlDecode(encodedPayload);
	if (payloadBytes === null) {
		return null;
	}

	let parsed: unknown;
	try {
		parsed = JSON.parse(new TextDecoder().decode(payloadBytes));
	} catch {
		return null;
	}

	if (typeof parsed !== 'object' || parsed === null) {
		return null;
	}

	const { sid, iat, exp } = parsed as Record<string, unknown>;
	if (typeof sid !== 'string' || typeof iat !== 'number' || typeof exp !== 'number') {
		return null;
	}
	if (exp <= Math.floor(Date.now() / 1000)) {
		return null;
	}

	return { sid, iat, exp };
}
