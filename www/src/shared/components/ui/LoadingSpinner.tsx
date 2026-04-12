import React from 'react';
import { Loading } from '@carbon/react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import './styles/LoadingSpinner.scss';

interface LoadingSpinnerProps {
  text?: string;
  fullscreen?: boolean;
  small?: boolean;
}

const LoadingSpinner: React.FC<LoadingSpinnerProps> = ({
  text,
  fullscreen = false,
  small = false,
}) => {
  const { locale } = useLocale();
  const t = translate(locale);

  const loadingText =
    text || (fullscreen ? t.loadingSpinner.pageLoading : t.loadingSpinner.loading);

  if (fullscreen) {
    return (
      <div className="loading-spinner-container">
        <div className="loading-spinner-content">
          <Loading withOverlay={false} description={loadingText} className="loading-spinner-icon" />
          <p className="loading-spinner-text">{loadingText}</p>
        </div>
      </div>
    );
  }

  return (
    <div className={`loading-spinner-inline ${small ? 'loading-spinner-inline--small' : ''}`}>
      <Loading withOverlay={false} small={small} description={loadingText} />
    </div>
  );
};

export default LoadingSpinner;
