/**
 * Structured console logging — picked up by Workers observability.
 * Never log message contents or raw IPs here. Aggregate token counts are
 * logged — see the `chat_completed` event.
 */

export function logInfo(event: string, data: Record<string, unknown> = {}): void {
	console.log(JSON.stringify({ level: 'info', event, ...data }));
}

export function logWarn(event: string, data: Record<string, unknown> = {}): void {
	console.warn(JSON.stringify({ level: 'warn', event, ...data }));
}

export function logError(event: string, error: unknown, data: Record<string, unknown> = {}): void {
	const message = error instanceof Error ? error.message : String(error);
	console.error(JSON.stringify({ level: 'error', event, message, ...data }));
}
