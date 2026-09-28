import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import { generateTTS, TTSInvalidResponseError, TTSRateLimitError } from '@/lib/audio/tts-providers';

const { mockFetch } = vi.hoisted(() => ({ mockFetch: vi.fn() as Mock }));

vi.mock('@/lib/server/audio-provider-fetch', () => ({
  audioProviderFetch: mockFetch,
}));

const WAV_BASE64 = Buffer.from('RIFF....WAVEfmt ').toString('base64');

function audioResponse(data: unknown = WAV_BASE64) {
  return {
    ok: true,
    status: 200,
    json: async () => ({ choices: [{ message: { audio: { data } } }] }),
  };
}

describe('MiMo V2.5 TTS', () => {
  beforeEach(() => mockFetch.mockReset());

  it('sends the documented chat-completions payload and decodes WAV audio', async () => {
    mockFetch.mockResolvedValueOnce(audioResponse());

    const result = await generateTTS(
      {
        providerId: 'mimo-tts',
        apiKey: 'sk-mimo',
        modelId: 'mimo-v2.5-tts',
        voice: 'mimo_default',
        speed: 1,
        publicOnly: true,
      },
      '你好，欢迎学习。',
    );

    expect(mockFetch).toHaveBeenCalledWith(
      'https://api.xiaomimimo.com/v1/chat/completions',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({
          Authorization: 'Bearer sk-mimo',
          'Content-Type': 'application/json; charset=utf-8',
        }),
      }),
      { allowLocalNetworks: false },
    );
    expect(JSON.parse(mockFetch.mock.calls[0][1].body)).toEqual({
      model: 'mimo-v2.5-tts',
      messages: [
        { role: 'user', content: 'Speak naturally and clearly.' },
        { role: 'assistant', content: '你好，欢迎学习。' },
      ],
      audio: { format: 'wav', voice: 'mimo_default' },
      stream: false,
    });
    expect(result).toEqual({
      audio: new Uint8Array(Buffer.from('RIFF....WAVEfmt ')),
      format: 'wav',
    });
  });

  it('uses the provider defaults when model and voice are omitted', async () => {
    mockFetch.mockResolvedValueOnce(audioResponse());

    await generateTTS({ providerId: 'mimo-tts', apiKey: 'sk-mimo', voice: '' }, 'hello');

    const body = JSON.parse(mockFetch.mock.calls[0][1].body);
    expect(body.model).toBe('mimo-v2.5-tts');
    expect(body.audio.voice).toBe('mimo_default');
  });

  it('translates non-default speed into a delivery instruction', async () => {
    mockFetch.mockResolvedValueOnce(audioResponse()).mockResolvedValueOnce(audioResponse());

    await generateTTS(
      { providerId: 'mimo-tts', apiKey: 'sk-mimo', voice: 'Mia', speed: 0.75 },
      'slow',
    );
    await generateTTS(
      { providerId: 'mimo-tts', apiKey: 'sk-mimo', voice: 'Mia', speed: 1.5 },
      'fast',
    );

    expect(JSON.parse(mockFetch.mock.calls[0][1].body).messages[0].content).toContain(
      '0.75 times normal speed',
    );
    expect(JSON.parse(mockFetch.mock.calls[1][1].body).messages[0].content).toContain(
      '1.50 times normal speed',
    );
  });

  it('accepts a custom base URL and does not duplicate the full endpoint', async () => {
    mockFetch.mockResolvedValueOnce(audioResponse());

    await generateTTS(
      {
        providerId: 'mimo-tts',
        apiKey: 'sk-mimo',
        baseUrl: 'https://gateway.example.com/v1/chat/completions',
        voice: 'Chloe',
      },
      'hello',
    );

    expect(mockFetch.mock.calls[0][0]).toBe('https://gateway.example.com/v1/chat/completions');
  });

  it('maps HTTP 429 to the shared rate-limit error', async () => {
    mockFetch.mockResolvedValueOnce({ ok: false, status: 429, statusText: 'Too Many Requests' });

    await expect(
      generateTTS({ providerId: 'mimo-tts', apiKey: 'sk-mimo', voice: 'mimo_default' }, 'hello'),
    ).rejects.toBeInstanceOf(TTSRateLimitError);
  });

  it('surfaces non-2xx provider details', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: false,
      status: 400,
      statusText: 'Bad Request',
      text: async () => JSON.stringify({ error: { message: 'invalid voice' } }),
    });

    await expect(
      generateTTS({ providerId: 'mimo-tts', apiKey: 'sk-mimo', voice: 'bad' }, 'hello'),
    ).rejects.toThrow('invalid voice');
  });

  it.each([
    ['malformed JSON', { json: async () => Promise.reject(new SyntaxError('bad json')) }],
    ['missing audio', { json: async () => ({ choices: [{ message: {} }] }) }],
    ['empty audio', audioResponse('')],
    ['invalid Base64', audioResponse('%%%not-base64%%%')],
    ['non-WAV bytes', audioResponse(Buffer.from('not a wav file').toString('base64'))],
  ])('rejects %s with TTSInvalidResponseError', async (_label, response) => {
    mockFetch.mockResolvedValueOnce({ ok: true, status: 200, ...response });

    await expect(
      generateTTS({ providerId: 'mimo-tts', apiKey: 'sk-mimo', voice: 'mimo_default' }, 'hello'),
    ).rejects.toBeInstanceOf(TTSInvalidResponseError);
  });
});
