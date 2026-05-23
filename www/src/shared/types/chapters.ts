export interface Chapter {
  /** Stable kebab-case identifier (used for deep-link anchors / aria). */
  slug: string;
  /** Label rendered on the chapter strip. */
  label: string;
  /** Start time in seconds. */
  start: number;
}
