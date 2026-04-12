import React from 'react';
import { translate, type Locale } from '@shared/translations';

interface FlagIconProps {
  locale: Locale;
  size?: number;
  className?: string;
}

export const FlagIcon: React.FC<FlagIconProps> = ({ locale, size = 20, className = '' }) => {
  const t = translate(locale);

  return (
    <img
      src={t._meta.flag}
      alt={`${t._meta.nativeName} flag`}
      width={size}
      height={size}
      className={`flag-icon ${className}`.trim()}
      style={{
        display: 'block',
        objectFit: 'cover',
        borderRadius: '2px',
      }}
    />
  );
};

export default FlagIcon;
