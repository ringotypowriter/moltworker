import { describe, it, expect } from 'vitest';
import { redactSecrets } from './redact';

describe('redactSecrets', () => {
  it('redacts common secret keys in nested objects', () => {
    const input = {
      gateway: { auth: { token: 'tok-123' } },
      channels: { telegram: { botToken: 'tg-abc', enabled: true } },
      r2: { accessKeyId: 'akid', secretAccessKey: 'secret' },
      openrouter: { apiKey: 'sk-or-123' },
      other: 'value',
    };

    const result = redactSecrets(input);
    expect(result.gateway.auth.token).toBe('[REDACTED]');
    expect(result.channels.telegram.botToken).toBe('[REDACTED]');
    expect(result.r2.accessKeyId).toBe('[REDACTED]');
    expect(result.r2.secretAccessKey).toBe('[REDACTED]');
    expect(result.openrouter.apiKey).toBe('[REDACTED]');
    expect(result.other).toBe('value');
  });

  it('redacts tokens inside arrays', () => {
    const input = {
      models: [
        { id: 'x', apiKey: 'k1' },
        { id: 'y', token: 'k2' },
      ],
    };

    const result = redactSecrets(input);
    expect(result.models[0].apiKey).toBe('[REDACTED]');
    expect(result.models[1].token).toBe('[REDACTED]');
  });
});
