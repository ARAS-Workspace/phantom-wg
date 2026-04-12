import React from 'react';
import { MisuseOutline } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import './styles/common.scss';

interface GenericErrorPageProps {
  error?: unknown;
}

const GenericErrorPage: React.FC<GenericErrorPageProps> = ({ error }) => {
  const { locale } = useLocale();
  const t = translate(locale);

  const getErrorMessage = (): string => {
    if (error instanceof Error) return error.message;
    if (typeof error === 'string') return error;
    return t.errorPages.generic.defaultMessage;
  };

  return (
    <div className="error-page-container">
      <div className="error-page-content">
        <div className="error-icon-wrapper">
          <MisuseOutline className="error-icon" />
        </div>
        <h1 className="error-code">{t.errorPages.generic.code}</h1>
        <h2 className="error-title">{t.errorPages.generic.title}</h2>
        <p className="error-description">{getErrorMessage()}</p>
        {import.meta.env.DEV && error instanceof Error && (
          <details className="error-details">
            <summary>{t.errorPages.generic.technicalDetails}</summary>
            <pre className="error-stack">{error.stack}</pre>
          </details>
        )}
      </div>
    </div>
  );
};

export default GenericErrorPage;