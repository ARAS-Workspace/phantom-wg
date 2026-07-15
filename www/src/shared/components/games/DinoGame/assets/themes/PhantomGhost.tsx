import React from 'react';
import type { CarbonIconType } from '@carbon/icons-react';

// Phantom's ghost as a Carbon-compatible icon: single `currentColor` fill (themes
// exactly like the Carbon glyphs), `size`-driven square box, eyes punched out via
// evenodd. Paths taken from asset-pipelines/main-asset-generator/masters/
// phantom-icon-master.svg (ghost body + eyes, shield dropped); the viewBox centres
// the ghost so it sits at the same visual weight as the other theme icons.
const GHOST =
  'M218.1,69c-66.59,0-118.96,52.37-118.96,118.96v139.16l41.15-41.15,41.15,41.15,36.67-41.15,36.67,41.15,41.15-41.15,41.15,41.15v-139.16c0-66.59-52.37-118.96-118.96-118.96Z';
const LEFT_EYE = 'M145.9,166.26a28.06,28.06,0,1,0,56.12,0a28.06,28.06,0,1,0,-56.12,0Z';
const RIGHT_EYE = 'M234.2,166.26a28.06,28.06,0,1,0,56.12,0a28.06,28.06,0,1,0,-56.12,0Z';

type PhantomGhostProps = React.SVGProps<SVGSVGElement> & { size?: number | string };

const PhantomGhostIcon = React.forwardRef<SVGSVGElement, PhantomGhostProps>(
  ({ size = 16, ...props }, ref) => (
    <svg
      ref={ref}
      xmlns="http://www.w3.org/2000/svg"
      width={size}
      height={size}
      viewBox="75 55 286 286"
      fill="currentColor"
      {...props}
    >
      <path fillRule="evenodd" d={`${GHOST} ${LEFT_EYE} ${RIGHT_EYE}`} />
    </svg>
  ),
);

PhantomGhostIcon.displayName = 'PhantomGhostIcon';

// The DinoGame icon slots are typed as CarbonIconType; PhantomGhostIcon renders the
// same SVG shape (size + currentColor) so it drops in interchangeably.
export const PhantomGhost = PhantomGhostIcon as unknown as CarbonIconType;
