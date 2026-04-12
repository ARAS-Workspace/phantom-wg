import {
  StructuredListWrapper,
  StructuredListHead,
  StructuredListBody,
  StructuredListRow,
  StructuredListCell,
  Tag,
} from '@carbon/react';
import type { ParameterObject } from '../types/openapi';
import { getSchemaTypeName } from '../utils/specParser';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';

interface ParameterListProps {
  parameters: ParameterObject[];
}

const ParameterList = ({ parameters }: ParameterListProps) => {
  const { locale } = useLocale();
  const t = translate(locale);

  if (parameters.length === 0) {
    return <p className="api-doc__empty">{t.apiDoc.noParameters}</p>;
  }

  return (
    <StructuredListWrapper isCondensed className="api-doc__params">
      <StructuredListHead>
        <StructuredListRow head>
          <StructuredListCell head>{t.apiDoc.name}</StructuredListCell>
          <StructuredListCell head>{t.apiDoc.location}</StructuredListCell>
          <StructuredListCell head>{t.apiDoc.type}</StructuredListCell>
          <StructuredListCell head>{t.apiDoc.required}</StructuredListCell>
          <StructuredListCell head>{t.apiDoc.description}</StructuredListCell>
        </StructuredListRow>
      </StructuredListHead>
      <StructuredListBody>
        {parameters.map((param) => (
          <StructuredListRow key={`${param.in}-${param.name}`}>
            <StructuredListCell>
              <code>{param.name}</code>
            </StructuredListCell>
            <StructuredListCell>
              <Tag type="cool-gray" size="sm">{param.in}</Tag>
            </StructuredListCell>
            <StructuredListCell>
              {param.schema ? getSchemaTypeName(param.schema) : '—'}
            </StructuredListCell>
            <StructuredListCell>
              {param.required ? (
                <Tag type="red" size="sm">{t.apiDoc.required}</Tag>
              ) : '—'}
            </StructuredListCell>
            <StructuredListCell>
              {param.description ?? '—'}
              {param.schema?.default !== undefined && (
                <span className="api-doc__param-default">
                  {' '}(default: {JSON.stringify(param.schema.default)})
                </span>
              )}
            </StructuredListCell>
          </StructuredListRow>
        ))}
      </StructuredListBody>
    </StructuredListWrapper>
  );
};

export default ParameterList;