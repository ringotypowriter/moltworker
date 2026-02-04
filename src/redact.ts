type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

const SECRET_KEY_PATTERN = /(apiKey|accessKey|secret|token|botToken|appToken)/i;

export function redactSecrets<T extends JsonValue>(value: T): T {
  if (Array.isArray(value)) {
    return value.map((item) => redactSecrets(item)) as T;
  }

  if (value && typeof value === 'object') {
    const result: { [key: string]: JsonValue } = {};
    for (const [key, child] of Object.entries(value)) {
      if (SECRET_KEY_PATTERN.test(key)) {
        result[key] = '[REDACTED]';
      } else {
        result[key] = redactSecrets(child as JsonValue);
      }
    }
    return result as T;
  }

  return value;
}
