import type {
  OpenApiSpec,
  SchemaObject,
  TagGroup,
  ParsedOperation,
  HttpMethod,
  RequestBodyObject,
} from '../types/openapi';

const METHODS: HttpMethod[] = ['get', 'post', 'put', 'delete', 'patch'];
const MAX_REF_DEPTH = 10;

export function resolveRef(spec: OpenApiSpec, ref: string, depth = 0): SchemaObject {
  if (depth > MAX_REF_DEPTH) return {};

  const path = ref.replace(/^#\//, '').split('/');
  let current: unknown = spec;
  for (const segment of path) {
    if (current && typeof current === 'object' && segment in current) {
      current = (current as Record<string, unknown>)[segment];
    } else {
      return {};
    }
  }

  const result = current as SchemaObject;
  if (result.$ref) {
    return resolveRef(spec, result.$ref, depth + 1);
  }
  return result;
}

export function resolveSchema(
  spec: OpenApiSpec,
  schema: SchemaObject | undefined,
  depth = 0,
): SchemaObject {
  if (!schema || depth > MAX_REF_DEPTH) return {};

  if (schema.$ref) {
    const resolved = resolveRef(spec, schema.$ref, depth);
    return resolveSchema(spec, resolved, depth + 1);
  }

  const result: SchemaObject = { ...schema };

  if (result.properties) {
    const resolved: Record<string, SchemaObject> = {};
    for (const [key, val] of Object.entries(result.properties)) {
      resolved[key] = resolveSchema(spec, val, depth + 1);
    }
    result.properties = resolved;
  }

  if (result.items) result.items = resolveSchema(spec, result.items, depth + 1);
  if (result.allOf) result.allOf = result.allOf.map((s) => resolveSchema(spec, s, depth + 1));
  if (result.oneOf) result.oneOf = result.oneOf.map((s) => resolveSchema(spec, s, depth + 1));
  if (result.anyOf) result.anyOf = result.anyOf.map((s) => resolveSchema(spec, s, depth + 1));

  return result;
}

export function groupByTag(spec: OpenApiSpec): TagGroup[] {
  const tagMap = new Map<string, ParsedOperation[]>();
  const tagOrder: string[] = (spec.tags ?? []).map((t) => t.name);
  const tagDescriptions = new Map<string, string>();

  for (const tag of spec.tags ?? []) {
    if (tag.description) tagDescriptions.set(tag.name, tag.description);
  }

  for (const [path, pathItem] of Object.entries(spec.paths)) {
    if (!pathItem) continue;

    for (const method of METHODS) {
      const operation = pathItem[method];
      if (!operation) continue;

      const tagName = operation.tags?.[0] ?? 'other';

      const resolvedParams = (operation.parameters ?? []).map((p) => ({
        ...p,
        schema: p.schema ? resolveSchema(spec, p.schema) : undefined,
      }));

      let resolvedBody: RequestBodyObject | null = null;
      if (operation.requestBody) {
        const content: Record<string, { schema?: SchemaObject }> = {};
        for (const [ct, mediaType] of Object.entries(operation.requestBody.content)) {
          content[ct] = {
            schema: mediaType.schema ? resolveSchema(spec, mediaType.schema) : undefined,
          };
        }
        resolvedBody = { ...operation.requestBody, content };
      }

      const resolvedResponses: Record<string, { description?: string; content?: Record<string, { schema?: SchemaObject }> }> = {};
      for (const [code, response] of Object.entries(operation.responses ?? {})) {
        if (!response.content) {
          resolvedResponses[code] = { description: response.description };
          continue;
        }
        const rContent: Record<string, { schema?: SchemaObject }> = {};
        for (const [ct, mediaType] of Object.entries(response.content)) {
          rContent[ct] = {
            schema: mediaType.schema ? resolveSchema(spec, mediaType.schema) : undefined,
          };
        }
        resolvedResponses[code] = { description: response.description, content: rContent };
      }

      const parsed: ParsedOperation = {
        path,
        method,
        summary: operation.summary ?? '',
        description: operation.description ?? '',
        operationId: operation.operationId ?? '',
        parameters: resolvedParams,
        requestBody: resolvedBody,
        responses: resolvedResponses,
      };

      const existing = tagMap.get(tagName);
      if (existing) {
        existing.push(parsed);
      } else {
        tagMap.set(tagName, [parsed]);
        if (!tagOrder.includes(tagName)) tagOrder.push(tagName);
      }
    }
  }

  return tagOrder
    .filter((name) => tagMap.has(name))
    .map((name) => ({
      name,
      description: tagDescriptions.get(name),
      operations: tagMap.get(name)!,
    }));
}

export function generateBodyTemplate(schema: SchemaObject, depth = 0): unknown {
  if (depth > 6) return '...';

  if (schema.example !== undefined) return schema.example;
  if (schema.default !== undefined) return schema.default;
  if (schema.const !== undefined) return schema.const;
  if (schema.enum && schema.enum.length > 0) return schema.enum[0];

  const type = Array.isArray(schema.type) ? schema.type[0] : schema.type;

  if (type === 'object' && schema.properties) {
    const obj: Record<string, unknown> = {};
    for (const [key, prop] of Object.entries(schema.properties)) {
      obj[key] = generateBodyTemplate(prop, depth + 1);
    }
    return obj;
  }

  if (type === 'array' && schema.items) {
    return [generateBodyTemplate(schema.items, depth + 1)];
  }

  if (type === 'string') return schema.pattern ?? '';
  if (type === 'integer' || type === 'number') return schema.minimum ?? 0;
  if (type === 'boolean') return false;

  if (schema.anyOf) {
    const nonNull = schema.anyOf.find(
      (s) => !(s.type === 'null' || (Array.isArray(s.type) && s.type.includes('null'))),
    );
    if (nonNull) return generateBodyTemplate(nonNull, depth + 1);
  }

  return null;
}

export function getSchemaTypeName(schema: SchemaObject): string {
  if (schema.title) return schema.title;
  const type = Array.isArray(schema.type)
    ? schema.type.filter((t) => t !== 'null').join(' | ')
    : schema.type;
  if (type === 'array' && schema.items) {
    return `${getSchemaTypeName(schema.items)}[]`;
  }
  return type ?? 'object';
}
