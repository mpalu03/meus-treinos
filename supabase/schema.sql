-- ÁXIS · banco de dados no Supabase
-- Pode rodar de novo sem problema.
-- A primeira conta criada vira personal. Para ter outros personais, inclua o e-mail em "personais".

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Quem é personal: quem criar conta com um destes e-mails entra como personal
-- ---------------------------------------------------------------------------
create table if not exists public.personais (
  email text primary key
);

-- ---------------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  nome text,
  papel text not null default 'aluno' check (papel in ('personal', 'aluno')),
  criado_em timestamptz not null default now()
);

create table if not exists public.alunos (
  id uuid primary key default gen_random_uuid(),
  personal_id uuid not null references auth.users (id) on delete cascade,
  user_id uuid unique references auth.users (id) on delete set null,
  nome text not null check (length(trim(nome)) between 1 and 120),
  objetivo text,
  observacoes text,
  convite text not null unique default upper(substr(md5(gen_random_uuid()::text), 1, 8)),
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
create index if not exists alunos_personal_idx on public.alunos (personal_id);

create table if not exists public.fichas (
  aluno_id uuid primary key references public.alunos (id) on delete cascade,
  plano jsonb not null,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid references auth.users (id) on delete set null
);

create table if not exists public.sessoes (
  id text primary key check (id ~ '^[A-Za-z0-9_.:-]{1,120}$'),
  aluno_id uuid not null references public.alunos (id) on delete cascade,
  data date not null,
  treino text not null,
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);
create index if not exists sessoes_aluno_data_idx on public.sessoes (aluno_id, data);

create table if not exists public.corpo (
  id text primary key check (id ~ '^[A-Za-z0-9_.:-]{1,120}$'),
  aluno_id uuid not null references public.alunos (id) on delete cascade,
  data date not null,
  kg numeric(5, 2) not null check (kg > 0 and kg < 500),
  unique (aluno_id, data)
);

create table if not exists public.avaliacoes (
  id uuid primary key default gen_random_uuid(),
  aluno_id uuid not null references public.alunos (id) on delete cascade,
  data date not null,
  dados jsonb not null default '{}'::jsonb,
  fotos text[] not null default '{}',
  criado_por uuid references auth.users (id) on delete set null,
  criado_em timestamptz not null default now()
);
create index if not exists avaliacoes_aluno_idx on public.avaliacoes (aluno_id, data);

create table if not exists public.comentarios (
  id uuid primary key default gen_random_uuid(),
  aluno_id uuid not null references public.alunos (id) on delete cascade,
  sessao_id text,
  autor_id uuid references auth.users (id) on delete set null,
  autor_papel text not null default 'aluno' check (autor_papel in ('personal', 'aluno')),
  texto text not null check (length(trim(texto)) between 1 and 2000),
  criado_em timestamptz not null default now()
);
create index if not exists comentarios_aluno_idx on public.comentarios (aluno_id, criado_em);
create index if not exists comentarios_autor_idx on public.comentarios (autor_id);
create index if not exists avaliacoes_criado_por_idx on public.avaliacoes (criado_por);
create index if not exists fichas_atualizado_por_idx on public.fichas (atualizado_por);

-- ---------------------------------------------------------------------------
-- Funções de apoio (security definer para não cair em recursão de RLS)
-- ---------------------------------------------------------------------------
create or replace function public.eh_personal() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and papel = 'personal');
$$;

create or replace function public.eh_personal_de(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from alunos where id = a and personal_id = auth.uid());
$$;

create or replace function public.eh_aluno(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from alunos where id = a and user_id = auth.uid());
$$;

create or replace function public.pode_ver(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from alunos where id = a and (personal_id = auth.uid() or user_id = auth.uid()));
$$;

create or replace function public.uuid_ou_nulo(t text) returns uuid
language sql immutable set search_path = '' as $$
  select case when t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then t::uuid end;
$$;

-- Perfil criado junto com a conta; papel decidido pela lista de personais
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, nome, papel)
  values (
    new.id, new.email,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'nome'), ''), split_part(new.email, '@', 1)),
    case when exists (select 1 from personais p where lower(p.email) = lower(new.email))
           or not exists (select 1 from profiles where papel = 'personal') then 'personal' else 'aluno' end
  )
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.novo_usuario();

-- Contas que já existiam antes deste arquivo
insert into public.profiles (id, email, nome, papel)
select u.id, u.email, split_part(u.email, '@', 1), 'aluno' from auth.users u
on conflict (id) do nothing;
update public.profiles p set papel = 'personal'
where exists (select 1 from public.personais x where lower(x.email) = lower(p.email));

-- Protege o vínculo aluno ↔ conta: só pelo código de convite (ou o próprio personal treinando)
create or replace function public.protege_aluno() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.personal_id <> old.personal_id then
    raise exception 'Não é possível trocar o personal do aluno';
  end if;
  if new.user_id is not null
     and (tg_op = 'INSERT' or new.user_id is distinct from old.user_id)
     and new.user_id is distinct from auth.uid()
     and coalesce(current_setting('axis.convite', true), '') <> 'on'
     and auth.uid() is not null then
    raise exception 'Use o código de convite para ligar a conta do aluno';
  end if;
  return new;
