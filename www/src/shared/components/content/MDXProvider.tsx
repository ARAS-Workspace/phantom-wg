import React from 'react';
import { MDXProvider as MDXProviderBase } from '@mdx-js/react';
import { components } from './MDXComponents';

interface MDXProviderProps {
  children: React.ReactNode;
}

const MDXProvider: React.FC<MDXProviderProps> = ({ children }) => {
  return <MDXProviderBase components={components}>{children}</MDXProviderBase>;
};

export default MDXProvider;
