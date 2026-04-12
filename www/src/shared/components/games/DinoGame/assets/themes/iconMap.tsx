import {
  BareMetalServer,
  WarningAlt,
  Cloud as CloudIcon,
  Running,
  TrafficCone,
  Construction,
  Building,
  Firewall,
  ViewFilled,
  WarningHex,
  Locked,
  SecurityServices,
} from '@carbon/icons-react';
import type { CarbonIconType } from '@carbon/icons-react';
import type { ThemeName } from './types';

export type IconComponent = CarbonIconType;

export interface ThemeIcons {
  dino: IconComponent;
  obstacles: IconComponent[];
  clouds: IconComponent[];
}

const ERROR_ICONS: ThemeIcons = {
  dino: BareMetalServer,
  obstacles: [WarningAlt, WarningAlt, WarningAlt],
  clouds: [CloudIcon, CloudIcon, CloudIcon],
};

const DPI_ICONS: ThemeIcons = {
  dino: Running,
  obstacles: [Firewall, ViewFilled, WarningHex],
  clouds: [Locked, SecurityServices, CloudIcon],
};

const UNDER_CONSTRUCTION_ICONS: ThemeIcons = {
  dino: Running,
  obstacles: [Construction, TrafficCone, Building],
  clouds: [CloudIcon, CloudIcon, CloudIcon],
};

export function getThemeIcons(theme: ThemeName): ThemeIcons {
  switch (theme) {
    case 'dpi':
      return DPI_ICONS;
    case 'under-construction':
      return UNDER_CONSTRUCTION_ICONS;
    case 'error':
    default:
      return ERROR_ICONS;
  }
}

export interface VariantCounts {
  obstacle: number;
  cloud: number;
}

export function getVariantCounts(themeIcons: ThemeIcons): VariantCounts {
  return {
    obstacle: themeIcons.obstacles.length,
    cloud: themeIcons.clouds.length,
  };
}