import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import { generateTTS } from '@/lib/audio/tts-providers';

const { mockFetch } = vi.hoisted(() => ({ mockFetch: vi.fn() as Mock }));

vi.mock('@/lib/server/audio-provider-fetch', () => ({
  audioProviderFetch: mockFetch,
}));

function mp3Response(): ArrayBuffer {
  return new Uint8Array([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00]).buffer;
}

describe('OpenAI-compatible custom TTS', () => {
  beforeEach(() => {
    mockFetch.mockReset();
  });

  it('normalizes the base URL and sends the configured Edge voice', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      headers: { get: () => 'audio/mpeg' },
      arrayBuffer: async () => mp3Response(),
    });

    const result = await generateTTS(
      {
        providerId: 'custom-tts-edge',
        apiKey: 'sk-edge',
        baseUrl: 'http://192.169.6.239:5050/v1/',
        modelId: 'tts-1',
        voice: 'zh-CN-XiaoxiaoNeural',
        speed: 1,
      },
      '你好',
    );

    expect(mockFetch).toHaveBeenCalledWith(
      'http://192.169.6.239:5050/v1/audio/speech',
      expect.objectContaining({ method: 'POST' }),
      { allowLocalNetworks: undefined },
    );
    expect(JSON.parse(mockFetch.mock.calls[0][1].body)).toEqual({
      model: 'tts-1',
      input: '你好',
      voice: 'zh-CN-XiaoxiaoNeural',
      speed: 1,
    });
    expect(result.format).toBe('mp3');
  });

  it('does not append /audio/speech twice when the full endpoint is configured', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      headers: { get: () => 'audio/mpeg' },
      arrayBuffer: async () => mp3Response(),
    });

    await generateTTS(
      {
        providerId: 'custom-tts-edge',
        baseUrl: 'http://192.169.6.239:5050/v1/audio/speech',
        voice: 'en-US-AriaNeural',
      },
      'hello',
    );

    expect(mockFetch.mock.calls[0][0]).toBe('http://192.169.6.239:5050/v1/audio/speech');
  });

  it('surfaces the provider detail instead of only INTERNAL SERVER ERROR', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: false,
      status: 500,
      statusText: 'INTERNAL SERVER ERROR',
      text: async () =>
        JSON.stringify({
          details: "Invalid voice 'default'.",
          error: 'An internal server error occurred',
        }),
    });

    await expect(
      generateTTS(
        {
          providerId: 'custom-tts-edge',
          baseUrl: 'http://192.169.6.239:5050/v1',
          voice: 'zh-CN-XiaoxiaoNeural',
        },
        '你好',
      ),
    ).rejects.toThrow("Invalid voice 'default'.");
  });

  it('maps the legacy default placeholder to an Edge neural voice by text language', async () => {
    mockFetch
      .mockResolvedValueOnce({
        ok: true,
        headers: { get: () => 'audio/mpeg' },
        arrayBuffer: async () => mp3Response(),
      })
      .mockResolvedValueOnce({
        ok: true,
        headers: { get: () => 'audio/mpeg' },
        arrayBuffer: async () => mp3Response(),
      });

    await generateTTS(
      {
        providerId: 'custom-tts-edge',
        baseUrl: 'http://192.169.6.239:5050/v1',
        voice: 'default',
      },
      '你好，欢迎学习。',
    );
    await generateTTS(
      {
        providerId: 'custom-tts-edge',
        baseUrl: 'http://192.169.6.239:5050/v1',
        voice: 'default',
      },
      'Hello, welcome.',
    );

    expect(JSON.parse(mockFetch.mock.calls[0][1].body).voice).toBe('zh-CN-XiaoxiaoNeural');
    expect(JSON.parse(mockFetch.mock.calls[1][1].body).voice).toBe('en-US-AriaNeural');
  });
});
