// Python str semantics the daemon's exit config parser relies on
// (phantom_daemon/base/exit_store/parser.py). The JavaScript built-ins differ:
// trim() removes U+FEFF and keeps U+001C-U+001F, \d is ASCII only, split on
// "\n" misses the other line boundaries, and Number() accepts "1e3" and
// "0x10". The tables below are generated from CPython 3.13 (Unicode 15.1).

// str.isspace()
const WHITESPACE = new Set(
  '\u0009\u000a\u000b\u000c\u000d\u001c\u001d\u001e\u001f\u0020\u0085\u00a0\u1680' +
    '\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a' +
    '\u2028\u2029\u202f\u205f\u3000'
);

// str.splitlines() boundaries; "\r\n" counts as one.
const LINE_BOUNDARY = /\r\n|[\n\r\u000b\u000c\u001c\u001d\u001e\u0085\u2028\u2029]/;

// First code point of every block of ten decimal digits (str.isdecimal()).
const DECIMAL_ZEROS = [
  0x30, 0x660, 0x6f0, 0x7c0, 0x966, 0x9e6, 0xa66, 0xae6, 0xb66, 0xbe6, 0xc66, 0xce6, 0xd66, 0xde6,
  0xe50, 0xed0, 0xf20, 0x1040, 0x1090, 0x17e0, 0x1810, 0x1946, 0x19d0, 0x1a80, 0x1a90, 0x1b50,
  0x1bb0, 0x1c40, 0x1c50, 0xa620, 0xa8d0, 0xa900, 0xa9d0, 0xa9f0, 0xaa50, 0xabf0, 0xff10, 0x104a0,
  0x10d30, 0x11066, 0x110f0, 0x11136, 0x111d0, 0x112f0, 0x11450, 0x114d0, 0x11650, 0x116c0, 0x11730,
  0x118e0, 0x11950, 0x11c50, 0x11d50, 0x11da0, 0x11f50, 0x16a60, 0x16ac0, 0x16b50, 0x1d7ce, 0x1d7d8,
  0x1d7e2, 0x1d7ec, 0x1d7f6, 0x1e140, 0x1e2f0, 0x1e4f0, 0x1e950, 0x1fbf0,
];

// Code points where str.isdigit() holds and str.isdecimal() does not.
const DIGIT_ONLY_RANGES: ReadonlyArray<readonly [number, number]> = [
  [0xb2, 0xb3],
  [0xb9, 0xb9],
  [0x1369, 0x1371],
  [0x19da, 0x19da],
  [0x2070, 0x2070],
  [0x2074, 0x2079],
  [0x2080, 0x2089],
  [0x2460, 0x2468],
  [0x2474, 0x247c],
  [0x2488, 0x2490],
  [0x24ea, 0x24ea],
  [0x24f5, 0x24fd],
  [0x24ff, 0x24ff],
  [0x2776, 0x277e],
  [0x2780, 0x2788],
  [0x278a, 0x2792],
  [0x10a40, 0x10a43],
  [0x10e60, 0x10e68],
  [0x11052, 0x1105a],
  [0x1f100, 0x1f10a],
];

const ASCII = /^[\x00-\x7f]*$/;

/** The value of a decimal digit code point, or -1. */
function decimalValue(codePoint: number): number {
  for (const zero of DECIMAL_ZEROS) {
    if (codePoint >= zero && codePoint < zero + 10) return codePoint - zero;
  }
  return -1;
}

function isDigitCodePoint(codePoint: number): boolean {
  if (decimalValue(codePoint) >= 0) return true;
  return DIGIT_ONLY_RANGES.some(([low, high]) => codePoint >= low && codePoint <= high);
}

/** str.splitlines() */
export function splitLines(text: string): string[] {
  return text.split(LINE_BOUNDARY);
}

/** str.strip() */
export function strip(text: string): string {
  let start = 0;
  let end = text.length;
  while (start < end && WHITESPACE.has(text[start])) start++;
  while (end > start && WHITESPACE.has(text[end - 1])) end--;
  return text.slice(start, end);
}

/** len(text.split()) == 1: one word, no whitespace inside. */
export function isOneWord(text: string): boolean {
  const word = strip(text);
  if (!word) return false;
  for (const ch of word) {
    if (WHITESPACE.has(ch)) return false;
  }
  return true;
}

/** str.isascii() */
export function isAscii(text: string): boolean {
  return ASCII.test(text);
}

/** str.isdigit() */
export function isDigit(text: string): boolean {
  if (text === '') return false;
  for (const ch of text) {
    if (!isDigitCodePoint(ch.codePointAt(0) ?? -1)) return false;
  }
  return true;
}

/**
 * int(text) in base 10: surrounding whitespace, an optional sign, decimal
 * digits of any script, single underscores between digits. Returns null
 * where Python raises ValueError.
 */
export function toInt(text: string): bigint | null {
  const body = strip(text);
  const chars = Array.from(body);
  let index = 0;
  let negative = false;
  if (chars[0] === '+' || chars[0] === '-') {
    negative = chars[0] === '-';
    index = 1;
  }
  if (index >= chars.length) return null;

  let value = 0n;
  let previousWasDigit = false;
  for (; index < chars.length; index++) {
    const ch = chars[index];
    if (ch === '_') {
      if (!previousWasDigit) return null;
      previousWasDigit = false;
      continue;
    }
    const digit = decimalValue(ch.codePointAt(0) ?? -1);
    if (digit < 0) return null;
    value = value * 10n + BigInt(digit);
    previousWasDigit = true;
  }
  if (!previousWasDigit) return null;
  return negative ? -value : value;
}
