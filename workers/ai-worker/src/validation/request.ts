import { CONFIG } from '../config';
import { getTranslations, parseLocale } from '../translations';
import type { ChatMessage, ChatRequest, ValidationDetail } from '../types';
import type { Locale } from '../translations';

const encoder = new TextEncoder();

/**
 * Chat body validation. Unknown/legacy fields (stream, max_tokens,
 * temperature, turnstileToken) are IGNORED, never rejected — the old
 * frontend keeps working. An invalid `locale` silently falls back to the
 * default. The first and last message must both be user turns — enforced
 * here, because the integrity chain downstream assumes it: it hashes
 * everything before the trailing user message as the prior context. Detail
 * messages are localized and returned in `details`, which is what the site
 * shows the visitor when a refusal names exactly one field — the envelope's
 * own message only points at the list.
 */

export type ValidationResult =
	| { valid: true; request: ChatRequest; locale: Locale }
	| { valid: false; details: ValidationDetail[]; locale: Locale };

/**
 * @example const result = validateChatRequest(rawBody);
 */
export function validateChatRequest(rawBody: unknown): ValidationResult {
	const body = (typeof rawBody === 'object' && rawBody !== null ? rawBody : {}) as Record<string, unknown>;
	const locale = parseLocale(body.locale);
	const t = getTranslations(locale);
	const details: ValidationDetail[] = [];

	const rawMessages = body.messages;
	if (!Array.isArray(rawMessages)) {
		return { valid: false, details: [{ field: 'messages', message: t.errors.invalidMessages }], locale };
	}
	if (rawMessages.length === 0) {
		return { valid: false, details: [{ field: 'messages', message: t.errors.emptyMessages }], locale };
	}
	// Nothing caps the message count here. The conversation's length is decided
	// by its size, upstream in `readJsonBody` — the client replays the whole
	// conversation on every turn, so the body is the conversation, and counting
	// it twice in two units only made the two caps drift apart.

	const messages: ChatMessage[] = [];
	for (let i = 0; i < rawMessages.length; i++) {
		const item = (typeof rawMessages[i] === 'object' && rawMessages[i] !== null ? rawMessages[i] : {}) as Record<
			string,
			unknown
		>;

		const role = item.role;
		if (role !== 'user' && role !== 'assistant') {
			details.push({ field: `messages[${i}].role`, message: t.errors.invalidRole });
			continue;
		}

		const content = item.content;
		if (typeof content !== 'string') {
			details.push({ field: `messages[${i}].content`, message: t.errors.invalidMessages });
			continue;
		}
		if (content.length === 0) {
			details.push({ field: `messages[${i}].content`, message: t.errors.messageEmpty });
			continue;
		}
		// Visitor messages only. The cap exists to bound what a visitor can send,
		// and an assistant message is not that: it is this worker's own output,
		// replayed back, already bounded at generation by `claude.maxTokens`.
		//
		// Applying it to both was a real defect rather than a redundancy. The
		// two ceilings are in different units and the conversion is per-language:
		// measured here, 1024 output tokens is ~2.8 KB of Turkish but 4,999 bytes
		// of English, so an ordinary English answer came back 903 bytes over this
		// cap and the next request was refused for a message the visitor never
		// wrote — with no way to continue, since a validation refusal is not one
		// of the states that ends a conversation cleanly.
		//
		// Bytes rather than characters so the figure is in the same unit as the
		// body cap that ends the conversation. What bounds an assistant message
		// is `claude.maxTokens`; what bounds the conversation is
		// `maxRequestBodySize`; this bounds one visitor message. Three ceilings,
		// three jobs.
		if (role === 'user' && encoder.encode(content).length > CONFIG.validation.maxMessageLength) {
			details.push({ field: `messages[${i}].content`, message: t.errors.messageTooLong });
			continue;
		}

		messages.push({ role, content });
	}

	if (details.length > 0) {
		return { valid: false, details, locale };
	}

	if (messages[0].role !== 'user') {
		details.push({ field: 'messages[0].role', message: t.errors.firstMessageNotUser });
	}
	if (messages[messages.length - 1].role !== 'user') {
		details.push({ field: `messages[${messages.length - 1}].role`, message: t.errors.lastMessageNotUser });
	}
	if (details.length > 0) {
		return { valid: false, details, locale };
	}

	return { valid: true, request: { messages }, locale };
}
