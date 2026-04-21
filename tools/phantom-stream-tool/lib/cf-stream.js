import { requireValue } from './config.js';

/** @typedef {import('./types.js').CFStreamClient}    CFStreamClient */
/** @typedef {import('./types.js').CFClientOptions}   CFClientOptions */
/** @typedef {import('./types.js').CFStreamVideo}     CFStreamVideo */
/** @typedef {import('./types.js').UploadFileInput}   UploadFileInput */
/** @typedef {import('./types.js').VideoUpdatePatch}  VideoUpdatePatch */
/** @typedef {import('./types.js').ListVideosParams}  ListVideosParams */
/**
 * @template T
 * @typedef {import('./types.js').CFResponse<T>} CFResponse
 */

const API_BASE = 'https://api.cloudflare.com/client/v4';

/**
 * Create a Cloudflare Stream REST client bound to an account.
 * Credentials resolve through flag > env > secrets/.env (see config.js).
 *
 * @param {CFClientOptions} [options]
 * @returns {CFStreamClient}
 */
export function createClient({ apiToken, accountId } = {}) {
  const token = requireValue('CLOUDFLARE_API_TOKEN', apiToken);
  const account = requireValue('CLOUDFLARE_ACCOUNT_ID', accountId);

  /**
   * Low-level request wrapper — handles auth header, JSON parsing and the
   * CF envelope's `success`/`errors` fields. Not exposed to callers.
   *
   * @param {string} pathname
   * @param {{ method?: string, body?: BodyInit|null, headers?: Record<string, string> }} [init]
   * @returns {Promise<any>}
   */
  async function request(pathname, { method = 'GET', body, headers = {} } = {}) {
    const url = `${API_BASE}/accounts/${account}${pathname}`;
    const res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        ...headers,
      },
      body,
    });

    const text = await res.text();
    let json;
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      throw new Error(
        `Cloudflare API returned non-JSON (HTTP ${res.status}): ${text.slice(0, 400)}`,
      );
    }

    if (!res.ok || json.success === false) {
      const errs = (json.errors ?? [])
        .map((/** @type {{ code: number|string, message: string }} */ e) => `[${e.code}] ${e.message}`)
        .join('; ');
      const summary = errs || JSON.stringify(json).slice(0, 400);
      throw new Error(`Cloudflare API error (HTTP ${res.status}): ${summary}`);
    }

    return json;
  }

  return {
    /**
     * Direct upload via multipart/form-data. The multipart body only carries
     * the file itself — Cloudflare's direct-upload endpoint silently ignores
     * metadata fields passed as form data. Use `updateVideo` afterwards to
     * apply `meta`, `requireSignedURLs`, `allowedOrigins`, etc.
     * Max 200 MB per CF Stream direct-upload limits.
     *
     * @param {UploadFileInput} input
     * @returns {Promise<CFResponse<CFStreamVideo>>}
     */
    async uploadVideo({ file, filename }) {
      const form = new FormData();
      form.append('file', new Blob([file]), filename);
      // fetch + FormData sets the multipart Content-Type + boundary automatically.
      return request('/stream', { method: 'POST', body: form });
    },

    /**
     * Edit video details — CF's `POST /stream/{uid}` accepts any subset of
     * metadata fields and merges them into the existing video record. Fields
     * not included in `patch` are left untouched.
     *
     * @param {string}           uid
     * @param {VideoUpdatePatch} patch
     * @returns {Promise<CFResponse<CFStreamVideo>>}
     */
    async updateVideo(uid, patch) {
      return request(`/stream/${encodeURIComponent(uid)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(patch),
      });
    },

    /**
     * List videos with optional filters.
     *
     * @param {ListVideosParams} [params]
     * @returns {Promise<CFResponse<CFStreamVideo[]>>}
     */
    async listVideos(params = {}) {
      const qp = new URLSearchParams();
      if (params.search) qp.set('search', params.search);
      if (params.status) qp.set('status', params.status);
      if (params.creator) qp.set('creator', params.creator);
      if (params.before) qp.set('before', params.before);
      if (params.after) qp.set('after', params.after);
      if (params.asc) qp.set('asc', 'true');
      if (params.limit != null) qp.set('limit', String(params.limit));
      const qs = qp.toString() ? `?${qp}` : '';
      return request(`/stream${qs}`);
    },

    /**
     * Fetch metadata for a single video.
     *
     * @param {string} uid
     * @returns {Promise<CFResponse<CFStreamVideo>>}
     */
    async getVideo(uid) {
      return request(`/stream/${encodeURIComponent(uid)}`);
    },

    /**
     * Delete a video.
     *
     * @param {string} uid
     * @returns {Promise<CFResponse<null>>}
     */
    async deleteVideo(uid) {
      return request(`/stream/${encodeURIComponent(uid)}`, { method: 'DELETE' });
    },
  };
}

/**
 * Extract the customer subdomain (e.g. `customer-abc123`) from a playback URL.
 *
 * @param {string|null|undefined} playbackUrl
 * @returns {string|null}
 */
export function extractCustomerSubdomain(playbackUrl) {
  if (!playbackUrl) return null;
  const m = playbackUrl.match(/https:\/\/(customer-[^.]+)\.cloudflarestream\.com/);
  return m ? m[1] : null;
}
