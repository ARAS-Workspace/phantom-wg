import { canonicalizeMessages, normalizeMessages, normalizeText } from './normalize';
import type { ChainAnchor, ChatMessage, ConversationBlock, Env } from '../types';

/**
 * SHA-256 hash chain over conversation turns (WebCrypto; replaces the
 * reference implementation's keccak256/EIP-712 encoder with the same
 * guarantee — a tampered or fabricated client history cannot anchor).
 *
 * Rules:
 *  - Genesis = exactly 1 message → fresh chain_id (32 random bytes hex).
 *  - Continuation → drop the trailing user message, hash the prior
 *    context, look up D1 `context_hash` (UNIQUE); missing ⇒ violation.
 *  - Genesis prev_hash: ZERO_HASH inside the hash input, NULL in D1.
 *  - created_at: Date.now() (epoch milliseconds).
 */

const ZERO_HASH = '0'.repeat(64);
const encoder = new TextEncoder();

async function sha256Hex(input: string): Promise<string> {
	const digest = await crypto.subtle.digest('SHA-256', encoder.encode(input));
	return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

/**
 * Hash of a full conversation context (the continuation lookup key).
 * @example const contextHash = await hashContext(priorMessages);
 */
export async function hashContext(messages: ChatMessage[]): Promise<string> {
	return sha256Hex(canonicalizeMessages(normalizeMessages(messages)));
}

/**
 * Hash of one block. Explicit field order: chain_id, block_index, prev_hash,
 * user_message, assistant_response. The two text fields are normalized (NFC,
 * LF) before hashing while D1 stores them verbatim, so re-deriving a block hash
 * from a stored row means normalizing it again first.
 * @example const blockHash = await hashBlock({ chainId, blockIndex, prevHash, userMessage, assistantResponse });
 */
export async function hashBlock(input: {
	chainId: string;
	blockIndex: number;
	prevHash: string | null;
	userMessage: string;
	assistantResponse: string;
}): Promise<string> {
	const payload = JSON.stringify({
		chain_id: input.chainId,
		block_index: input.blockIndex,
		prev_hash: input.prevHash ?? ZERO_HASH,
		user_message: normalizeText(input.userMessage),
		assistant_response: normalizeText(input.assistantResponse),
	});
	return sha256Hex(payload);
}

type IntegrityCheck =
	| { kind: 'genesis'; chainId: string }
	| { kind: 'continuation'; anchor: ChainAnchor }
	| { kind: 'violation' };

/**
 * Classify and verify the client-sent history against D1. The caller has
 * already validated that the last message is a user turn.
 * @example const check = await verifyHistory(env, request.messages);
 */
export async function verifyHistory(env: Env, messages: ChatMessage[]): Promise<IntegrityCheck> {
	// Genesis — a single user message anchors a brand new chain.
	if (messages.length === 1) {
		const chainId = [...crypto.getRandomValues(new Uint8Array(32))]
			.map((byte) => byte.toString(16).padStart(2, '0'))
			.join('');
		return { kind: 'genesis', chainId };
	}

	// Continuation — the prior context (everything before the new user
	// message) must already be anchored in D1.
	const priorMessages = messages.slice(0, -1);
	const priorContextHash = await hashContext(priorMessages);

	const anchor = await env.AI_LOGS_DB.prepare(
		'SELECT chain_id, block_hash, block_index FROM conversation_logs WHERE context_hash = ?',
	)
		.bind(priorContextHash)
		.first<ChainAnchor>();

	if (anchor === null) {
		return { kind: 'violation' };
	}

	return { kind: 'continuation', anchor };
}

/**
 * INSERT the new block. The caller AWAITS this before emitting the SSE
 * `done` event, so the next request can anchor immediately.
 * @example await logConversationBlock(env, block);
 */
export async function logConversationBlock(env: Env, block: ConversationBlock): Promise<void> {
	await env.AI_LOGS_DB.prepare(
		`INSERT INTO conversation_logs (
			chain_id, block_hash, prev_hash, block_index, context_hash,
			user_message, assistant_response, locale, ip_hash, model,
			tokens_in, tokens_out, latency_ms, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)
		.bind(
			block.chain_id,
			block.block_hash,
			block.prev_hash,
			block.block_index,
			block.context_hash,
			block.user_message,
			block.assistant_response,
			block.locale,
			block.ip_hash,
			block.model,
			block.tokens_in,
			block.tokens_out,
			block.latency_ms,
			block.created_at,
		)
		.run();
}


/**
 * SHA-256 of the client IP — a grouping key for the dashboard
 *
 * @example const ipHash = await hashIp(clientIp);
 */
export async function hashIp(ip: string): Promise<string> {
	return sha256Hex(ip);
}

