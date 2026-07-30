/**
 * Phantom-WG AI Worker — Claude-backed site agent (ai-worker.phantom.tc)
 *
 * Chat pipeline (order is load-bearing):
 *   CORS/preflight → path/method → session HMAC verify (401) → declared-length
 *   fast path + size-bounded body read (409 when the conversation is full) →
 *   validation (400) → integrity verify (409) → gateway configuration (503 when
 *   it is missing) → llms-full fetch (503 when the site context cannot be read)
 *   → Claude stream → SSE out → D1 insert AWAITED before `done`.
 *
 * The session check comes before the size checks on purpose: a caller with no
 * session is told that, rather than being told the conversation it never
 * started is full — and its body is never read either way.
 *
 * Nothing here meters spend. The model is reached only through AI Gateway,
 * which holds the budget, the rate limit and the key that pays for the call, so
 * the ceiling is enforced where the cost is actually known. When the gateway
 * refuses, it does so with a 429 that arrives mid-stream — after the SSE
 * response has already been opened — so it is reported as an `error` event
 * carrying `AGENT_UNAVAILABLE` rather than as a status.
 */

import { streamChatCompletion } from './claude/manager';
import type { Upstream } from './claude/manager';
import { CONFIG } from './config';
import { corsHeaders, preflightResponse } from './cors';
import {
	hashBlock,
	hashContext as hashContextOf,
	hashIp,
	logConversationBlock,
	verifyHistory,
} from './integrity/chain';
import { getLlmsContext } from './llms/context';
import { issueSessionToken, verifySessionToken } from './session/token';
import { validateChatRequest } from './validation/request';
import { verifyTurnstileToken } from './session/turnstile';
import { getTranslations, parseLocale } from './translations';
import { readJsonBody } from './utils/body';
import { errorResponse } from './utils/errors';
import { logError, logInfo, logWarn } from './utils/logging';
import { sseEvent, sseHeaders } from './utils/sse';
import type { ConversationBlock, Env, SessionResponse } from './types';

export default {
	async fetch(request, env): Promise<Response> {
		try {
			if (request.method === 'OPTIONS') {
				return preflightResponse(request, env);
			}

			const t = getTranslations(CONFIG.localization.defaultLocale);
			const { pathname } = new URL(request.url);
			const isSession = pathname === CONFIG.endpoints.session;
			const isChat = pathname === CONFIG.endpoints.chat;

			if (!isSession && !isChat) {
				return errorResponse(request, env, 'NOT_FOUND', t.errors.endpointNotFound, 404);
			}
			if (request.method !== 'POST') {
				return errorResponse(request, env, 'METHOD_NOT_ALLOWED', t.errors.methodNotAllowed, 405);
			}

			// Awaited, not just returned: `return promise` leaves the try block
			// before the promise settles, so every rejection from the handlers
			// would bypass the catch below — and with it the localized envelope,
			// the CORS headers that envelope carries, and the error log.
			if (isSession) {
				return await handleSession(request, env);
			}
			return await handleChat(request, env);
		} catch (error) {
			logError('unhandled_error', error);
			const t = getTranslations(CONFIG.localization.defaultLocale);
			return errorResponse(request, env, 'API_ERROR', t.errors.apiError, 500);
		}
	},
} satisfies ExportedHandler<Env>;

/** Client IP for the `conversation_logs.ip_hash` column and Turnstile remoteip. */
function getClientIp(request: Request): string {
	return request.headers.get('CF-Connecting-IP') ?? 'unknown';
}

/**
 * Whether the client declared a body larger than the cap.
 *
 * A fast path only. `Content-Length` is a client-supplied hint and is simply
 * absent on a chunked upload, so nothing is trusted to it — the cap that
 * actually holds is applied while the body is read, in `readJsonBody`. What
 * this buys is refusing an oversized request without reading it.
 *
 * It runs inside each handler rather than in front of both, so that a refusal
 * the caller has not earned the right to hear comes second: an unauthenticated
 * request to the chat endpoint is answered 401 without its body being read at
 * all, instead of being told the conversation it never started is full.
 */
function declaresOversizedBody(request: Request): boolean {
	const declared = Number.parseInt(request.headers.get('Content-Length') ?? '', 10);
	return Number.isFinite(declared) && declared > CONFIG.validation.maxRequestBodySize;
}

/**
 * The gateway configuration, or null when it is incomplete.
 *
 * Null is a refusal rather than a fallback. Every ceiling this agent has —
 * the spend limit, the rate limit, the key that pays — lives in the gateway, so
 * a worker that quietly called Anthropic directly would be a worker that had
 * lost all of them at once, and it would look like it was working.
 */