end $$;
drop trigger if exists protege_aluno on public.alunos;
create trigger protege_aluno before insert or update on public.alunos
  for each row execute function public.protege_aluno();

-- Aluno usa o código de convite para ligar a conta ao cadastro feito pelo personal
create or replace function public.usar_convite(codigo text) returns public.alunos
language plpgsql security definer set search_path = public as $$
declare r alunos;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta primeiro'; end if;
  select * into r from alunos where convite = upper(trim(codigo)) for update;
  if not found then raise exception 'Código de convite não encontrado'; end if;
  if r.user_id = auth.uid() then return r; end if;
  if r.user_id is not null then raise exception 'Este convite já foi usado por outra conta'; end if;
  if exists (select 1 from alunos where user_id = auth.uid()) then
    raise exception 'Sua conta já está ligada a outro cadastro de aluno';
  end if;
  perform set_config('axis.convite', 'on', true);
  update alunos set user_id = auth.uid() where id = r.id returning * into r;
  perform set_config('axis.convite', '', true);
  return r;
end $$;
revoke all on function public.usar_convite(text) from public, anon;
grant execute on function public.usar_convite(text) to authenticated;

-- Autor e papel dos comentários vêm do servidor, não do aparelho
create or replace function public.marca_comentario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.autor_id := auth.uid();
  new.autor_papel := case when eh_personal_de(new.aluno_id) then 'personal' else 'aluno' end;
  new.criado_em := now();
  return new;
end $$;
drop trigger if exists marca_comentario on public.comentarios;
create trigger marca_comentario before insert on public.comentarios
  for each row execute function public.marca_comentario();

create or replace function public.marca_autor() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'fichas' then new.atualizado_por := auth.uid(); new.atualizado_em := now();
  elsif tg_table_name = 'avaliacoes' and tg_op = 'INSERT' then new.criado_por := auth.uid();
  elsif tg_table_name = 'sessoes' then new.atualizado_em := now();
  end if;
  return new;
end $$;
drop trigger if exists marca_autor on public.fichas;
create trigger marca_autor before insert or update on public.fichas for each row execute function public.marca_autor();
drop trigger if exists marca_autor on public.avaliacoes;
create trigger marca_autor before insert on public.avaliacoes for each row execute function public.marca_autor();
drop trigger if exists marca_autor on public.sessoes;
create trigger marca_autor before insert or update on public.sessoes for each row execute function public.marca_autor();

-- ---------------------------------------------------------------------------
-- Regras de acesso (RLS)
-- ---------------------------------------------------------------------------
alter table public.personais enable row level security;
alter table public.profiles enable row level security;
alter table public.alunos enable row level security;
alter table public.fichas enable row level security;
alter table public.sessoes enable row level security;
alter table public.corpo enable row level security;
alter table public.avaliacoes enable row level security;
alter table public.comentarios enable row level security;

-- personais: ninguém lê pelo app

-- Funções: só usuários logados executam; gatilhos não ficam expostos na API
revoke all on function public.eh_personal() from public, anon;
revoke all on function public.eh_personal_de(uuid) from public, anon;
revoke all on function public.eh_aluno(uuid) from public, anon;
revoke all on function public.pode_ver(uuid) from public, anon;
grant execute on function public.eh_personal() to authenticated;
grant execute on function public.eh_personal_de(uuid) to authenticated;
grant execute on function public.eh_aluno(uuid) to authenticated;
grant execute on function public.pode_ver(uuid) to authenticated;
revoke all on function public.novo_usuario() from public, anon, authenticated;
revoke all on function public.marca_comentario() from public, anon, authenticated;
revoke all on function public.marca_autor() from public, anon, authenticated;
revoke all on function public.protege_aluno() from public, anon, authenticated;

-- nomes antigos (versão 1)
drop policy if exists "ver o proprio perfil" on public.profiles;
drop policy if exists "personal ve perfis dos alunos" on public.profiles;
drop policy if exists "personal gerencia seus alunos" on public.alunos;
drop policy if exists "aluno ve o proprio cadastro" on public.alunos;

-- profiles
drop policy if exists "ver perfis" on public.profiles;
create policy "ver perfis" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or exists (select 1 from public.alunos a where a.user_id = profiles.id and a.personal_id = (select auth.uid())));
drop policy if exists "editar o proprio nome" on public.profiles;
create policy "editar o proprio nome" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
revoke update on public.profiles from anon, authenticated;
grant update (nome) on public.profiles to authenticated;

-- alunos
drop policy if exists "ver alunos" on public.alunos;
create policy "ver alunos" on public.alunos for select to authenticated
  using (personal_id = (select auth.uid()) or user_id = (select auth.uid()));
drop policy if exists "personal cria aluno" on public.alunos;
create policy "personal cria aluno" on public.alunos for insert to authenticated
  with check (personal_id = (select auth.uid()) and public.eh_personal());
