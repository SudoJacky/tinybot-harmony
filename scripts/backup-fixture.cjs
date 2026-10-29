// Independent host decoder: inspect new archives and build real v2 compatibility fixtures.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
function legacyBackupFixture(bytes) {
  if (bytes.subarray(0, 8).toString() !== 'TINYBOT3') return JSON.parse(bytes.toString());
  assert.deepEqual(crypto.createHash('sha256').update(bytes.subarray(0, -32)).digest(), bytes.subarray(-32));
  const length = bytes.readUInt32LE(8), index = JSON.parse(bytes.subarray(12, 12 + length).toString());
  const envelope = JSON.parse(index.metadata); assert.equal(envelope.format, 'tinybot-harmony.backup.v3');
  let position = 12 + length;
  const blobs = index.sizes.map(size => { const value = bytes.subarray(position, position + size); position += size; return value; });
  assert.equal(position, bytes.length - 32);
  for (const item of [...envelope.attachments, ...envelope.files]) item.bytes = blobs[Number(item.bytes)].toString('base64');
  envelope.format = 'tinybot-harmony.backup.v2';
  return envelope;
}
// Native-compatible crypto facade backed by real Node crypto, including GCM's trailing tag.
const backupCrypto = {
  CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
  createRandom: () => ({ generateRandom: async n => ({ data: Uint8Array.from(crypto.randomBytes(n)) }) }),
  createKdf: algorithm => { assert.equal(algorithm, 'PBKDF2|SHA256'); return { generateSecret: spec => new Promise((resolve,reject) => {
    crypto.pbkdf2(spec.password, spec.salt, spec.iterations, spec.keySize, 'sha256', (error,key) => error ? reject(error) : resolve({data:Uint8Array.from(key)}));
  }) }; },
  createSymKeyGenerator: algorithm => { assert.equal(algorithm,'AES256'); return { convertKey: async material => {
    const data=Uint8Array.from(material.data);return {data,clearMem(){data.fill(0);}};
  } }; },
  createCipher: algorithm => { assert.equal(algorithm,'AES256|GCM|NoPadding');let cipher,encrypt;return {
    async init(mode,key,params){encrypt=mode===0;cipher=encrypt?crypto.createCipheriv('aes-256-gcm',key.data,params.iv.data):crypto.createDecipheriv('aes-256-gcm',key.data,params.iv.data);
      cipher.setAAD(Buffer.from(params.aad.data));if(!encrypt)cipher.setAuthTag(Buffer.from(params.authTag.data));},
    async doFinal(blob){const bytes=Buffer.concat([cipher.update(blob.data),cipher.final()]);return{data:Uint8Array.from(encrypt?Buffer.concat([bytes,cipher.getAuthTag()]):bytes)};}
  }; }
};
module.exports = { legacyBackupFixture, backupCrypto };
