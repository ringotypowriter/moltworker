import { describe, it, expect } from 'vitest';
import { createMockEnv } from './test-utils';
import { validateRequiredEnv } from './index';

describe('validateRequiredEnv', () => {
  it('accepts OpenRouter-only configuration', () => {
    const env = createMockEnv({
      MOLTBOT_GATEWAY_TOKEN: 'token',
      CF_ACCESS_TEAM_DOMAIN: 'team.example.com',
      CF_ACCESS_AUD: 'audience',
      OPENROUTER_API_KEY: 'sk-or-key',
      OPENROUTER_MODEL: 'anthropic/claude-sonnet-4-5',
    });
    const missing = validateRequiredEnv(env);
    expect(missing).toEqual([]);
  });

  it('requires OPENROUTER_MODEL when OPENROUTER_API_KEY is set', () => {
    const env = createMockEnv({
      MOLTBOT_GATEWAY_TOKEN: 'token',
      CF_ACCESS_TEAM_DOMAIN: 'team.example.com',
      CF_ACCESS_AUD: 'audience',
      OPENROUTER_API_KEY: 'sk-or-key',
    });
    const missing = validateRequiredEnv(env);
    expect(missing).toContain('OPENROUTER_MODEL (required when using OPENROUTER_API_KEY)');
  });

  it('requires OPENROUTER_API_KEY when OPENROUTER_MODEL is set', () => {
    const env = createMockEnv({
      MOLTBOT_GATEWAY_TOKEN: 'token',
      CF_ACCESS_TEAM_DOMAIN: 'team.example.com',
      CF_ACCESS_AUD: 'audience',
      OPENROUTER_MODEL: 'anthropic/claude-sonnet-4-5',
    });
    const missing = validateRequiredEnv(env);
    expect(missing).toContain('OPENROUTER_API_KEY (required when using OPENROUTER_MODEL)');
  });
});