function readUpstream(env: Env): Upstream | null {
	const baseURL = env.ANTHROPIC_BASE_URL ?? '';
	const token = env.CF_AIG_TOKEN ?? '';
	if (baseURL === '' || token === '') {
		return null;
	}
	// An empty alias is treated as unset, like the two fields above: a var that
	// is present but blank is a configuration mistake, and forwarding it would
	// ask the gateway for a stored key named "".
	const alias = env.CF_AIG_KEY_ALIAS ?? '';
	return { baseURL, token, keyAlias: alias === '' ? 'default' : alias };
}

/**
 * Whether a thrown upstream error is the gateway turning the request away for a
 * reason that retrying will not change.
 *
 * 429 is a limit: the spend budget for the window is used up, or the request
 * rate is. Which of the two cannot be told apart here, and it does not need to
 * be — both mean the agent cannot answer now, and reporting them the same way
 * is what keeps the client from promising a retry time this worker cannot know.
 *
 * 401 and 403 are the credential: a wrong or revoked CF_AIG_TOKEN, or a stored
 * provider key the gateway will not use. They are operator errors and belong
 * with the missing-configuration refusal rather than with transient faults — a
 * visitor retrying a misconfigured deployment only meets the same wall, and the
 * composer should close instead of inviting that.
 */
function isUpstreamRefusal(error: unknown): boolean {
	if (typeof error !== 'object' || error === null) {
		return false;
	}
	const { status } = error as { status?: unknown };
	return status === 429 || status === 401 || status === 403;
}

/**
 * POST /api/v1/session — Turnstile siteverify → signed session token.
 * Order: parse → token presence → siteverify → issue. Nothing throttles
 * siteverify; Turnstile itself is the gate. `locale` in the body is
 * optional and only localizes errors.
 */
async function handleSession(request: Request, env: Env): Promise<Response> {
	if (declaresOversizedBody(request)) {
		const t = getTranslations(CONFIG.localization.defaultLocale);
		return errorResponse(request, env, 'PAYLOAD_TOO_LARGE', t.errors.payloadTooLarge, 413);
	}

	const read = await readJsonBody(request, CONFIG.validation.maxRequestBodySize);
	if (!read.ok) {
		const t = getTranslations(CONFIG.localization.defaultLocale);
		return read.reason === 'too-large'
			? errorResponse(request, env, 'PAYLOAD_TOO_LARGE', t.errors.payloadTooLarge, 413)
			: errorResponse(request, env, 'VALIDATION_ERROR', t.errors.invalidJson, 400);
	}

	const body = (read.value ?? {}) as Record<string, unknown>;
	const locale = parseLocale(body.locale);
	const t = getTranslations(locale);

	const turnstileToken = body.turnstileToken;
	if (typeof turnstileToken !== 'string' || turnstileToken.length === 0) {
		return errorResponse(request, env, 'VALIDATION_ERROR', t.errors.turnstileTokenMissing, 400);
	}

	const verdict = await verifyTurnstileToken(env, turnstileToken, getClientIp(request));
	if (!verdict.ok) {
		logWarn('session_turnstile_rejected', { errorCodes: verdict.errorCodes });
		return errorResponse(request, env, 'TURNSTILE_FAILED', t.errors.turnstileFailed, 403);
	}

	const { token, payload } = await issueSessionToken(env.SESSION_SIGNING_KEY);
	logInfo('session_issued', { sid: payload.sid, exp: payload.exp });

	const responseBody: SessionResponse = { token, expiresAt: payload.exp * 1000 };
	return new Response(JSON.stringify(responseBody, null, 2), {
		status: 200,
		headers: { 'Content-Type': 'application/json; charset=utf-8', ...corsHeaders(request, env) },
	});
}

/**
 * POST /api/v1/chat — session-gated, integrity-chained, SSE-streamed chat.
 * Pre-parse gates run with the default locale (the body is unread yet).
 */
