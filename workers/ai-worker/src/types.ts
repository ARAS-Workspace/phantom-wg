import type { Locale } from './translations';

// ============================================================================
// Worker Environment
// ============================================================================

export interface Env {
	// Bindings
	AI_LOGS_DB: D1Database;

	// Secrets
	TURNSTILE_SECRET_KEY: string;
	SESSION_SIGNING_KEY: string;

	/**
	 * AI Gateway access token — the only credential this worker holds for
	 * reaching the model.
	 *
	 * There is no Anthropic key here. It lives in the gateway, which attaches it
	 * on the way out, so this token is what stands between the internet and that
	 * key: the gateway must be configured as authenticated, or anyone who learns
	 * its URL can spend it.
	 *
	 * Optional in the type and required at runtime — a worker deployed without
	 * it refuses to answer rather than falling back to an unmetered path.
	 */
	CF_AIG_TOKEN?: string;

	// Vars
	ENVIRONMENT?: string;
	/** Gateway provider endpoint; required at runtime, see `CF_AIG_TOKEN`. */
	ANTHROPIC_BASE_URL?: string;
	/** Alias of the provider key stored in the gateway; unset means `default`. */
	CF_AIG_KEY_ALIAS?: string;
}

// ============================================================================
// Requests
// ============================================================================

export interface ChatMessage {
	role: 'user' | 'assistant';
	content: string;
}

/**
 * The validated part of a POST /api/v1/chat body. The request also carries
 * `locale`, which is read during validation and travels separately on the
 * result; unknown or legacy fields (stream, max_tokens, temperature,
 * turnstileToken) are ignored rather than rejected.
 */
export interface ChatRequest {
	messages: ChatMessage[];
}

// ============================================================================
// Session Token
// ============================================================================

/** Signed payload: `base64url(json).base64url(hmac-sha256)`. */
export interface SessionPayload {
	/** Session id (UUID) — log correlation only. */
	sid: string;
	/** Issued at, Unix epoch seconds. */
	iat: number;
	/** Expires at, Unix epoch seconds. */
	exp: number;
}

export interface SessionResponse {
	token: string;
	/** Unix epoch milliseconds. */
	expiresAt: number;
}

// ============================================================================
// Errors — envelope kept verbatim from the reference implementation
// ============================================================================

export type ErrorType =
	| 'VALIDATION_ERROR'
	| 'PAYLOAD_TOO_LARGE'
	| 'NOT_FOUND'
	| 'METHOD_NOT_ALLOWED'
	| 'TURNSTILE_FAILED'
	| 'SESSION_INVALID'
	| 'CONVERSATION_FULL'
	| 'AGENT_UNAVAILABLE'
	| 'INTEGRITY_VIOLATION'
	| 'API_ERROR';

export interface ValidationDetail {
	field: string;
	message: string;
}

/** JSON error body: `{ error: { type, message, details? }, status }`. */
export interface ErrorResponseBody {
	error: {
		type: ErrorType;
		message: string;
		details?: ValidationDetail[];
	};
	status: number;
}

// ============================================================================
// SSE Protocol (worker-owned; not Anthropic passthrough, not UI-specific)
// ============================================================================

export interface SseDeltaEvent {
	text: string;
}

/**
 * Sent once the turn is in the chain, which is what makes it the signal the
 * client waits for: transport EOF proves nothing on its own. This site's chat
 * reads only that the event arrived. The fields are the turn's receipt, carried
 * for any client that wants them and for reading a stream by hand.
 */
export interface SseDoneEvent {
	id: string;
	model: string;
	usage: {
		input_tokens: number;
		output_tokens: number;
	};
	duration_ms: number;
}

export interface SseErrorEvent {
	error: {
		type: ErrorType;
		message: string;
	};
	status: number;
}

// ============================================================================
// Turnstile
// ============================================================================

/** https://developers.cloudflare.com/turnstile/get-started/server-side-validation/ */
export interface TurnstileVerifyResponse {
	'success': boolean;
	'hostname'?: string;
	'error-codes'?: string[];
}

// ============================================================================
// Integrity Chain
// ============================================================================

/** Row subset used for continuation lookup. */
export interface ChainAnchor {
	chain_id: string;
	block_hash: string;
	block_index: number;
}

/** One logged conversation turn (see migrations/0001). */
export interface ConversationBlock {
	chain_id: string;
	block_hash: string;
	/** Genesis: null in D1; "0" * 64 inside the canonical hash input. */
	prev_hash: string | null;
	block_index: number;
	context_hash: string;
	user_message: string;
	assistant_response: string;
	locale: Locale;
	/** SHA-256(ip) — a grouping key for the dashboard. */
	ip_hash: string | null;
	model: string;
	tokens_in: number;
	tokens_out: number;
	latency_ms: number;
	/** Unix epoch milliseconds (Date.now()). */
	created_at: number;
}

