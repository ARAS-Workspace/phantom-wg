import React from 'react';
import PhantomIcon from '@shared/components/ui/PhantomIcon';
import './styles/FooterLogo.scss';

const FooterLogo: React.FC = () => {
  return (
    <div className="footer-logo">
      <PhantomIcon className="footer-logo-svg" />
    </div>
  );
};

export default FooterLogo;