drop policy if exists "personal altera aluno" on public.alunos;
create policy "personal altera aluno" on public.alunos for update to authenticated
  using (personal_id = (select auth.uid())) with check (personal_id = (select auth.uid()));
drop policy if exists "personal apaga aluno" on public.alunos;
create policy "personal apaga aluno" on public.alunos for delete to authenticated
  using (personal_id = (select auth.uid()));

-- fichas: personal monta, aluno lê
drop policy if exists "ver ficha" on public.fichas;
create policy "ver ficha" on public.fichas for select to authenticated using (public.pode_ver(aluno_id));
drop policy if exists "personal cria ficha" on public.fichas;
create policy "personal cria ficha" on public.fichas for insert to authenticated with check (public.eh_personal_de(aluno_id));
drop policy if exists "personal altera ficha" on public.fichas;
create policy "personal altera ficha" on public.fichas for update to authenticated
  using (public.eh_personal_de(aluno_id)) with check (public.eh_personal_de(aluno_id));
drop policy if exists "personal apaga ficha" on public.fichas;
create policy "personal apaga ficha" on public.fichas for delete to authenticated using (public.eh_personal_de(aluno_id));

-- sessoes e corpo: aluno registra, personal lê
drop policy if exists "ver treinos" on public.sessoes;
create policy "ver treinos" on public.sessoes for select to authenticated using (public.pode_ver(aluno_id));
drop policy if exists "aluno registra treinos" on public.sessoes;
create policy "aluno registra treinos" on public.sessoes for insert to authenticated with check (public.eh_aluno(aluno_id));
drop policy if exists "aluno altera treinos" on public.sessoes;
create policy "aluno altera treinos" on public.sessoes for update to authenticated
  using (public.eh_aluno(aluno_id)) with check (public.eh_aluno(aluno_id));
drop policy if exists "aluno apaga treinos" on public.sessoes;
create policy "aluno apaga treinos" on public.sessoes for delete to authenticated using (public.eh_aluno(aluno_id));

drop policy if exists "ver peso" on public.corpo;
create policy "ver peso" on public.corpo for select to authenticated using (public.pode_ver(aluno_id));
drop policy if exists "aluno registra peso" on public.corpo;
create policy "aluno registra peso" on public.corpo for insert to authenticated with check (public.eh_aluno(aluno_id));
drop policy if exists "aluno altera peso" on public.corpo;
create policy "aluno altera peso" on public.corpo for update to authenticated
  using (public.eh_aluno(aluno_id)) with check (public.eh_aluno(aluno_id));
drop policy if exists "aluno apaga peso" on public.corpo;
create policy "aluno apaga peso" on public.corpo for delete to authenticated using (public.eh_aluno(aluno_id));

-- avaliacoes: personal registra, aluno lê
drop policy if exists "ver avaliacoes" on public.avaliacoes;
create policy "ver avaliacoes" on public.avaliacoes for select to authenticated using (public.pode_ver(aluno_id));
drop policy if exists "personal registra avaliacoes" on public.avaliacoes;
create policy "personal registra avaliacoes" on public.avaliacoes for insert to authenticated with check (public.eh_personal_de(aluno_id));
drop policy if exists "personal altera avaliacoes" on public.avaliacoes;
create policy "personal altera avaliacoes" on public.avaliacoes for update to authenticated
  using (public.eh_personal_de(aluno_id)) with check (public.eh_personal_de(aluno_id));
drop policy if exists "personal apaga avaliacoes" on public.avaliacoes;
create policy "personal apaga avaliacoes" on public.avaliacoes for delete to authenticated using (public.eh_personal_de(aluno_id));

-- comentarios: os dois leem e escrevem; cada um apaga só os seus
drop policy if exists "ver comentarios" on public.comentarios;
create policy "ver comentarios" on public.comentarios for select to authenticated using (public.pode_ver(aluno_id));
drop policy if exists "escrever comentarios" on public.comentarios;
create policy "escrever comentarios" on public.comentarios for insert to authenticated with check (public.pode_ver(aluno_id));
drop policy if exists "apagar os proprios comentarios" on public.comentarios;
create policy "apagar os proprios comentarios" on public.comentarios for delete to authenticated using (autor_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Fotos das avaliações (Storage, privado): pasta = id do aluno
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avaliacoes', 'avaliacoes', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "axis ver fotos" on storage.objects;
create policy "axis ver fotos" on storage.objects for select to authenticated
  using (bucket_id = 'avaliacoes' and public.pode_ver(public.uuid_ou_nulo((storage.foldername(name))[1])));
drop policy if exists "axis enviar fotos" on storage.objects;
create policy "axis enviar fotos" on storage.objects for insert to authenticated
  with check (bucket_id = 'avaliacoes' and public.eh_personal_de(public.uuid_ou_nulo((storage.foldername(name))[1])));
drop policy if exists "axis apagar fotos" on storage.objects;
create policy "axis apagar fotos" on storage.objects for delete to authenticated
  using (bucket_id = 'avaliacoes' and public.eh_personal_de(public.uuid_ou_nulo((storage.foldername(name))[1])));
