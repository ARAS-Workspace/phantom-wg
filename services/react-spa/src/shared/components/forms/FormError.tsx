import React from 'react';
import { InlineNotification } from '@carbon/react';
import './styles/FormError.scss';

interface FormErrorProps {
  error: string | null;
  /** Lines listed under the title, one per problem. */
  details?: string[];
  className?: string;
}

const FormError: React.FC<FormErrorProps> = ({ error, details, className }) => {
  if (!error) return null;
  const hasDetails = !!details && details.length > 0;
  return (
    <InlineNotification
      kind="error"
      title={error}
      lowContrast
      hideCloseButton
      className={
        hasDetails ? [className, 'form-error--details'].filter(Boolean).join(' ') : className
      }
    >
      {hasDetails && (
        <ul className="form-error__details">
          {details.map((line, index) => (
            <li key={index}>{line}</li>
          ))}
        </ul>
      )}
    </InlineNotification>
  );
};

export default FormError;
