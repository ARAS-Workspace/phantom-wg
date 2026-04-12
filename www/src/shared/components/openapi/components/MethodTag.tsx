import { Tag } from '@carbon/react';
import type { HttpMethod } from '../types/openapi';

const METHOD_COLORS: Record<HttpMethod, 'green' | 'blue' | 'red' | 'purple' | 'teal'> = {
  get: 'green',
  post: 'blue',
  put: 'purple',
  delete: 'red',
  patch: 'teal',
};

interface MethodTagProps {
  method: HttpMethod;
}

const MethodTag = ({ method }: MethodTagProps) => (
  <Tag type={METHOD_COLORS[method]} size="sm" className="api-doc__method-tag">
    {method.toUpperCase()}
  </Tag>
);

export default MethodTag;