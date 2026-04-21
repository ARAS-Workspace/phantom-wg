// Central JSDoc typedefs for Cloudflare Stream API shapes and local client.
// Reference via `@typedef {import('./types.js').TypeName} TypeName` at the
// top of any consuming file. No runtime code lives here.

/**
 * A single video as returned by the Cloudflare Stream API.
 * @see https://developers.cloudflare.com/api/resources/stream/
 *
 * @typedef {object} CFStreamVideo
 * @property {string} uid                            Unique video identifier.
 * @property {string|null} [creator]                 Optional creator identifier set at upload.
 * @property {string} [thumbnail]                    Still-image thumbnail URL.
 * @property {number} [thumbnailTimestampPct]        Point in the video used as thumbnail (0.0–1.0).
 * @property {boolean} [readyToStream]               True once encoding is complete.
 * @property {string} [readyToStreamAt]              ISO-8601 timestamp when ready.
 * @property {CFStreamStatus} [status]               Encoding/ready status breakdown.
 * @property {CFStreamMeta} [meta]                   User-supplied metadata.
 * @property {string} [created]                      ISO-8601 creation timestamp.
 * @property {string} [modified]                     ISO-8601 last-modified timestamp.
 * @property {string|null} [scheduledDeletion]
 * @property {number|null} [size]                    File size in bytes.
 * @property {string} [preview]                      Short-form preview URL.
 * @property {string[]} [allowedOrigins]             Allowed embed origins.
 * @property {boolean} [requireSignedURLs]           Whether playback requires a signed URL.
 * @property {string} [uploaded]                     ISO-8601 upload timestamp.
 * @property {string|null} [uploadExpiry]
 * @property {number|null} [maxSizeBytes]
 * @property {number|null} [maxDurationSeconds]
 * @property {number} [duration]                     Duration in seconds.
 * @property {CFStreamInput} [input]                 Source video dimensions.
 * @property {CFStreamPlayback} [playback]           HLS / DASH manifest URLs.
 * @property {object|null} [watermark]
 * @property {object|null} [liveInput]
 * @property {object|null} [clippedFrom]
 * @property {object|null} [publicDetails]
 * @property {string} [filename]                     Rarely present at the top level; prefer `meta.filename`.
 */

/**
 * Encoding / readiness sub-object on a video.
 *
 * @typedef {object} CFStreamStatus
 * @property {"queued"|"inprogress"|"ready"|"error"|string} [state]
 * @property {string} [pctComplete]                  "100.000000"-style string percentage.
 * @property {string} [errorReasonCode]
 * @property {string} [errorReasonText]
 */

/**
 * User-supplied metadata bag on a video.
 *
 * @typedef {object} CFStreamMeta
 * @property {string} [name]                         Display name set at upload (via `meta` field).
 * @property {string} [filename]                     Original filename supplied by the uploader.
 * @property {string} [filetype]                     MIME type supplied by the uploader.
 */

/**
 * Source video dimensions.
 *
 * @typedef {object} CFStreamInput
 * @property {number} [width]
 * @property {number} [height]
 */

/**
 * Playback manifest URLs for a video.
 *
 * @typedef {object} CFStreamPlayback
 * @property {string} [hls]                          HLS manifest URL (`.m3u8`).
 * @property {string} [dash]                         DASH manifest URL (`.mpd`).
 */

/**
 * Standard Cloudflare API response envelope.
 *
 * @template T
 * @typedef {object} CFResponse
 * @property {T} result
 * @property {boolean} success
 * @property {Array<{ code: number, message: string }>} [errors]
 * @property {string[]} [messages]
 */

/**
 * Options accepted by `createClient` in `cf-stream.js`.
 *
 * @typedef {object} CFClientOptions
 * @property {string} [apiToken]                     Override CLOUDFLARE_API_TOKEN for this call.
 * @property {string} [accountId]                    Override CLOUDFLARE_ACCOUNT_ID for this call.
 */

/**
 * Minimal payload for the direct-upload endpoint — the multipart/form-data
 * body accepts only the file itself; all other metadata has to be applied
 * via a follow-up `POST /stream/{uid}` (see `VideoUpdatePatch`).
 *
 * @see https://developers.cloudflare.com/api/resources/stream/methods/create/
 *
 * @typedef {object} UploadFileInput
 * @property {Buffer|Uint8Array} file      File contents.
 * @property {string}            filename  Filename used in the multipart form.
 */

/**
 * Patch payload for `POST /stream/{uid}` — every field is optional and
 * maps 1-to-1 onto the Cloudflare Stream "edit video details" endpoint.
 *
 * @see https://developers.cloudflare.com/api/resources/stream/methods/edit/
 *
 * @typedef {object} VideoUpdatePatch
 * @property {Record<string, string>}   [meta]                    Custom meta object (includes `meta.name`).
 * @property {boolean}                  [requireSignedURLs]       Require signed URLs for playback.
 * @property {string[]}                 [allowedOrigins]          Domains allowed to embed the player.
 * @property {number}                   [thumbnailTimestampPct]   Thumbnail frame position (0.0–1.0).
 * @property {string}                   [scheduledDeletion]       ISO-8601 timestamp for automatic deletion.
 * @property {string}                   [creator]                 Opaque creator identifier stored with the video.
 */

/**
 * Query parameters accepted by the list endpoint.
 *
 * @see https://developers.cloudflare.com/api/resources/stream/methods/list/
 *
 * @typedef {object} ListVideosParams
 * @property {string}                                    [search]   Fuzzy match against video name.
 * @property {"ready"|"inprogress"|"queued"|"error"}     [status]   Encoding state filter.
 * @property {string}                                    [creator]  Filter by creator identifier.
 * @property {string}                                    [before]   ISO-8601 — videos created before.
 * @property {string}                                    [after]    ISO-8601 — videos created after.
 * @property {boolean}                                   [asc]      Sort ascending by creation time.
 * @property {number}                                    [limit]    Max results (CF cap: 1000).
 */

/**
 * Cloudflare Stream REST client returned by `createClient`.
 *
 * @typedef {object} CFStreamClient
 * @property {(input: UploadFileInput) => Promise<CFResponse<CFStreamVideo>>} uploadVideo
 * @property {(uid: string, patch: VideoUpdatePatch) => Promise<CFResponse<CFStreamVideo>>} updateVideo
 * @property {(params?: ListVideosParams) => Promise<CFResponse<CFStreamVideo[]>>} listVideos
 * @property {(uid: string) => Promise<CFResponse<CFStreamVideo>>} getVideo
 * @property {(uid: string) => Promise<CFResponse<null>>} deleteVideo
 */

// Marker export so this file is treated as an ES module; consumers use
// `import('./types.js').TypeName` in JSDoc to reference the types above.
export {};