async function handleChat(request: Request, env: Env): Promise<Response> {
	// The locale twice over, and both are needed. The body carries it, but the
	// refusals below happen before the body is read — a conversation that has
	// run its length is turned away without being parsed — so a copy rides on
	// the query string where it can be read first. Without it every visitor who
	// simply reached the end of a conversation, which is a routine event rather
	// than an error, would be told so in the default language.
	const t = getTranslations(parseLocale(new URL(request.url).searchParams.get('locale')));

	// 1. Session (cheap HMAC — before anything stateful; 401 → client re-solves Turnstile)
	const authorization = request.headers.get('Authorization') ?? '';
	const bearer = authorization.startsWith('Bearer ') ? authorization.slice(7) : '';
	const session = bearer === '' ? null : await verifySessionToken(bearer, env.SESSION_SIGNING_KEY);
	if (session === null) {
		return errorResponse(request, env, 'SESSION_INVALID', t.errors.sessionInvalid, 401);
	}

	// 2. Body + validation. An oversized body here is the conversation reaching
	// its length — a hard stop, on purpose: this conversation is over and the
	// visitor starts a new one. Rolling silently into a fresh chain would hide
	// that the agent no longer remembers what came before. The declared length
	// is checked first so an over-cap conversation is refused without being
	// read; a client that declares nothing is caught by the reader instead.
	if (declaresOversizedBody(request)) {
		return errorResponse(request, env, 'CONVERSATION_FULL', t.errors.conversationFull, 409);
	}

	const read = await readJsonBody(request, CONFIG.validation.maxRequestBodySize);
	if (!read.ok) {
		return read.reason === 'too-large'
			? errorResponse(request, env, 'CONVERSATION_FULL', t.errors.conversationFull, 409)
			: errorResponse(request, env, 'VALIDATION_ERROR', t.errors.invalidJson, 400);
	}

	const validation = validateChatRequest(read.value);
	const tl = getTranslations(validation.locale);
	if (!validation.valid) {
		return errorResponse(request, env, 'VALIDATION_ERROR', tl.errors.validationFailed, 400, {
			details: validation.details,
		});
	}

	// 3. Integrity — the client-sent history must anchor in D1
	const integrity = await verifyHistory(env, validation.request.messages);
	if (integrity.kind === 'violation') {
		logWarn('integrity_violation', { sid: session.sid });
		return errorResponse(request, env, 'INTEGRITY_VIOLATION', tl.errors.integrityViolation, 409);
	}

	// 4. Upstream configuration. The gateway holds the spend limit, the rate
	// limit and the provider key, so a worker that cannot reach it has no
	// ceiling to fall back on — better to refuse the turn than to answer it
	// unbounded. Misconfiguration is an operator error, so it reads as the
	// agent being unavailable rather than as anything the visitor did.
	//
	// This is a free environment read and could sit ahead of the body read and
	// the integrity SELECT, which would spare a broken deployment that work. It
	// stays here because the refusal is shown to a visitor and the locale it is
	// written in comes from the body: moving it earlier would answer every
	// English visitor in Turkish. A deployment missing its gateway configuration
	// is already broken and rare; the wasted SELECT is cheaper than the wrong
	// language.
	const upstream = readUpstream(env);
	if (upstream === null) {
		logError('gateway_not_configured', new Error('ANTHROPIC_BASE_URL or CF_AIG_TOKEN is missing'));
		return errorResponse(request, env, 'AGENT_UNAVAILABLE', tl.errors.agentUnavailable, 503);
	}

	// 5. Fresh site context (fetched per message, outside the chain)
	let llmsContext: string;
	try {
		llmsContext = await getLlmsContext(validation.locale);
	} catch (error) {
		logError('llms_context_unavailable', error, { locale: validation.locale });
		return errorResponse(request, env, 'API_ERROR', tl.errors.apiError, 503);
	}

	// 6. Claude stream → SSE. The D1 block is written and AWAITED before
	// the `done` event so the next message can anchor immediately.
	const messages = validation.request.messages;
	const startedAt = Date.now();
	// Client disconnect arrives as a `cancel()` on the response stream —
	// `request.signal` is not a reliable disconnect signal in Workers. On
	// disconnect the upstream call is aborted and the turn is dropped: an
	// unanswered turn must never enter the chain. Its cost is not lost with it,
	// because the gateway records what it forwarded whether or not this worker
	// stays to hear the answer.
	const upstreamAbort = new AbortController();
	let clientGone = false;
	let controller: ReadableStreamDefaultController<Uint8Array>;

	const write = async (chunk: Uint8Array): Promise<void> => {
		if (clientGone) {
			return;
		}
		try {
			controller.enqueue(chunk);
		} catch {
			clientGone = true;
			upstreamAbort.abort();
		}
	};

	const pump = async (): Promise<void> => {
		let streamedText = '';
		try {
			const result = await streamChatCompletion(
				upstream,
				messages,
				llmsContext,
				{
					onDelta: async (text) => {
						streamedText += text;
						await write(sseEvent('delta', { text }));
					},
				},
				upstreamAbort.signal,
			);

			if (clientGone) {
				// The turn is dropped, because an unanswered turn must never enter
				// the chain. Its cost is the gateway's to record, not ours.
				logInfo('chat_aborted', { sid: session.sid, streamed: streamedText.length });
				return;
			}

			// An empty answer is an unanswered turn, and an unanswered turn must
			// never enter the chain — the same rule the abort above follows.
			// Substituting a fixed apology would write a sentence the model
			// never produced into a tamper-evident record, and since that
			// sentence is a constant, two visitors opening with the same
			// question would hash to the same context and the second would
			// collide on the UNIQUE index.
			const assistantResponse = result.text;
			if (assistantResponse.length === 0) {
				logWarn('chat_empty_response', { sid: session.sid, model: result.model });
				await write(
					sseEvent('error', { error: { type: 'API_ERROR', message: tl.errors.emptyResponse }, status: 502 }),
				);
				return;
			}

			const prevHash = integrity.kind === 'continuation' ? integrity.anchor.block_hash : null;
			const blockIndex = integrity.kind === 'continuation' ? integrity.anchor.block_index + 1 : 0;
			const chainId = integrity.kind === 'continuation' ? integrity.anchor.chain_id : integrity.chainId;
			const fullContext = [...messages, { role: 'assistant' as const, content: assistantResponse }];

			const block: ConversationBlock = {
				chain_id: chainId,
				block_hash: await hashBlock({
					chainId,
					blockIndex,
					prevHash,
					userMessage: messages[messages.length - 1].content,
					assistantResponse,
				}),
				prev_hash: prevHash,
				block_index: blockIndex,
				context_hash: await hashContextOf(fullContext),
				user_message: messages[messages.length - 1].content,
				assistant_response: assistantResponse,
				locale: validation.locale,
				ip_hash: await hashIp(getClientIp(request)),
				model: result.model,
				tokens_in: result.usage.input_tokens,
				tokens_out: result.usage.output_tokens,
				latency_ms: Date.now() - startedAt,
				created_at: Date.now(),
			};

			await logConversationBlock(env, block);

			await write(
				sseEvent('done', {
					id: result.id,
					model: result.model,
					usage: result.usage,
					duration_ms: Date.now() - startedAt,
				}),
			);
			logInfo('chat_completed', {
				sid: session.sid,
				chain: chainId.slice(0, 12),
				block: blockIndex,
				tokens: result.usage.input_tokens + result.usage.output_tokens,
			});
		} catch (error) {
			// Aborted by the client: leave the chain untouched.
			if (clientGone) {
				logInfo('chat_aborted', { sid: session.sid, streamed: streamedText.length });
			} else if (isUpstreamRefusal(error)) {
				// The gateway's ceiling, reported mid-stream because that is when
				// it arrives: the response has already been opened as SSE by the
				// time the upstream call is made, so there is no status left to
				// send. The client tells these apart by `error.type`, and this one
				// closes the composer instead of inviting a retry that would be
				// refused the same way.
				// The error travels with it: this mapping keys on a status the SDK is
				// trusted to surface, and if a future version wraps it differently
				// the log is what shows the refusal arriving as something else.
				logWarn('upstream_refused', {
					sid: session.sid,
					status: (error as { status?: unknown }).status,
					message: error instanceof Error ? error.message : String(error),
				});
				await write(
					sseEvent('error', {
						error: { type: 'AGENT_UNAVAILABLE', message: tl.errors.agentUnavailable },
						status: 503,
					}),
				);
			} else {
				logError('chat_failed', error, { sid: session.sid });
				await write(sseEvent('error', { error: { type: 'API_ERROR', message: tl.errors.apiError }, status: 500 }));
			}
		} finally {
			try {
				controller.close();
			} catch {
				// Already closed by the client's disconnect.
			}
		}
	};

	const stream = new ReadableStream<Uint8Array>({
		start(streamController) {
			controller = streamController;
			// Tied to the stream's lifetime, not the request's: if the client
			// disconnects, `cancel` below stops the work.
			void pump();
		},
		cancel() {
			clientGone = true;
			upstreamAbort.abort();
			// Nothing else to settle here. This worker keeps no running total to
			// flush, and the handler takes no ExecutionContext, so anything left
			// in flight would be dropped anyway — what the turn cost is recorded
			// by the gateway, which saw the request regardless.
		},
	});

	return new Response(stream, {
		status: 200,
		headers: { ...sseHeaders(), ...corsHeaders(request, env) },
	});
}
