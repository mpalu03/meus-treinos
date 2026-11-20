-- ÁXIS · conta de administrador (login mestre)
-- O administrador não treina e não tem alunos: vê todos os personais e os alunos de cada um,
-- cadastra novos personais e pode bloquear ou liberar o acesso de um personal. Pode rodar de novo.

-- ---------------------------------------------------------------------------
-- Quem é administrador (só por SQL)
-- ---------------------------------------------------------------------------
create table if not exists public.admins (
  email text primary key check (email = lower(email))
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;
insert into public.admins (email) values ('palu.matheus+admin@gmail.com') on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Personais liberados pelo administrador
-- ---------------------------------------------------------------------------
alter table public.personais add column if not exists nome text;
alter table public.personais add column if not exists ativo boolean not null default true;
alter table public.personais add column if not exists criado_em timestamptz not null default now();
alter table public.personais add column if not exists criado_por uuid references auth.users (id) on delete set null;
create index if not exists personais_criado_por_idx on public.personais (criado_por);
revoke all on public.personais from anon, authenticated;
-- quem já é personal entra na lista
insert into public.personais (email, nome)
  select lower(email), nome from public.profiles where papel = 'personal' and email is not null
on conflict (email) do nothing;

alter table public.profiles drop constraint if exists profiles_papel_check;
alter table public.profiles add constraint profiles_papel_check check (papel in ('admin', 'personal', 'aluno'));

-- Papel de quem cria a conta: admin, personal liberado ou aluno.
-- (A regra antiga "a primeira conta vira personal" sai: agora quem libera é o administrador.)
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, nome, papel)
  values (
    new.id, new.email,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'nome'), ''), split_part(new.email, '@', 1)),
    case when exists (select 1 from admins a where a.email = lower(new.email)) then 'admin'
         when exists (select 1 from personais p where p.email = lower(new.email) and p.ativo) then 'personal'
         else 'aluno' end
  )
  on conflict (id) do nothing;
  return new;
end $$;
revoke all on function public.novo_usuario() from public, anon, authenticated;

update public.profiles p set papel = 'admin'
 where lower(p.email) in (select email from public.admins) and p.papel <> 'admin';

-- ---------------------------------------------------------------------------
-- Regras: personal bloqueado perde o acesso aos alunos
-- ---------------------------------------------------------------------------
create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and papel = 'admin');
$$;
revoke all on function public.eh_admin() from public, anon;
grant execute on function public.eh_admin() to authenticated;

create or replace function public.eh_personal_de(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from alunos al join profiles p on p.id = al.personal_id
     where al.id = a and al.personal_id = auth.uid() and p.papel = 'personal');
$$;

create or replace function public.pode_ver(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from alunos al
     where al.id = a and (al.user_id = auth.uid() or (al.personal_id = auth.uid() and public.eh_personal())));
$$;

drop policy if exists "ver alunos" on public.alunos;
create policy "ver alunos" on public.alunos for select to authenticated
  using (user_id = (select auth.uid()) or (personal_id = (select auth.uid()) and (select public.eh_personal())));
drop policy if exists "personal altera aluno" on public.alunos;
create policy "personal altera aluno" on public.alunos for update to authenticated
  using (personal_id = (select auth.uid()) and (select public.eh_personal()))
  with check (personal_id = (select auth.uid()) and (select public.eh_personal()));
drop policy if exists "personal apaga aluno" on public.alunos;
create policy "personal apaga aluno" on public.alunos for delete to authenticated
  using (personal_id = (select auth.uid()) and (select public.eh_personal()));

