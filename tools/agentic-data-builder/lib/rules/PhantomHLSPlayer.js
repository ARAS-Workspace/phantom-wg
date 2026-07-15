// Rule: <PhantomHLSPlayer src poster /> → a short bilingual note that a video is
// embedded here, plus a direct reference to its source stream. Video content is
// not text, so the note describes the medium and points at the src.

/** @typedef {import('../types.js').RuleProps} RuleProps */

/**
 * @param {RuleProps} props
 * @returns {string}
 */
export function rule(props) {
  const src = typeof props.src === 'string' ? props.src : '';
  const lines = [
    '> **Video** · EN: an embedded video walkthrough — its content is shown in the recording, not as text · TR: gömülü video anlatımı — içerik metin olarak değil kayıt olarak gösterilir',
  ];
  if (src) lines.push(`> src: \`${src}\``);
  return lines.join('\n');
}
