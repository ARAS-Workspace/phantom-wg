import type { SseDeltaEvent, SseDoneEvent, SseErrorEvent } from '../types';

/**
 * Worker-owned SSE protocol helpers.
 *
 * Wire format (one event per write):
 *   event: delta|done|error
 *   data: <json>
 *   <blank line>
 */

const encoder = new TextEncoder();

type SseEventName = 'delta' | 'done' | 'error';

/**
 * @example controller.enqueue(sseEvent('delta', { text }));
 */
export function sseEvent(name: 'delta', data: SseDeltaEvent): Uint8Array;
export function sseEvent(name: 'done', data: SseDoneEvent): Uint8Array;
export function sseEvent(name: 'error', data: SseErrorEvent): Uint8Array;
export function sseEvent(name: SseEventName, data: unknown): Uint8Array {
	return encoder.encode(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`);
}

/**
 * Response headers for an SSE stream. Content-Length is intentionally
 * absent — the runtime chunks ReadableStream bodies on its own.
 * @example new Response(stream, { headers: { ...sseHeaders(), ...cors } });
 */
export function sseHeaders(): Record<string, string> {
	return {
		'Content-Type': 'text/event-stream; charset=utf-8',
		'Cache-Control': 'no-cache',
	};
}
