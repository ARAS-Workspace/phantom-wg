import Anthropic from '@anthropic-ai/sdk';

import systemPrompt from './prompts/system-prompt.md';
import { CONFIG } from '../config';
import type { ChatMessage } from '../types';

/**
 * Claude streaming call.
 *
 * `system` carries the persona/guardrails plus the freshly fetched
 * llms-full site content — never the message array, so the integrity
 * chain is unaffected by site updates mid-session.
 *
 * `cache_control` on the last system block caches both blocks together. The
 * model's floor is 4096 tokens and a prefix below it is not cached at all —
 * no error, no signal — so the margin is worth recording. Measured against the
 * gateway's billing, the prefix clears the floor by 62% in Turkish and 33% in
 * English; English is the tighter side because it packs more characters into
 * each token, so trimming its llms-full file would take it under silently.
 *
 * The window is five minutes, so turns inside one conversation read the cache
 * while the first turn of each writes it.
 *
 * No tools, no thinking; parameters are server-fixed from CONFIG.
 */

export interface StreamCallbacks {
	/** One raw text delta — forwarded verbatim; byte-identity depends on it. */
	onDelta(text: string): Promise<void> | void;
}

/**
 * Where the model is reached, and with what.
 *
 * Every field is required. The gateway is not an optional accelerator in front
 * of Anthropic — it is where the spend limit, the rate limit and the provider
 * key now live, so a worker that could fall back to calling Anthropic directly
 * would be a worker with no ceiling of any kind. Missing configuration has to
 * stop the request, not quietly bypass the thing that bounds it.
 */
export interface Upstream {
	/** Gateway provider endpoint; the SDK appends `/v1/messages`. */
	baseURL: string;
	/**
	 * Gateway access token. Without it the gateway answers 401 from its own
	 * error body and the request never reaches Anthropic at all — which reads as
	 * an Anthropic key problem and is not one.
	 */
	token: string;
	/** Which stored provider key the gateway should use. */
	keyAlias: string;
}

export interface StreamResult {
	/** Exact concatenation of every delta emitted (logged as-is). */
	text: string;
	id: string;
	model: string;
	/** Final figures, for the conversation record. Nothing is metered here. */
	usage: { input_tokens: number; output_tokens: number };
}

/**
 * @example const result = await streamChatCompletion(upstream, messages, llmsContext, callbacks, signal);
 */
export async function streamChatCompletion(
	upstream: Upstream,
	messages: ChatMessage[],
	llmsContext: string,
	callbacks: StreamCallbacks,
	signal: AbortSignal,
): Promise<StreamResult> {
	const client = new Anthropic({
		// This worker holds no Anthropic key: the gateway stores it and attaches
		// it on the way out, so sending one from here would be a second
		// credential travelling for no reason.
		//
		// A null `apiKey` is not enough on its own — the SDK treats an absent
		// credential as a mistake and refuses to build the request ("Could not
		// resolve authentication method"). Omitting the header explicitly, by
		// setting it to null, is how that intent is stated.
		apiKey: null,
		baseURL: upstream.baseURL,
		defaultHeaders: {
			'x-api-key': null,
			'cf-aig-authorization': `Bearer ${upstream.token}`,
			'cf-aig-byok-alias': upstream.keyAlias,
		},
		// No retries at all, not just none for 429. The SDK would otherwise retry
		// 429 and 5xx twice with backoff. Behind the gateway a 429 is the spend or
		// rate limit answering and will refuse the retry the same way, only later;
		// a 5xx is worth one more attempt in principle, but the visitor is holding
		// an open stream with nothing on screen, and a failure they can retry
		// themselves beats a wait they cannot see the end of.
		maxRetries: 0,
	});

	const stream = client.messages.stream(
		{
			model: CONFIG.claude.model,
			max_tokens: CONFIG.claude.maxTokens,
			system: [
				{ type: 'text', text: systemPrompt },
				{
					type: 'text',
					text: `<site_content>\n${llmsContext}\n</site_content>`,
					cache_control: { type: 'ephemeral' },
				},
			],
			messages: messages.map((message) => ({ role: message.role, content: message.content })),
		},
		{ signal },
	);

	// Only the text is followed. Usage used to be tracked event by event so a
	// turn the visitor abandoned could still be charged against a meter this
	// worker kept; the gateway keeps that meter now, and it sees every request
	// whether or not this worker waits for the answer.
	let text = '';
	for await (const event of stream) {
		if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
			text += event.delta.text;
			await callbacks.onDelta(event.delta.text);
		}
	}

	const message = await stream.finalMessage();

	// Total input actually processed: uncached + cache writes + cache reads.
	// Anthropic reports these as three separate counters, and the system blocks
	// land in `cache_creation_input_tokens` on the first request of a cache
	// window — recording only `input_tokens` would under-report the context by
	// thousands of tokens in the conversation record.
	return {
		text,
		id: message.id,
		model: message.model,
		usage: {
			input_tokens:
				message.usage.input_tokens +
				(message.usage.cache_creation_input_tokens ?? 0) +
				(message.usage.cache_read_input_tokens ?? 0),
			output_tokens: message.usage.output_tokens,
		},
	};
}
