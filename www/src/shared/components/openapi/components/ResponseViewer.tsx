import { Tag } from '@carbon/react';
import CodeHighlight from '@shared/components/visualization/CodeHighlight';
import type { ResponseObject } from '../types/openapi';
import { generateBodyTemplate } from '../utils/specParser';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';

interface ResponseViewerProps {
  responses: Record<string, ResponseObject>;
}

const STATUS_COLORS: Record<string, 'green' | 'blue' | 'red' | 'magenta' | 'cool-gray'> = {
  '2': 'green',
  '3': 'blue',
  '4': 'magenta',
  '5': 'red',
};

function getStatusColor(code: string): 'green' | 'blue' | 'red' | 'magenta' | 'cool-gray' {
  return STATUS_COLORS[code[0]] ?? 'cool-gray';
}

const ResponseViewer = ({ responses }: ResponseViewerProps) => {
  const { locale } = useLocale();
  const t = translate(locale);

  const entries = Object.entries(responses);
  if (entries.length === 0) {
    return <p className="api-doc__empty">{t.apiDoc.noResponse}</p>;
  }

  return (
    <div className="api-doc__responses">
      {entries.map(([code, response]) => {
        const schema = response.content?.['application/json']?.schema;
        const example = schema ? generateBodyTemplate(schema) : null;

        return (
          <div key={code} className="api-doc__response-item">
            <div className="api-doc__response-header">
              <Tag type={getStatusColor(code)} size="sm">{code}</Tag>
              <span className="api-doc__response-desc">
                {response.description ?? ''}
              </span>
            </div>
            {example !== null && (
              <div className="api-doc__response-example">
                <CodeHighlight
                  code={JSON.stringify(example, null, 2)}
                  lang="json"
                />
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
};

export default ResponseViewer;