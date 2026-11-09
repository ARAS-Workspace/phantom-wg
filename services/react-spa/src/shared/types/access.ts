import type { UserRole } from './nav';

// The access a daemon route asks of the caller, and the roles that hold
// each one. GRANTS mirrors GRANTS in auth-service routes/proxy.py: the
// proxy refuses a route to a role outside its access, and the panel
// leaves out the controls of that route.
export type Access = 'view' | 'tunnel' | 'operate' | 'multihop' | 'custody';

export const GRANTS: Record<Access, readonly UserRole[]> = {
  view: ['admin', 'superadmin'],
  tunnel: ['admin', 'superadmin'],
  operate: ['superadmin'],
  multihop: ['superadmin'],
  custody: ['superadmin'],
};

export function holds(role: string | undefined, access: Access): boolean {
  return GRANTS[access].some((granted) => granted === role);
}
