/**
 * Size-bounded JSON body reader.
 *
 * `request.json()` buffers whatever arrives before it parses, so the size of a
 * request body has to be enforced while it is being read rather than trusted
 * from a header. `Content-Length` is client-supplied and simply absent on a
 * chunked upload, which left the declared-length check with nothing to compare
 * and every unmeasured body going straight into the parser. The per-message cap
 * does not cover this: it runs on the object the parser has already produced, so
 * it bounds what is accepted, never what is buffered — and on the session
 * endpoint it does not run at all.
 *
 * Reading through the stream and stopping at the cap makes the bound hold
 * whether or not the length was declared.
 */

const decoder = new TextDecoder();

export type BodyResult =
	| { ok: true; value: unknown }
	/**
	 * Over the cap. The buffered bytes are released but the stream is still read
	 * to its end — see the note in the loop for why abandoning it is not an
	 * option. The status is the caller's to choose: 413 on the session path,
	 * 409 CONVERSATION_FULL on the chat path, where the body IS the conversation.
	 */
	| { ok: false; reason: 'too-large' }
	/** Absent, truncated, or not JSON — all indistinguishable to the caller. */
	| { ok: false; reason: 'invalid-json' };

/**
 * @example const body = await readJsonBody(request, CONFIG.validation.maxRequestBodySize);
 */
export async function readJsonBody(request: Request, maxBytes: number): Promise<BodyResult> {
	if (request.body === null) {
		return { ok: false, reason: 'invalid-json' };
	}

	const reader = request.body.getReader();
	let chunks: Uint8Array[] = [];
	let total = 0;
	let overCap = false;

	try {
		for (;;) {
			const { done, value } = await reader.read();
			if (done) {
				break;
			}
			total += value.byteLength;
			if (!overCap && total > maxBytes) {
				// Past the cap. What is protected here is memory, so the bytes
				// already held are released and nothing further is kept — but the
				// stream is still read to its end.
				//
				// Abandoning it instead is what the obvious implementation does
				// and it does not work: cancelling or simply walking away from a
				// request body the client is still uploading leaves the runtime
				// unable to serve anything afterwards, so one oversized request
				// takes the worker down for every request behind it. Measured
				// against `wrangler dev`: a 400 KB chunked body answered early
				// returns its 413, and every request after it returns 500.
				//
				// Draining costs bandwidth on a request that was going to be
				// refused anyway. Well-behaved clients never pay it: a declared
				// over-cap length is rejected before the body is touched at all.
				overCap = true;
				chunks = [];
				continue;
			}
			if (!overCap) {
				chunks.push(value);
			}
		}
	} catch {
		// A connection that dies mid-upload leaves a partial body, which is not a
		// body at all as far as the caller is concerned — unless the cap had
		// already been passed, in which case the answer was decided before the
		// stream failed and the failure does not un-decide it.
		return { ok: false, reason: overCap ? 'too-large' : 'invalid-json' };
	}

	if (overCap) {
		return { ok: false, reason: 'too-large' };
	}

	const merged = new Uint8Array(total);
	let offset = 0;
	for (const chunk of chunks) {
		merged.set(chunk, offset);
		offset += chunk.byteLength;
	}

	try {
		return { ok: true, value: JSON.parse(decoder.decode(merged)) };
	} catch {
		return { ok: false, reason: 'invalid-json' };
	}
}
