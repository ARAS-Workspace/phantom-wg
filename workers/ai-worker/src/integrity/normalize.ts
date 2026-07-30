import type { ChatMessage } from '../types';

/**
 * Deterministic normalization before hashing: NFC unicode form and LF line
 * endings, so the same logical text always hashes identically regardless
 * of platform quirks.
 *
 * NO trimming, NO fallback substitution: the byte-identity invariant
 * requires the logged assistant_response to be the exact concatenation of
 * the streamed deltas. Whitespace differences are real differences.
 */

/**
 * @example const clean = normalizeText(message.content);
 */
export function normalizeText(text: string): string {
	return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').normalize('NFC');
}

/**
 * Normalize a message list to the canonical {role, content} shape.
 * @example const canonical = normalizeMessages(request.messages);
 */
export function normalizeMessages(messages: ChatMessage[]): ChatMessage[] {
	return messages.map((message) => ({ role: message.role, content: normalizeText(message.content) }));
}

/**
 * Canonical serialization with EXPLICIT field order — never rely on
 * dynamic object key order. Arrays of messages serialize as a JSON array
 * of two-field objects, always role before content.
 * @example const payload = canonicalizeMessages(normalizeMessages(messages));
 */
export function canonicalizeMessages(messages: ChatMessage[]): string {
	return JSON.stringify(messages.map((message) => ({ role: message.role, content: message.content })));
}
