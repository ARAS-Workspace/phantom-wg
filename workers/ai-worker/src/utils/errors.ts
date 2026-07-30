import { corsHeaders } from '../cors';
import type { Env, ErrorResponseBody, ErrorType, ValidationDetail } from '../types';

/**
 * JSON error responses: `{ error: { type, message, details? }, status }`.
 *
 * This site's chat reads `error.type`, `error.message` and `error.details`: the
 * type decides whether a refusal is retryable or ends the conversation, and
 * `details` carries the per-field reason for a validation refusal, which the
 * chat shows in place of the envelope's own message whenever exactly one field
 * is named. Both are part of the contract rather than decoration. `status` is
 * carried for other clients and rendered by none.
 *
 * There is no `retryAfter`. It used to carry the seconds until the worker's own
 * daily meter rolled over, and that meter is gone — the ceiling belongs to the
 * gateway now, whose window this worker does not know. A number invented here
 * would be a guess printed with the authority of a fact.
 */

interface ErrorOptions {
	details?: ValidationDetail[];
}

/**
 * @example return errorResponse(request, env, 'NOT_FOUND', t.errors.endpointNotFound, 404);
 */
export function errorResponse(
	request: Request,
	env: Env,
	type: ErrorType,
	message: string,
	status: number,
	options: ErrorOptions = {},
): Response {
	const body: ErrorResponseBody = {
		error: {
			type,
			message,
			...(options.details ? { details: options.details } : {}),
		},
		status,
	};

	const headers: Record<string, string> = {
		'Content-Type': 'application/json; charset=utf-8',
		...corsHeaders(request, env),
	};
	return new Response(JSON.stringify(body, null, 2), { status, headers });
}
