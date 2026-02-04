import { describe, it, expect, vi } from 'vitest';
import { withTimeout } from './utils';

describe('withTimeout', () => {
  it('resolves when promise resolves before timeout', async () => {
    const result = await withTimeout(Promise.resolve('ok'), 50, 'test');
    expect(result).toBe('ok');
  });

  it('rejects when promise does not resolve before timeout', async () => {
    vi.useFakeTimers();
    const never = new Promise<string>(() => {});
    const promise = withTimeout(never, 10, 'slow-op');
    vi.advanceTimersByTime(11);

    await expect(promise).rejects.toThrow('Timeout after 10ms: slow-op');
    vi.useRealTimers();
  });
});
