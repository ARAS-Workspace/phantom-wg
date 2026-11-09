import React, { createContext, useContext, useCallback, useMemo, ReactNode } from 'react';
import useSWR, { mutate as globalMutate } from 'swr';
import { swrFetcher, USER_KEY } from '@shared/api/swrFetcher';
import { holds, type Access } from '@shared/types/access';

export interface UserInfo {
  id: string;
  username: string;
  role: string;
  totp_enabled: boolean;
  created_at: string;
  updated_at: string;
}

interface UserContextValue {
  user: UserInfo | null;
  isLoading: boolean;
  isSuperadmin: boolean;
  can: (access: Access) => boolean;
  mutateUser: () => Promise<void>;
  clearUser: () => void;
}

const UserContext = createContext<UserContextValue | undefined>(undefined);

export const UserProvider: React.FC<{ children: ReactNode }> = ({ children }) => {
  const {
    data: user = null,
    isLoading,
    mutate,
  } = useSWR<UserInfo | null>(USER_KEY, swrFetcher, {
    revalidateOnFocus: true,
    revalidateOnReconnect: true,
    dedupingInterval: 1000,
  });

  const mutateUser = useCallback(async () => {
    await mutate();
  }, [mutate]);

  const clearUser = useCallback(() => {
    void globalMutate(USER_KEY, null, false);
  }, []);

  const isSuperadmin = user?.role === 'superadmin';
  const role = user?.role;

  const can = useCallback((access: Access) => holds(role, access), [role]);

  const value = useMemo(
    () => ({ user, isLoading, isSuperadmin, can, mutateUser, clearUser }),
    [user, isLoading, isSuperadmin, can, mutateUser, clearUser]
  );

  return <UserContext.Provider value={value}>{children}</UserContext.Provider>;
};

export const useUser = (): UserContextValue => {
  const context = useContext(UserContext);
  if (!context) {
    throw new Error('useUser must be used within UserProvider');
  }
  return context;
};
