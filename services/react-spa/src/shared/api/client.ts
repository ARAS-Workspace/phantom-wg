export interface ApiOk<T> {
  ok: true;
  data: T;
}

export interface ApiErr {
  ok: false;
  error_code?: string; // auth-service errors + client-side synthetic codes
  code?: string; // daemon errors, and FORBIDDEN on a 403
  error?: string; // daemon: full English message for debugging
}

export type ApiResponse<T> = ApiOk<T> | ApiErr;

type SessionExpiredHandler = () => void;

const AUTH_PATHS = [
  '/auth/login',
  '/auth/mfa/verify',
  '/auth/totp/backup',
  '/auth/totp/setup',
  '/auth/totp/confirm',
  '/auth/totp/disable',
  '/auth/password/verify',
  '/auth/password/change',
];

class ApiClient {
  private onSessionExpired: SessionExpiredHandler | null = null;

  setSessionExpiredHandler(handler: SessionExpiredHandler) {
    this.onSessionExpired = handler;
  }

  private getToken(): string | null {
    return localStorage.getItem('token');
  }

  async request<T>(method: string, path: string, body?: unknown): Promise<ApiResponse<T>> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };

    const token = this.getToken();
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    let response: Response;
    try {
      response = await fetch(path, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch {
      return { ok: false, error_code: 'NETWORK_ERROR' };
    }

    if (response.status >= 500) {
      return { ok: false, error_code: 'SERVER_ERROR' };
    }

    if (response.status === 401 && !AUTH_PATHS.includes(path)) {
      this.onSessionExpired?.();
      return { ok: false, error_code: 'SESSION_EXPIRED' };
    }

    // Auth pages read error_code and daemon pages read code; FORBIDDEN is
    // in both code tables, so a refused route shows the permission message.
    if (response.status === 403) {
      return { ok: false, error_code: 'FORBIDDEN', code: 'FORBIDDEN' };
    }

    return response.json();
  }

  get<T>(path: string) {
    return this.request<T>('GET', path);
  }

  post<T>(path: string, body?: unknown) {
    return this.request<T>('POST', path, body);
  }

  // noinspection JSUnusedGlobalSymbols
  delete<T>(path: string) {
    return this.request<T>('DELETE', path);
  }
}

export const apiClient = new ApiClient();
