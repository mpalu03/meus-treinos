-- ÁXIS · aviso de fim do descanso por notificação (Web Push)
-- O app agenda o aviso; a cada 2 s o banco procura avisos vencidos e chama a função "descanso",
-- que envia a notificação para o celular. Pode rodar de novo sem problema.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------------------
-- Inscrições de notificação (uma por celular)
-- ---------------------------------------------------------------------------
create table if not exists public.push_inscricoes (
  endpoint text primary key check (
    length(endpoint) <= 1000 and endpoint ~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/'
  ),
  user_id uuid not null references auth.users (id) on delete cascade,
  p256dh text not null check (length(p256dh) between 40 and 200),
  auth text not null check (length(auth) between 10 and 100),
  atualizado_em timestamptz not null default now()
);
create index if not exists push_inscricoes_user_idx on public.push_inscricoes (user_id);
alter table public.push_inscricoes enable row level security;

drop policy if exists "ver as proprias inscricoes" on public.push_inscricoes;
create policy "ver as proprias inscricoes" on public.push_inscricoes for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists "apagar as proprias inscricoes" on public.push_inscricoes;
create policy "apagar as proprias inscricoes" on public.push_inscricoes for delete to authenticated
  using (user_id = (select auth.uid()));
revoke insert, update on public.push_inscricoes from anon, authenticated;

-- O mesmo celular pode trocar de conta: a inscrição passa para quem está logado agora
create or replace function public.registrar_push(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Entre na sua conta primeiro'; end if;
  insert into public.push_inscricoes (endpoint, user_id, p256dh, auth, atualizado_em)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, now())
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, atualizado_em = now();
end $$;
revoke all on function public.registrar_push(text, text, text) from public, anon;
grant execute on function public.registrar_push(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Avisos agendados
-- ---------------------------------------------------------------------------
create table if not exists public.avisos (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  endpoint text,
  espera_s integer not null check (espera_s between 0 and 1800),
  enviar_em timestamptz not null default now(),
  titulo text not null check (length(titulo) between 1 and 80),
  corpo text not null default '' check (length(corpo) <= 200),
  tag text not null default 'descanso' check (tag ~ '^[a-z0-9-]{1,30}$'),
  enviado_em timestamptz,
  criado_em timestamptz not null default now()
);
create index if not exists avisos_pendentes_idx on public.avisos (enviar_em) where enviado_em is null;
create index if not exists avisos_user_idx on public.avisos (user_id);
alter table public.avisos enable row level security;

drop policy if exists "ver os proprios avisos" on public.avisos;
create policy "ver os proprios avisos" on public.avisos for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists "agendar avisos" on public.avisos;
create policy "agendar avisos" on public.avisos for insert to authenticated
  with check (user_id = (select auth.uid()));
drop policy if exists "cancelar avisos" on public.avisos;
create policy "cancelar avisos" on public.avisos for delete to authenticated
  using (user_id = (select auth.uid()));
revoke update on public.avisos from anon, authenticated;

-- O horário vem do relógio do servidor (o do celular pode estar adiantado ou atrasado).
-- Um novo aviso do mesmo tipo, no mesmo celular, substitui o anterior que ainda não saiu.
create or replace function public.prepara_aviso() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.user_id := coalesce(auth.uid(), new.user_id);
  new.enviar_em := now() + make_interval(secs => new.espera_s);
  new.enviado_em := null;
  new.criado_em := now();
  delete from public.avisos a
   where a.user_id = new.user_id and a.tag = new.tag and a.enviado_em is null
     and a.endpoint is not distinct from new.endpoint and a.id <> new.id;
  if (select count(*) from public.avisos a where a.user_id = new.user_id and a.enviado_em is null) >= 5 then
    raise exception 'Muitos avisos pendentes';
  end if;
  return new;
end $$;
drop trigger if exists prepara_aviso on public.avisos;
create trigger prepara_aviso before insert on public.avisos
  for each row execute function public.prepara_aviso();
revoke all on function public.prepara_aviso() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Disparo: pega os avisos vencidos e manda para a função de envio
-- (as chaves de envio ficam no Vault, em "axis_vapid")
-- ---------------------------------------------------------------------------
create or replace function public.axis_disparar_avisos() returns void
language plpgsql security definer set search_path = '' as $$
declare
  lote jsonb;
  chave jsonb;
begin
  if not exists (select 1 from public.avisos where enviado_em is null and enviar_em <= now() + interval '1 second') then
    return;
  end if;
  select decrypted_secret::jsonb into chave from vault.decrypted_secrets where name = 'axis_vapid';
  if chave is null then return; end if;

  with vencidos as (
    update public.avisos a set enviado_em = now()
     where a.id in (
       select x.id from public.avisos x
        where x.enviado_em is null and x.enviar_em <= now() + interval '1 second'
        order by x.enviar_em limit 100
        for update skip locked)
    returning a.id, a.user_id, a.endpoint, a.titulo, a.corpo, a.tag
  )
  select jsonb_agg(jsonb_build_object(
           'id', v.id, 'titulo', v.titulo, 'corpo', v.corpo, 'tag', v.tag,
           'subs', coalesce((
             select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
               from public.push_inscricoes s
              where s.user_id = v.user_id and (v.endpoint is null or s.endpoint = v.endpoint)), '[]'::jsonb)))
    into lote
    from vencidos v;
  if lote is null then return; end if;

  perform net.http_post(
    url := 'https://qlksntoamjutmycrqidf.supabase.co/functions/v1/descanso',
    body := jsonb_build_object('acao', 'disparar', 'chave', chave, 'avisos', lote),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000
  );
end $$;
revoke all on function public.axis_disparar_avisos() from public, anon, authenticated;

-- Limpeza: inscrições que o celular cancelou, avisos antigos e o histórico do cron
create or replace function public.axis_limpeza() returns void
language plpgsql security definer set search_path = '' as $$
begin
  begin
    delete from public.push_inscricoes
     where endpoint in (
       select jsonb_array_elements_text(r.content::jsonb -> 'gone')
         from net._http_response r
        where r.status_code = 200 and r.content like '{"axis":%' and r.created > now() - interval '3 hours');
  exception when others then null;
  end;
  delete from public.avisos where criado_em < now() - interval '1 day';
  delete from public.push_inscricoes where atualizado_em < now() - interval '180 days';
  begin
    delete from cron.job_run_details where end_time < now() - interval '1 hour';
  exception when others then null;
  end;
end $$;
revoke all on function public.axis_limpeza() from public, anon, authenticated;

select cron.schedule('axis-avisos', '2 seconds', 'select public.axis_disparar_avisos()');
select cron.schedule('axis-limpeza', '17 * * * *', 'select public.axis_limpeza()');
