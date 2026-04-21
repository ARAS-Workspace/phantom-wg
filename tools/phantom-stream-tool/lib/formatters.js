import pc from 'picocolors';

/** @typedef {import('./types.js').CFStreamVideo} CFStreamVideo */

/**
 * Return the raw UID verbatim — pipe-friendly output for shell substitution
 * (e.g. `VIDEO_ID=$(phantom-stream-tool upload clip.mp4)`).
 *
 * @param {string} uid
 * @returns {string}
 */
export function formatUUID(uid) {
  return uid;
}

/**
 * Pretty-print any JSON-serialisable value with a two-space indent.
 *
 * @param {unknown} obj
 * @returns {string}
 */
export function formatJSON(obj) {
  return JSON.stringify(obj, null, 2);
}

/**
 * Render an aligned, colour-highlighted table summarising each video.
 *
 * @param {CFStreamVideo[]} videos
 * @returns {string}
 */
export function formatTable(videos) {
  if (!videos || videos.length === 0) {
    return pc.dim('(no videos)');
  }

  const rows = videos.map((v) => ({
    uid: v.uid ?? '-',
    name: v.meta?.name || v.meta?.filename || '-',
    size: formatBytes(v.size),
    duration: formatDuration(v.duration),
    created: (v.created ?? '').slice(0, 10),
    status: v.status?.state ?? '-',
  }));

  const col = {
    uid: Math.max(3, ...rows.map((r) => r.uid.length)),
    name: Math.min(36, Math.max(4, ...rows.map((r) => r.name.length))),
    size: Math.max(4, ...rows.map((r) => r.size.length)),
    duration: Math.max(8, ...rows.map((r) => r.duration.length)),
    created: 10,
    status: Math.max(6, ...rows.map((r) => r.status.length)),
  };

  const header = [
    pc.bold('UID'.padEnd(col.uid)),
    pc.bold('NAME'.padEnd(col.name)),
    pc.bold('SIZE'.padStart(col.size)),
    pc.bold('DURATION'.padStart(col.duration)),
    pc.bold('CREATED'.padEnd(col.created)),
    pc.bold('STATUS'.padEnd(col.status)),
  ].join('  ');

  const body = rows
    .map((r) =>
      [
        r.uid.padEnd(col.uid),
        truncate(r.name, col.name).padEnd(col.name),
        r.size.padStart(col.size),
        r.duration.padStart(col.duration),
        r.created.padEnd(col.created),
        r.status.padEnd(col.status),
      ].join('  '),
    )
    .join('\n');

  return `${header}\n${body}`;
}

/**
 * Human-readable detail block for a single video: identifiers, status,
 * playback manifests and thumbnail URLs.
 *
 * @param {CFStreamVideo} v
 * @returns {string}
 */
export function formatVideoDetails(v) {
  const lines = [
    `${label('UID')}${v.uid ?? '-'}`,
    `${label('Name')}${v.meta?.name || v.meta?.filename || '-'}`,
    `${label('Status')}${v.status?.state ?? '-'}`,
    `${label('Ready')}${v.readyToStream ? pc.green('yes') : pc.yellow('no')}`,
    `${label('Size')}${formatBytes(v.size)}`,
    `${label('Duration')}${formatDuration(v.duration)}`,
    `${label('Created')}${v.created ?? '-'}`,
    `${label('Modified')}${v.modified ?? '-'}`,
    '',
    pc.bold('Playback:'),
    `  HLS:        ${v.playback?.hls ?? '-'}`,
    `  DASH:       ${v.playback?.dash ?? '-'}`,
    '',
    pc.bold('Thumbnails:'),
    `  Still:      ${v.thumbnail ?? '-'}`,
    `  Preview:    ${v.preview ?? '-'}`,
  ];
  return lines.join('\n');
}

/**
 * Bold, fixed-width label prefix used in detail listings.
 *
 * @param {string} text
 * @returns {string}
 */
function label(text) {
  return pc.bold(`${text}:`.padEnd(12));
}

/**
 * Render a byte count in binary-prefix units (KB/MB/GB), one decimal digit.
 *
 * @param {number|null|undefined} bytes
 * @returns {string}
 */
function formatBytes(bytes) {
  if (bytes == null) return '-';
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)}GB`;
}

/**
 * Render seconds as `M:SS` (zero-padded seconds).
 *
 * @param {number|null|undefined} seconds
 * @returns {string}
 */
function formatDuration(seconds) {
  if (seconds == null || seconds < 0) return '-';
  const total = Math.floor(seconds);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

/**
 * Truncate a string with a trailing ellipsis if it exceeds `max` characters.
 *
 * @param {string} s
 * @param {number} max
 * @returns {string}
 */
function truncate(s, max) {
  if (s.length <= max) return s;
  return s.slice(0, Math.max(1, max - 1)) + '…';
}
