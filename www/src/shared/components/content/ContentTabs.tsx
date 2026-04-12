import React from 'react';
import { Tabs, TabList, Tab, TabPanels, TabPanel } from '@carbon/react';
import { useIsClient } from '@shared/hooks/useIsClient';
import './styles/ContentTabs.scss';

interface TabItem {
  label: string;
  content: React.ComponentType<any> | any;
}

interface ContentTabsProps {
  tabs: TabItem[];
  contained?: boolean;
  className?: string;
}

const ContentTabs: React.FC<ContentTabsProps> = ({ tabs, contained = true, className = '' }) => {
  const isClient = useIsClient();

  if (!tabs || tabs.length === 0) {
    return null;
  }

  // Prerender: render all tab contents stacked so Playwright captures full content
  if (!isClient) {
    return (
      <div className="content-tabs__prerender">
        {tabs.map((tab, index) => {
          const ContentComponent = tab.content;
          return (
            <div key={index}>
              <ContentComponent />
            </div>
          );
        })}
      </div>
    );
  }

  return (
    <div className={`content-tabs ${className}`}>
      <Tabs>
        <TabList aria-label="Content Tabs" contained={contained}>
          {tabs.map((tab, index) => (
            <Tab key={`tab-${index}`}>{tab.label}</Tab>
          ))}
        </TabList>
        <TabPanels>
          {tabs.map((tab, index) => {
            const ContentComponent = tab.content;
            return (
              <TabPanel key={`panel-${index}`}>
                <div className="content-tabs__panel">
                  <ContentComponent />
                </div>
              </TabPanel>
            );
          })}
        </TabPanels>
      </Tabs>
    </div>
  );
};

export default ContentTabs;
