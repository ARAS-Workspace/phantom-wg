export interface OpenApiSpec {
  info: { title: string; version: string; description?: string };
  tags?: Array<{ name: string; description?: string }>;
  paths: Record<string, PathItem>;
  components?: { schemas?: Record<string, SchemaObject> };
}

export type PathItem = Partial<Record<HttpMethod, OperationObject>>;

export type HttpMethod = 'get' | 'post' | 'put' | 'delete' | 'patch';

export interface OperationObject {
  tags?: string[];
  summary?: string;
  description?: string;
  operationId?: string;
  parameters?: ParameterObject[];
  requestBody?: RequestBodyObject;
  responses?: Record<string, ResponseObject>;
}

export interface ParameterObject {
  name: string;
  in: 'path' | 'query' | 'header' | 'cookie';
  required?: boolean;
  schema?: SchemaObject;
  description?: string;
}

export interface RequestBodyObject {
  required?: boolean;
  content: Record<string, MediaTypeObject>;
}

export interface MediaTypeObject {
  schema?: SchemaObject;
}

export interface ResponseObject {
  description?: string;
  content?: Record<string, MediaTypeObject>;
}

export interface SchemaObject {
  $ref?: string;
  type?: string | string[];
  format?: string;
  title?: string;
  description?: string;
  properties?: Record<string, SchemaObject>;
  items?: SchemaObject;
  required?: string[];
  enum?: unknown[];
  allOf?: SchemaObject[];
  oneOf?: SchemaObject[];
  anyOf?: SchemaObject[];
  default?: unknown;
  example?: unknown;
  const?: unknown;
  nullable?: boolean;
  minimum?: number;
  maximum?: number;
  pattern?: string;
  additionalProperties?: boolean | SchemaObject;
}

export interface TagGroup {
  name: string;
  description?: string;
  operations: ParsedOperation[];
}

export interface ParsedOperation {
  path: string;
  method: HttpMethod;
  summary: string;
  description: string;
  operationId: string;
  parameters: ParameterObject[];
  requestBody: RequestBodyObject | null;
  responses: Record<string, ResponseObject>;
}