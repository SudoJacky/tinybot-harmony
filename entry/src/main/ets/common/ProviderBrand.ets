// Keep brand assets in the UI layer; profiles retain only their existing preset ID.
export function providerLogo(presetId: string): Resource | undefined {
  switch (presetId) {
    case 'deepseek': return $r('app.media.logo_deepseek');
    case 'dashscope': return $r('app.media.logo_dashscope');
    case 'openai':
    case 'openai-responses': return $r('app.media.logo_openai');
    case 'zai': return $r('app.media.logo_zai');
    case 'ollama': return $r('app.media.logo_ollama');
    case 'anthropic': return $r('app.media.logo_anthropic');
    default: return undefined;
  }
}

export function monochromeProviderLogo(presetId: string): boolean {
  return ['openai', 'openai-responses', 'ollama', 'anthropic'].includes(presetId);
}
