import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { CollaborationPacket, COLLABORATION_MAX_CHARS } from '../model/DeviceCollaboration';

export interface LanEnvelope { sequence: number; iv: string; data: string; }
export interface LanInvitation { address: string; port: number; secret: string; }
export function privateLanAddress(address: string): boolean {
  const parts = address.split('.').map((part) => Number(part));
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) { return false; }
  return parts[0] === 10 || (parts[0] === 192 && parts[1] === 168) || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31);
}
export function parseLanInvitation(value: string): LanInvitation {
  const match = /^tinybot-lan:\/\/(\d+\.\d+\.\d+\.\d+):(\d{1,5})\/([a-f0-9]{64})$/.exec(value.trim());
  if (!match || !privateLanAddress(match[1]) || Number(match[2]) < 1 || Number(match[2]) > 65535) {
    throw new Error('Invalid LAN invitation.');
  }
  return { address: match[1], port: Number(match[2]), secret: match[3] };
}

// The invitation carries a random 256-bit key. Every socket uses a fresh challenge; direction and sequence are authenticated.
export class LanCollaborationCrypto {
  private key?: cryptoFramework.SymKey;
  static async secret(): Promise<string> {
    return Array.from((await cryptoFramework.createRandom().generateRandom(32)).data)
      .map((value) => value.toString(16).padStart(2, '0')).join('');
  }
  async initialize(secret: string): Promise<void> {
    if (!/^[a-f0-9]{64}$/.test(secret)) { throw new Error('Invalid LAN key.'); }
    const bytes = new Uint8Array(32);
    for (let index = 0; index < 32; index++) { bytes[index] = parseInt(secret.slice(index * 2, index * 2 + 2), 16); }
    try { this.key = await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: bytes }); }
    finally { bytes.fill(0); }
  }
  private aad(challenge: string, role: string, sequence: number): Uint8Array {
    return new util.TextEncoder().encodeInto('tinybot-lan-v1:' + challenge + ':' + role + ':' + sequence);
  }
  async encrypt(packet: CollaborationPacket, challenge: string, role: string, sequence: number): Promise<string> {
    if (!this.key) { throw new Error('LAN key unavailable.'); }
    const text = JSON.stringify(packet);
    if (text.length > COLLABORATION_MAX_CHARS) { throw new Error('LAN message too large.'); }
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec',
      iv: await cryptoFramework.createRandom().generateRandom(12),
      aad: { data: this.aad(challenge, role, sequence) }, authTag: { data: new Uint8Array(16) } };
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, this.key, params);
    const plaintext = new util.TextEncoder().encodeInto(text);
    try {
      const encoded = await cipher.doFinal({ data: plaintext }); const base64 = new util.Base64Helper();
      const envelope: LanEnvelope = { sequence: sequence, iv: base64.encodeToStringSync(params.iv.data), data: base64.encodeToStringSync(encoded.data) };
      return JSON.stringify(envelope) + '\n';
    } finally { plaintext.fill(0); }
  }
  async decrypt(text: string, challenge: string, role: string, sequence: number): Promise<CollaborationPacket> {
    if (!this.key) { throw new Error('LAN key unavailable.'); }
    const envelope = JSON.parse(text) as LanEnvelope;
    if (!envelope || envelope.sequence !== sequence || typeof envelope.iv !== 'string' || typeof envelope.data !== 'string') {
      throw new Error('LAN message sequence mismatch.');
    }
    const base64 = new util.Base64Helper(); const iv = base64.decodeSync(envelope.iv); const data = base64.decodeSync(envelope.data);
    if (iv.length !== 12 || data.length <= 16) { throw new Error('Invalid LAN ciphertext.'); }
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: iv },
      aad: { data: this.aad(challenge, role, sequence) }, authTag: { data: data.slice(-16) } };
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, this.key, params);
    const plaintext = (await cipher.doFinal({ data: data.slice(0, -16) })).data;
    try {
      const decoded = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(plaintext);
      if (decoded.length > COLLABORATION_MAX_CHARS) { throw new Error('LAN message too large.'); }
      const packet = JSON.parse(decoded) as CollaborationPacket;
      if (!packet || packet.version !== 1 || !['hello', 'catalog', 'watch', 'output', 'command', 'receipt'].includes(packet.kind)) {
        throw new Error('Invalid LAN protocol.');
      }
      return packet;
    } finally { plaintext.fill(0); }
  }
  dispose(): void { this.key?.clearMem(); this.key = undefined; }
}
