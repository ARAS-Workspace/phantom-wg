import { CONFIG } from '../config';
import { logWarn } from '../utils/logging';
import type { Locale } from '../translations';

/**
 * llms-full context source.
 *
 * Fetched fresh per message with `cache: 'no-store'` (the site also serves
 * these files with `cache-control: no-cache`), so a deploy is reflected in
 * the very next answer — including mid-session. One retry absorbs a
 * transient failure; a hard failure surfaces to the caller rather than
 * answering from a stale snapshot. There is no bundled copy on purpose:
 * the chat page is served by the same origin, so an unreachable site means
 * the user could not be chatting in the first place.
 */

class LlmsContextError extends Error {}

/**
 * How long one attempt at the site context may take. `getLlmsContext` retries
 * once, so the ceiling a caller actually waits is twice this before the turn is
 * refused.
 */
const FETCH_TIMEOUT_MS = 5_000;

async function fetchOnce(url: string): Promise<string> {
	// Bounded on purpose: this runs before the response has started, so a fetch
	// that hangs holds the whole request open with nothing on screen. Failing
	// fast turns that into the 503 the caller already handles.
	const response = await fetch(url, { cache: 'no-store', signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
	if (!response.ok) {
		throw new LlmsContextError(`llms fetch failed: ${response.status}`);
	}
	const text = await response.text();
	if (text.trim().length === 0) {
		throw new LlmsContextError('llms fetch returned an empty body');
	}
	return text;
}

/**
 * @example const context = await getLlmsContext(locale);
 */
export async function getLlmsContext(locale: Locale): Promise<string> {
	const url = CONFIG.llms.urls[locale];

	try {
		return await fetchOnce(url);
	} catch (error) {
		logWarn('llms_fetch_retry', { locale, message: error instanceof Error ? error.message : String(error) });
		return fetchOnce(url);
	}
}
