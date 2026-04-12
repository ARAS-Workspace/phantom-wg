import React from 'react';
import { Grid, Column } from '@carbon/react';
import FooterLogo from './FooterLogo';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import './styles/Footer.scss';

const Footer: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);

  return (
    <footer className="footer">
      <div className="footer-separator" />

      <Grid className="footer-grid" narrow>
        <Column lg={3} md={2} sm={4} className="footer-logo-column">
          <FooterLogo />
        </Column>

        <Column lg={13} md={6} sm={4} className="footer-content-column">
          <p className="footer-copyright-text">{t.footer.copyright.text}</p>
          <p className="footer-trademark">{t.footer.copyright.trademark}</p>
          <p className="footer-trademark-notice">{t.footer.copyright.trademarkNotice}</p>
          <p
            className="footer-copyright-additional"
            dangerouslySetInnerHTML={{ __html: t.footer.copyright.additionalText }}
          />
        </Column>
      </Grid>
    </footer>
  );
};

export default Footer;
