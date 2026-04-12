import React from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@carbon/react';
import { ArrowLeft, ErrorFilled } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import './styles/common.scss';

const ServerErrorPage: React.FC = () => {
  const navigate = useNavigate();
  const { locale } = useLocale();
  const t = translate(locale);

  return (
    <div className="error-page-container">
      <div className="error-page-content">
        <div className="error-icon-wrapper error-icon-wrapper--server">
          <ErrorFilled className="error-icon error-icon--server" />
        </div>
        <h1 className="error-code">{t.errorPages.serverError.code}</h1>
        <h2 className="error-title">{t.errorPages.serverError.title}</h2>
        <p className="error-description">{t.errorPages.serverError.description}</p>
        <div className="error-actions">
          <Button renderIcon={ArrowLeft} onClick={() => navigate('/')} size="lg">
            {t.errorPages.serverError.backHome}
          </Button>
          <Button kind="secondary" onClick={() => window.location.reload()} size="lg">
            {t.errorPages.serverError.reload}
          </Button>
        </div>
      </div>
    </div>
  );
};

export default ServerErrorPage;