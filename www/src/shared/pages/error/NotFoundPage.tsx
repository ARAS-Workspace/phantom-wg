import React from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@carbon/react';
import { ArrowLeft, WarningAlt } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import DinoGame from '@shared/components/games/DinoGame';
import './styles/common.scss';

const NotFoundPage: React.FC = () => {
  const navigate = useNavigate();
  const { locale } = useLocale();
  const t = translate(locale);

  return (
    <div className="error-page-container">
      <div className="error-page-content">
        <div className="error-icon-wrapper">
          <WarningAlt className="error-icon" />
        </div>
        <h1 className="error-code">{t.errorPages.notFound.code}</h1>
        <h2 className="error-title">{t.errorPages.notFound.title}</h2>
        <p className="error-description">{t.errorPages.notFound.description}</p>
        <div className="error-game-area">
          <DinoGame.Lazy theme="error" />
        </div>
        <div className="error-actions">
          <Button renderIcon={ArrowLeft} onClick={() => navigate('/')} size="lg">
            {t.errorPages.notFound.backHome}
          </Button>
          <Button kind="ghost" onClick={() => navigate(-1)} size="lg">
            {t.errorPages.notFound.goBack}
          </Button>
        </div>
      </div>
    </div>
  );
};

export default NotFoundPage;
