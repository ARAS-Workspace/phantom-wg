import { AccordionItem, Tag } from '@carbon/react';
import type { TagGroup as TagGroupType } from '../types/openapi';
import EndpointCard from './EndpointCard';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';

interface TagGroupProps {
  group: TagGroupType;
}

const TagGroup = ({ group }: TagGroupProps) => {
  const { locale } = useLocale();
  const t = translate(locale);

  const title = (
    <span className="api-doc__tag-title">
      <strong>{group.name}</strong>
      <Tag type="cool-gray" size="sm">
        {group.operations.length} {t.apiDoc.endpoints}
      </Tag>
    </span>
  );

  return (
    <AccordionItem title={title} className="api-doc__tag-group">
      {group.description && (
        <p className="api-doc__tag-desc">{group.description}</p>
      )}
      {group.operations.map((op) => (
        <EndpointCard key={`${op.method}-${op.path}`} operation={op} />
      ))}
    </AccordionItem>
  );
};

export default TagGroup;