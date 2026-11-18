// Web Push (RFC 8291 aes128gcm + VAPID RFC 8292) só com Web Crypto: funciona no Deno sem dependências.

export type Inscricao = { endpoint: string; p256dh: string; auth: string };
export type ChaveVapid = { x: string; y: string; d: string };

const te = new TextEncoder();

export function b64uEnc(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function b64uDec(str: string): Uint8Array {
  const s = str.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(s + '='.repeat((4 - (s.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, len: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, len * 8));
}

/** Cifra a mensagem para a inscrição (corpo aes128gcm com um único registro). */
export async function cifrar(texto: Uint8Array, p256dh: string, authSecret: string): Promise<Uint8Array> {
  const uaPub = b64uDec(p256dh);
  const auth = b64uDec(authSecret);
  if (uaPub.length !== 65 || auth.length < 16) throw new Error('inscrição inválida');
  const eph = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey('raw', eph.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, eph.privateKey, 256));
  const ikm = await hkdf(auth, ecdh, concat(te.encode('WebPush: info\0'), uaPub, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, te.encode('Content-Encoding: nonce\0'), 12);
  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cifrado = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, concat(texto, new Uint8Array([2]))));
  const cab = new Uint8Array(16 + 4 + 1 + asPub.length);
  cab.set(salt, 0);
  new DataView(cab.buffer).setUint32(16, 4096);
  cab[20] = asPub.length;
  cab.set(asPub, 21);
  return concat(cab, cifrado);
}

export function chavePublica(c: ChaveVapid): string {
  return b64uEnc(concat(new Uint8Array([4]), b64uDec(c.x), b64uDec(c.y)));
}

async function chaveAssinatura(c: ChaveVapid): Promise<CryptoKey> {
  return crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x: c.x, y: c.y, d: c.d, ext: true }, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
}

/** Cabeçalho Authorization do VAPID para o serviço de push do endpoint. */
export async function vapid(endpoint: string, c: ChaveVapid, sub: string, agora = Date.now()): Promise<string> {
  const aud = new URL(endpoint).origin;
  const h = b64uEnc(te.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const p = b64uEnc(te.encode(JSON.stringify({ aud, exp: Math.floor(agora / 1000) + 12 * 3600, sub })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, await chaveAssinatura(c), te.encode(`${h}.${p}`)));
  return `vapid t=${h}.${p}.${b64uEnc(sig)}, k=${chavePublica(c)}`;
}

/** Confere se "d" é mesmo a chave privada da chave pública (x, y) esperada. */
export async function chaveConfere(c: ChaveVapid, esperada: { x: string; y: string }): Promise<boolean> {
  try {
    if (!c || c.x !== esperada.x || c.y !== esperada.y || typeof c.d !== 'string') return false;
    const msg = te.encode('axis');
    const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, await chaveAssinatura(c), msg);
    const pub = await crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x: esperada.x, y: esperada.y, ext: true }, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub, sig, msg);
  } catch {
    return false;
  }
}

export async function gerarChave(): Promise<ChaveVapid & { publica: string }> {
  const par = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey('jwk', par.privateKey) as JsonWebKey;
  const c = { x: jwk.x as string, y: jwk.y as string, d: jwk.d as string };
  return { ...c, publica: chavePublica(c) };
}

/** Envia a notificação. Devolve o status HTTP do serviço de push (201 = entregue ao serviço). */
export async function enviar(
  insc: Inscricao, dados: unknown, c: ChaveVapid, sub: string,
  op: { ttl?: number; topic?: string; urgencia?: string } = {},
): Promise<number> {
  const corpo = await cifrar(te.encode(JSON.stringify(dados)), insc.p256dh, insc.auth);
  const cab: Record<string, string> = {
    Authorization: await vapid(insc.endpoint, c, sub),
    'Content-Encoding': 'aes128gcm',
    'Content-Type': 'application/octet-stream',
    TTL: String(op.ttl ?? 120),
    Urgency: op.urgencia ?? 'high',
  };
  if (op.topic) cab.Topic = op.topic;
  const r = await fetch(insc.endpoint, { method: 'POST', headers: cab, body: corpo });
  try { await r.body?.cancel(); } catch { /* ok */ }
  return r.status;
}
