export interface NavItem {
  label: string;
  href?: string;
  external?: boolean;
  defaultExpanded?: boolean;
  children?: NavItem[];
}

export interface DocsNavContent {
  headerNav: NavItem[];
  sideNav: NavItem[];
}
