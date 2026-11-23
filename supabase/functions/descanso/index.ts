// ÁXIS · função "descanso": envia a notificação de fim do descanso (Web Push).
// Chamada pelo banco (pg_cron + pg_net) com os avisos vencidos, e pelo app ao sair da tela durante o descanso.
import { chaveConfere, enviar, type ChaveVapid, type Inscricao } from './webpush.ts';

// Chave pública de envio (a privada fica só no Vault do banco e chega junto com cada lote)
const PUB = { x: '16-ZdyoTtiNuwoIW-Yjow6JlBtkBztmHChxPp7pty5g', y: '3ci2kZwy5VzuMAVGFSns1v4eD_VkZwwGK5_J886MP-A' };
const CONTATO = 'https://mpalu03.github.io/meus-treinos/';
const APP = CONTATO;
const ORIGEM = 'https://mpalu03.github.io';
const CHAVE_APP = 'sb_publishable_VgJ5ctbzboJu8qXTYZnWCQ_8ZvKqVIC';
const SERVICOS = /^https:\/\/(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)\//;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const cors = {
  'Access-Control-Allow-Origin': ORIGEM,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'content-type',
};
const json = (d: unknown, status = 200) =>
  new Response(JSON.stringify(d), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

type Aviso = { id: string; titulo: string; corpo: string; tag: string; subs: Inscricao[] };

async function disparar(b: { chave?: ChaveVapid; avisos?: Aviso[] }) {
  if (!PUB.x || !(await chaveConfere(b.chave as ChaveVapid, PUB))) return json({ ok: false }, 401);
  const chave = b.chave as ChaveVapid;
  const avisos = Array.isArray(b.avisos) ? b.avisos.slice(0, 100) : [];
  const gone: string[] = [];
  let enviados = 0, falhas = 0;
  await Promise.all(avisos.flatMap(a => (Array.isArray(a.subs) ? a.subs.slice(0, 10) : []).map(async s => {
    if (!s || typeof s.endpoint !== 'string' || !SERVICOS.test(s.endpoint)) { falhas++; return; }
    try {
      // Formato "Declarative Web Push" (iOS 18.4+): o próprio sistema mostra a notificação,
      // mesmo se o service worker não rodar. Os campos de cima servem para o service worker de versões antigas.
      const info = a.tag === 'descanso-info';
      const dados = {
        web_push: 8030,
        notification: {
          title: a.titulo, body: a.corpo, navigate: APP + '#treino', lang: 'pt-BR', dir: 'ltr',
          tag: a.tag, silent: info, data: { id: a.id, tag: a.tag },
          // mutable: o service worker também recebe (confirma o recebimento); se ele falhar, o sistema mostra esta mesma
          mutable: true,
        },
        titulo: a.titulo, corpo: a.corpo, tag: a.tag, id: a.id, url: './#treino',
      };
      const st = await enviar(s, dados, chave, CONTATO, {
        ttl: info ? 60 : a.tag === 'descanso' ? 90 : 300, topic: a.tag, urgencia: 'high',
      });
      if (st >= 200 && st < 300) enviados++;
      else { falhas++; if (st === 404 || st === 410) gone.push(s.endpoint); else console.log('push', st, new URL(s.endpoint).host); }
    } catch (e) {
      falhas++; console.log('push erro', String(e));
    }
  })));
  return json({ axis: true, enviados, falhas, gone });
}

// O app, ao sair da tela, manda o aviso por sendBeacon (texto simples, sem cabeçalhos).
// Aqui ele vira um insert normal na tabela "avisos", com o login do próprio usuário (as regras do banco valem).
async function agendar(b: { token?: string; aviso?: Record<string, unknown> }) {
  const t = b.token, a = b.aviso || {};
  if (typeof t !== 'string' || t.length > 4000 || !UUID.test(String(a.id || ''))) return json({ ok: false }, 400);
  const linha = {
    id: a.id,
    endpoint: typeof a.endpoint === 'string' ? a.endpoint.slice(0, 1000) : null,
    espera_s: Math.max(0, Math.min(1800, Math.round(Number(a.espera_s) || 0))),
    titulo: String(a.titulo || 'Descanso acabou').slice(0, 80),
    corpo: String(a.corpo || '').slice(0, 200),
    tag: /^[a-z0-9-]{1,30}$/.test(String(a.tag)) ? a.tag : 'descanso',
  };
  const r = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/avisos`, {
    method: 'POST',
    headers: { apikey: CHAVE_APP, Authorization: `Bearer ${t}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify(linha),
  });
  return json({ ok: r.ok }, r.ok ? 200 : r.status);
}

// Confirmação do celular (service worker) e diagnóstico do app: só registra no log da função.
function registrar(b: Record<string, unknown>) {
  const limpo: Record<string, string> = {};
  for (const k of ['id', 'tag', 'ok', 'erro', 'v', 'sw', 'ua', 'standalone', 'perm', 'decl']) {
    if (b[k] !== undefined) limpo[k] = String(b[k]).slice(0, k === 'ua' ? 200 : 120);
  }
  console.log(String(b.acao), JSON.stringify(limpo));
  return new Response(null, { status: 204, headers: cors });
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (req.method !== 'POST') return json({ ok: false }, 405);
  let b: Record<string, unknown>;
  try { b = JSON.parse(await req.text()); } catch { return json({ ok: false }, 400); }
  if (b.acao === 'disparar') return disparar(b);
  if (b.acao === 'agendar') return agendar(b);
  if (b.acao === 'recebido' || b.acao === 'diag') return registrar(b);
  return json({ ok: false }, 400);
});
