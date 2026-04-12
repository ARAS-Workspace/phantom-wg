import React from 'react';
import { useRouteError, isRouteErrorResponse } from 'react-router-dom';

import NotFoundPage from './NotFoundPage';
import ServerErrorPage from './ServerErrorPage';
import GenericErrorPage from './GenericErrorPage';

const ErrorPage: React.FC = () => {
  const error = useRouteError();
  if (isRouteErrorResponse(error)) {
    switch (error.status) {
      case 404:
        return <NotFoundPage />;
      case 503:
        return <ServerErrorPage />;
      default:
        return <GenericErrorPage error={error} />;
    }
  }
  return <GenericErrorPage error={error} />;
};

export default ErrorPage;
