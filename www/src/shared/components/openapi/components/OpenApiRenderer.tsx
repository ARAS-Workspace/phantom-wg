import { useMemo } from 'react';
import { Accordion, Tag, InlineNotification } from '@carbon/react';
import { groupByTag } from '../utils/specParser';
import type { OpenApiSpec } from '../types/openapi';
import TagGroup from './TagGroup';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import '../styles/ApiDoc.scss';

interface OpenApiRendererProps {
  spec: OpenApiSpec;
  showVersion?: boolean;
}

const OpenApiRenderer = ({ spec, showVersion = true }: OpenApiRendererProps) => {
  const { locale } = useLocale();
  const t = translate(locale);

  const tagGroups = useMemo(() => groupByTag(spec), [spec]);

  if (tagGroups.length === 0) {
    return (
      <div className="api-doc api-doc--error">
        <InlineNotification kind="info" title={t.apiDoc.error} hideCloseButton lowContrast />
      </div>
    );
  }

  return (
    <div className="api-doc" data-testid="api-doc">
      {showVersion && (
        <div className="api-doc__header">
          <span className="api-doc__title">{spec.info.title}</span>
          <Tag type="blue" size="sm">
            {t.apiDoc.version} {spec.info.version}
          </Tag>
        </div>
      )}

      <Accordion className="api-doc__groups">
        {tagGroups.map((group) => (
          <TagGroup key={group.name} group={group} />
        ))}
      </Accordion>
    </div>
  );
};

export default OpenApiRenderer;