-- ---------------------------------------------------------------------------
-- Painel do administrador
-- ---------------------------------------------------------------------------
create or replace function public.admin_painel() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if not eh_admin() then raise exception 'Acesso só para o administrador'; end if;
  return jsonb_build_object('gerado_em', now(), 'personais', coalesce((
    select jsonb_agg(x order by lower(x ->> 'nome')) from (
      select jsonb_build_object(
        'email', b.email,
        'nome', coalesce(nullif(trim(b.nome_conta), ''), nullif(trim(b.nome_conv), ''), split_part(b.email, '@', 1)),
        'status', case when b.id is null then 'pendente' when b.ativo and b.papel = 'personal' then 'ativo' else 'bloqueado' end,
        'desde', coalesce(b.conta_em, b.conv_em),
        'alunos', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', a.id, 'nome', a.nome, 'objetivo', a.objetivo, 'ativo', a.ativo,
                   'ligado', a.user_id is not null, 'proprio', coalesce(a.user_id = a.personal_id, false),
                   'ultimo', (select max(s.data) from sessoes s where s.aluno_id = a.id),
                   'semana', (select count(*) from sessoes s where s.aluno_id = a.id and s.data > hoje - 7),
                   'mes', (select count(*) from sessoes s where s.aluno_id = a.id and s.data > hoje - 30),
                   'avaliacao', (select max(v.data) from avaliacoes v where v.aluno_id = a.id),
                   'criado_em', a.criado_em)
                 order by lower(a.nome))
            from alunos a where b.id is not null and a.personal_id = b.id), '[]'::jsonb)
      ) as x
      from (
        select p.email, p.nome as nome_conv, p.ativo, p.criado_em as conv_em,
               pr.id, pr.nome as nome_conta, pr.papel, pr.criado_em as conta_em
          from personais p
          left join profiles pr on lower(pr.email) = p.email and pr.papel <> 'admin'
        union all
        select lower(pr.email), null, true, null, pr.id, pr.nome, pr.papel, pr.criado_em
          from profiles pr
         where pr.papel = 'personal' and not exists (select 1 from personais p where p.email = lower(pr.email))
      ) b
    ) t), '[]'::jsonb));
end $$;

create or replace function public.admin_add_personal(p_email text, p_nome text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e text := lower(trim(coalesce(p_email, '')));
  n text := nullif(trim(coalesce(p_nome, '')), '');
begin
  if not eh_admin() then raise exception 'Acesso só para o administrador'; end if;
  if e !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(e) > 200 then raise exception 'E-mail inválido'; end if;
  if exists (select 1 from admins where email = e) then raise exception 'Este e-mail é da conta de administrador'; end if;
  if length(n) > 120 then raise exception 'Nome muito longo'; end if;
  insert into personais (email, nome, ativo, criado_por) values (e, n, true, auth.uid())
  on conflict (email) do update set nome = coalesce(excluded.nome, personais.nome), ativo = true;
  update profiles set papel = 'personal' where lower(email) = e and papel = 'aluno';
  return jsonb_build_object('email', e, 'conta', exists (select 1 from profiles where lower(email) = e));
end $$;

create or replace function public.admin_status_personal(p_email text, p_ativo boolean) returns void
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email, '')));
begin
  if not eh_admin() then raise exception 'Acesso só para o administrador'; end if;
  insert into personais (email, ativo, criado_por)
    select e, p_ativo, auth.uid() where exists (select 1 from profiles where lower(email) = e and papel = 'personal')
  on conflict (email) do nothing;
  update personais set ativo = p_ativo where email = e;
  if not found then raise exception 'Personal não encontrado'; end if;
  update profiles set papel = case when p_ativo then 'personal' else 'aluno' end
   where lower(email) = e and papel <> 'admin';
end $$;

create or replace function public.admin_remover_convite(p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email, '')));
begin
  if not eh_admin() then raise exception 'Acesso só para o administrador'; end if;
  if exists (select 1 from profiles where lower(email) = e) then
    raise exception 'Esta pessoa já criou a conta. Use "Bloquear acesso".';
  end if;
  delete from personais where email = e;
end $$;

revoke all on function public.admin_painel() from public, anon;
revoke all on function public.admin_add_personal(text, text) from public, anon;
revoke all on function public.admin_status_personal(text, boolean) from public, anon;
revoke all on function public.admin_remover_convite(text) from public, anon;
grant execute on function public.admin_painel() to authenticated;
grant execute on function public.admin_add_personal(text, text) to authenticated;
grant execute on function public.admin_status_personal(text, boolean) to authenticated;
grant execute on function public.admin_remover_convite(text) to authenticated;
