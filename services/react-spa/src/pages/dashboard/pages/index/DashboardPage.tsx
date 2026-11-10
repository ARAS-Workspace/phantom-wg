import React from 'react';
import { useLocale } from '@shared/hooks';
import MDXPageRenderer from '@shared/components/content/MDXPageRenderer';
import { DashboardDataProvider } from '../../shared/contexts/DashboardDataContext';
import ContentTr from './index.mdx';
import ContentEn from './index.en.mdx';

const CONTENT_MAP: Record<string, React.ComponentType> = {
  tr: ContentTr,
  en: ContentEn,
};

const DashboardPage: React.FC = () => {
  const { locale } = useLocale();
  const Content = CONTENT_MAP[locale] || CONTENT_MAP.tr;
  // key: the content of a new language reads the dashboard again
  return (
    <DashboardDataProvider key={locale}>
      <MDXPageRenderer content={Content} className="dashboard-page" data-testid="dashboard-page" />
    </DashboardDataProvider>
  );
};

export default DashboardPage;
