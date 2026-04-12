import React, { createContext, useContext, useState, useCallback, useEffect } from 'react';
import { useLocale } from '@shared/hooks';

export interface SEOMetadata {
  title: string;
  description: string;
  path?: string;
  locale?: 'tr' | 'en';
  schemas?: any[];
}

interface SEOContextValue {
  metadata: SEOMetadata;
  updateMetadata: (metadata: SEOMetadata) => void;
  addSchema: (schema: any) => void;
  removeSchema: (schemaId: string) => void;
  clearSchemas: () => void;
  setSchemas: (schemas: any[]) => void;
}

const SEOContext = createContext<SEOContextValue | undefined>(undefined);

export const SEOProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { locale } = useLocale();

  const [metadata, setMetadata] = useState<SEOMetadata>({
    title: '',
    description: '',
    locale,
    schemas: [],
  });

  useEffect(() => {
    setMetadata((prev) => ({
      ...prev,
      locale,
      schemas: [],
    }));
  }, [locale]);

  const updateMetadata = useCallback((newMetadata: SEOMetadata) => {
    setMetadata((prev) => ({
      ...prev,
      ...newMetadata,
      schemas: newMetadata.schemas ?? prev.schemas,
    }));
  }, []);

  const addSchema = useCallback((schema: any) => {
    setMetadata((prev) => ({
      ...prev,
      schemas: [...(prev.schemas || []), schema],
    }));
  }, []);

  const removeSchema = useCallback((schemaId: string) => {
    setMetadata((prev) => ({
      ...prev,
      schemas: (prev.schemas || []).filter((s) => s['@id'] !== schemaId),
    }));
  }, []);

  const clearSchemas = useCallback(() => {
    setMetadata((prev) => ({ ...prev, schemas: [] }));
  }, []);

  const setSchemas = useCallback((schemas: any[]) => {
    setMetadata((prev) => ({ ...prev, schemas }));
  }, []);

  return (
    <SEOContext.Provider
      value={{ metadata, updateMetadata, addSchema, removeSchema, clearSchemas, setSchemas }}
    >
      {children}
    </SEOContext.Provider>
  );
};

export const useSEO = (): SEOContextValue => {
  const context = useContext(SEOContext);
  if (!context) {
    throw new Error('useSEO must be used within SEOProvider');
  }
  return context;
};
