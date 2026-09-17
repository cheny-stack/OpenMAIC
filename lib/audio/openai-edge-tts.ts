/**
 * Compatibility helpers for travisvn/openai-edge-tts.
 *
 * The service exposes an OpenAI-compatible speech endpoint but rejects the
 * OpenAI voice aliases for some languages. In particular, Chinese text must be
 * sent with a concrete Microsoft neural voice such as zh-CN-XiaoxiaoNeural.
 */

export const OPENAI_EDGE_TTS_DEFAULT_VOICE_ZH = 'zh-CN-XiaoxiaoNeural';
export const OPENAI_EDGE_TTS_DEFAULT_VOICE_EN = 'en-US-AriaNeural';

const CJK_TEXT =
  /[\u2e80-\u2eff\u3040-\u30ff\u3100-\u312f\u31a0-\u31bf\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/u;

/** True when the configured base URL looks like the standard Edge TTS deployment. */
export function isOpenAIEdgeTTSBaseUrl(baseUrl: string | undefined): boolean {
  if (!baseUrl?.trim()) return false;
  try {
    const url = new URL(baseUrl);
    return url.port === '5050' || /(^|[.-])openai-edge-tts([.-]|$)/i.test(url.hostname);
  } catch {
    return false;
  }
}

/** Pick a concrete Edge neural voice when the client still sends the `default` placeholder. */
export function resolveOpenAIEdgeTTSDefaultVoice(
  baseUrl: string | undefined,
  voice: string,
  text: string,
): string {
  if (!isOpenAIEdgeTTSBaseUrl(baseUrl) || voice.trim().toLowerCase() !== 'default') return voice;
  return CJK_TEXT.test(text) ? OPENAI_EDGE_TTS_DEFAULT_VOICE_ZH : OPENAI_EDGE_TTS_DEFAULT_VOICE_EN;
}
