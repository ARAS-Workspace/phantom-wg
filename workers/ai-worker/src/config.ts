/**
 * Phantom-WG AI Worker Configuration
 */

export const CONFIG = {
	/**
	 * Anthropic Claude AI Settings
	 */
	claude: {
		/**
		 * Claude model to use
		 * @example model: CONFIG.claude.model
		 */
		model: 'claude-haiku-4-5',

		/**
		 * Maximum tokens per completion (server-fixed; not client-controllable).
		 *
		 * This is the only thing bounding an assistant message, and it trades
		 * directly against conversation length: the answer is replayed on every
		 * later turn, so it is the growth rate of the body that
		 * `maxRequestBodySize` ends the conversation on. Measured here, a token of
		 * answer runs about 5 bytes in English and 2.8 in Turkish, which puts this
		 * value at roughly 10 KB an answer and a 256 KB conversation at around 18
		 * exchanges.
		 *
		 * Reaching it truncates the answer with nothing said, so it wants to sit
		 * above what the agent actually needs: real answers have measured 450
		 * tokens, and only a request for maximum detail approached 1024.
		 * @example max_tokens: CONFIG.claude.maxTokens
		 */
		maxTokens: 2048,
	},

	/**
	 * API Endpoints
	 */
	endpoints: {
		/**
		 * Turnstile verification → signed session token
		 * @example if (url.pathname === CONFIG.endpoints.session)
		 */
		session: '/api/v1/session',

		/**
		 * Chat completion (SSE streaming)
		 * @example if (url.pathname === CONFIG.endpoints.chat)
		 */
		chat: '/api/v1/chat',
	},

	/**
	 * CORS — origin allowlist (never wildcard)
	 */
	cors: {
		/**
		 * Origins allowed in every environment
		 * @example if (CONFIG.cors.allowedOrigins.includes(origin))
		 */
		allowedOrigins: ['https://www.phantom.tc', 'https://phantom.tc'],

		/**
		 * Extra origins allowed only when ENVIRONMENT === 'development'
		 * @example [...CONFIG.cors.allowedOrigins, ...CONFIG.cors.devOrigins]
		 */
		devOrigins: ['https://localhost:5175', 'https://localhost:5173', 'http://localhost:5173', 'http://localhost:8792'],

		/**
		 * Preflight cache lifetime in seconds
		 * @example 'Access-Control-Max-Age': String(CONFIG.cors.maxAgeSeconds)
		 */
		maxAgeSeconds: 86400,
	},

	/**
	 * Request Validation Limits
	 */
	validation: {
		/**
		 * Longest a single VISITOR message may be, in bytes.
		 *
		 * Assistant messages are exempt: they are this worker's own output
		 * replayed back, already bounded at generation by `claude.maxTokens`.
		 * Applying this cap to them made an ordinary English answer refuse the
		 * following request, over a message the visitor never wrote.
		 *
		 * Bytes rather than characters so it can be reasoned about against the
		 * body cap, which is also bytes and is what ends a conversation. Counting
		 * characters here instead would put the two caps in different units, so
		 * the relationship between one message and the conversation it belongs to
		 * would hold for Latin text and drift for everything else. See
		 * `maxRequestBodySize`.
		 *
		 * @example if (role === 'user' && encoder.encode(content).length > CONFIG.validation.maxMessageLength)
		 */
		maxMessageLength: 4096,

		/**
		 * Largest conversation accepted, in bytes — and therefore how long a
		 * conversation may get.
		 *
		 * This is the only length rule. A separate message count used to sit in
		 * front of it, but the two measured the same thing twice: the client
		 * replays the whole conversation on every turn, so the body IS the
		 * conversation, and one cap decides both questions. Reaching it ends that
		 * conversation and the visitor starts a new one; nothing rolls over
		 * silently, because an agent that quietly forgot the first half of a
		 * conversation would be worse than one that says so.
		 *
		 * A full-length exchange is one 4 KB question plus one answer at
		 * `claude.maxTokens` — 10.3 KB in English as measured, about 5.7 KB in
		 * Turkish — so 256 KB is on the order of 18 exchanges in English and 27 in
		 * Turkish, and far more ordinary ones. Raising `maxTokens` shortens
		 * conversations here; the two move together. The figure is in bytes, like `maxMessageLength`, so
		 * the two can be reasoned about together; it holds for a UTF-8 body,
		 * which is what `JSON.stringify` produces, while a client that escapes
		 * every non-ASCII character triples its own payload and meets this cap
		 * sooner.
		 *
		 * @example if (read.reason === 'too-large') // the conversation is full
		 */
		maxRequestBodySize: 262144,
	},

	/**
	 * Session (Turnstile verify-once → signed token)
	 */
	session: {
		/**
		 * Session token lifetime in seconds
		 * @example exp: now + CONFIG.session.ttlSeconds
		 */
		ttlSeconds: 3600,

		/**
		 * Hostnames accepted from the Turnstile siteverify response. Local
		 * development is covered by its own short-circuit, so this list is
		 * production-only on purpose. The apex is listed alongside www because
		 * the site answers on both: a challenge solved on the apex page reports
		 * `phantom.tc`, and rejecting it would fail exactly the visitors CORS
		 * just admitted.
		 * @example if (!CONFIG.session.expectedHostnames.includes(data.hostname))
		 */
		expectedHostnames: ['www.phantom.tc', 'phantom.tc'],
	},

	/**
	 * llms-full Context Injection
	 *
	 * Fetched fresh on every message (no caching layer), so a site deploy
	 * reaches the agent immediately — mid-session too. The context lives in
	 * the Claude `system` blocks, never in the message array, so it is
	 * outside the integrity chain and invisible to the client.
	 */
	llms: {
		/**
		 * Per-locale source URLs
		 * @example CONFIG.llms.urls[locale]
		 */
		urls: {
			tr: 'https://www.phantom.tc/llms-full/tr.txt',
			en: 'https://www.phantom.tc/llms-full/en.txt',
		},
	},

	/**
	 * Localization Settings
	 */
	localization: {
		/**
		 * Default locale for error messages and responses
		 * @example const locale = parseLocale(body.locale); // falls back to this
		 */
		defaultLocale: 'en' as 'tr' | 'en',

		/**
		 * Supported locales
		 * @example if (!CONFIG.localization.supportedLocales.includes(locale))
		 */
		supportedLocales: ['tr', 'en'] as const,
	},
} as const;
