import { useState } from 'react';
import { ChevronDown, ChevronUp } from '@carbon/icons-react';
import type { ParsedOperation } from '../types/openapi';
import MethodTag from './MethodTag';
import ParameterList from './ParameterList';
import ResponseViewer from './ResponseViewer';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';

interface EndpointCardProps {
  operation: ParsedOperation;
}

const EndpointCard = ({ operation }: EndpointCardProps) => {
  const [expanded, setExpanded] = useState(false);
  const { locale } = useLocale();
  const t = translate(locale);

  return (
    <div className={`api-doc__endpoint ${expanded ? 'api-doc__endpoint--expanded' : ''}`}>
      <button
        type="button"
        className="api-doc__endpoint-header"
        onClick={() => setExpanded(!expanded)}
        aria-expanded={expanded}
      >
        <MethodTag method={operation.method} />
        <code className="api-doc__endpoint-path">{operation.path}</code>
        <span className="api-doc__endpoint-summary">{operation.summary}</span>
        <span className="api-doc__endpoint-chevron">
          {expanded ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
        </span>
      </button>

      {expanded && (
        <div className="api-doc__endpoint-body">
          {operation.description && (
            <p className="api-doc__endpoint-desc">{operation.description}</p>
          )}

          {operation.parameters.length > 0 && (
            <div className="api-doc__section">
              <h6 className="api-doc__section-title">{t.apiDoc.parameters}</h6>
              <ParameterList parameters={operation.parameters} />
            </div>
          )}

          {operation.requestBody && (
            <div className="api-doc__section">
              <h6 className="api-doc__section-title">{t.apiDoc.requestBody}</h6>
              <p className="api-doc__empty">
                {Object.keys(operation.requestBody.content).join(', ')}
              </p>
            </div>
          )}

          <div className="api-doc__section">
            <h6 className="api-doc__section-title">{t.apiDoc.responses}</h6>
            <ResponseViewer responses={operation.responses} />
          </div>
        </div>
      )}
    </div>
  );
};

export default EndpointCard;