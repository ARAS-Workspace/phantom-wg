import { StrictMode } from 'react';
import ReactDOM from 'react-dom/client';

import App from './App';

import '@shared/styles/carbon-config.scss';

import { printConsoleBranding } from '@shared/utils/console-branding';
printConsoleBranding();

// Before the app renders, so the listener is in place before the first lazy
// route is reached. See the module comment for what it recovers from.
import { installChunkReloadGuard } from '@shared/utils/chunk-reload';
installChunkReloadGuard();

const rootElement = document.getElementById('root');
if (!rootElement) {
  throw new Error('Failed to find the root element');
}

const root = ReactDOM.createRoot(rootElement);

root.render(
  <StrictMode>
    <App />
  </StrictMode>
);
