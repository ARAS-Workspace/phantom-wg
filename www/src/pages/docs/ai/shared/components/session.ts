/**
 * The worker session, held for as long as the page is open.
 *
 * It lives in module scope rather than component state for two reasons. The
 * chat is mounted from an MDX body that is swapped wholesale when the visitor
 * changes language, so component state would be discarded and a still-valid
 * session thrown away — the visitor would be asked to solve Turnstile again for
 * nothing. And the token has an expiry the UI has to act on, which is easier to
 * reason about in one place than spread across renders.
 *
 * It is deliberately not written to storage: a bearer token that outlives the
 * tab buys nothing here, since solving Turnstile again is cheap and automatic.
 */

interface ActiveSession {
  token: string;
  /** When the session is given up — its expiry, less the safety margin. */
  usableUntil: number;
}

let active: ActiveSession | null = null;

/**
 * Give a session up slightly early, so a request cannot leave carrying a token
 * that expires while it is in flight.
 */
const EXPIRY_MARGIN_MS = 60_000;

/**
 * The margin, never more than half of what the session was given.
 *
 * A fixed margin quietly assumes the worker hands out long sessions. Shorten
 * the token's lifetime to the margin or less — which is exactly what testing
 * expiry means — and every session arrives already spent: the gate returns, the
 * challenge is solved, the new session is spent on arrival too, and the widget
 * spins forever without the chat ever opening. Scaling the margin down keeps
 * short sessions short but usable.
 */
function usableUntil(expiresAt: number): number {
  const lifetime = expiresAt - Date.now();
  return expiresAt - Math.min(EXPIRY_MARGIN_MS, Math.floor(lifetime / 2));
}

/** Milliseconds until the session should be given up, or null if there is none. */
export const millisecondsUntilExpiry = (): number | null =>
  active === null ? null : active.usableUntil - Date.now();

/**
 * The current token, or null once there is none left to use. An expired one is
 * dropped here rather than handed out and refused by the worker.
 * @example const token = readSession();
 */
export const readSession = (): string | null => {
  if (active === null) return null;
  if (Date.now() >= active.usableUntil) {
    active = null;
    return null;
  }
  return active.token;
};

/**
 * Store a freshly issued session. Returns false when the token is unusable on
 * arrival — a lifetime of zero or a clock far enough out of step that its
 * expiry is already past. Nothing is stored in that case, and the caller has to
 * report it rather than solve the challenge again, because solving it again
 * would produce another token just as dead.
 *
 * @example if (!writeSession(token, expiresAt)) failGate(message);
 */
export const writeSession = (token: string, expiresAt: number): boolean => {
  const until = usableUntil(expiresAt);
  if (until <= Date.now()) {
    active = null;
    return false;
  }
  active = { token, usableUntil: until };
  return true;
};

/** @example clearSession(); */
export const clearSession = (): void => {
  active = null;
};
