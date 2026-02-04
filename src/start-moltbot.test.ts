import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

describe('start-moltbot.sh OpenRouter config', () => {
  it('uses supported OpenAI-compatible api value for OpenRouter', () => {
    const scriptPath = resolve(__dirname, '..', 'start-moltbot.sh');
    const contents = readFileSync(scriptPath, 'utf8');
    expect(contents).toContain("api: 'openai-completions'");
  });

  it('does not use unsupported openai-chat-completions api value', () => {
    const scriptPath = resolve(__dirname, '..', 'start-moltbot.sh');
    const contents = readFileSync(scriptPath, 'utf8');
    expect(contents).not.toContain("openai-chat-completions");
  });

  it('resolves the clawdbot binary before exec', () => {
    const scriptPath = resolve(__dirname, '..', 'start-moltbot.sh');
    const contents = readFileSync(scriptPath, 'utf8');
    expect(contents).toContain('CLAWDBOT_BIN');
    expect(contents).toContain('command -v clawdbot');
    expect(contents).toContain('exec "$CLAWDBOT_BIN"');
  });
});
