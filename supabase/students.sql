-- ============================================================
--  청연국어 학생 명단 · 입장 코드 (2026-10-22)
--  실행 위치: Supabase 대시보드 → SQL Editor → New query → 붙여넣고 Run
--  test.sql 보다 먼저 실행 (다시 실행해도 안전하도록 작성됨)
--
--  선생님이 반과 학생 이름을 넣으면 4자리 입장 코드(1000~9999, 0으로 시작 안 함)가 저절로 정해짐.
--  학생은 이름 + 코드로 한 번 들어오면 그 기기에 열쇠(token)가 남아 다음부터는 바로 들어옴.
--  선생님이 '새 코드'를 누르거나 학생을 지우면 그 학생의 열쇠는 모두 못 쓰게 됨.
--  지금은 청연 되새김이 쓰고, 나중에 청연 독서도 같은 명단을 씀.
-- ============================================================

create extension if not exists "pgcrypto";

create table if not exists public.classes (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 30),
  created_at  timestamptz not null default now()
);

create table if not exists public.students (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  class_id    uuid references public.classes (id) on delete set null,
  name        text not null check (length(trim(name)) between 1 and 30),
  code        text not null check (code ~ '^[1-9][0-9]{3}$'),
  created_at  timestamptz not null default now(),
  unique (owner, name),
  unique (code)
);

-- 학생 기기에 남는 열쇠
create table if not exists public.student_sessions (
  token       uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.students (id) on delete cascade,
  created_at  timestamptz not null default now()
);

-- 틀린 입장 시도 (같은 이름으로 10분에 8번 넘게 틀리면 잠시 막음)
create table if not exists public.student_login_fails (
  id    bigint generated always as identity primary key,
  name  text not null,
  at    timestamptz not null default now()
);

alter table public.classes             enable row level security;
alter table public.students            enable row level security;
alter table public.student_sessions    enable row level security;
alter table public.student_login_fails enable row level security;

drop policy if exists "owner manages classes" on public.classes;
create policy "owner manages classes" on public.classes
  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists "owner manages students" on public.students;
create policy "owner manages students" on public.students
  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
-- student_sessions · student_login_fails 는 정책 없음 = 아래 함수로만 다룸

-- ---------- 입장 코드 만들기 ------------------------------------------
--   1000~9999, 겹치지 않게. 1111 같은 같은 숫자, 1234·4321 같은 이어지는 숫자는 뺌
create or replace function public.new_student_code()
returns text
language plpgsql volatile security definer set search_path = public
as $$
declare c text; i int := 0;
begin
  loop
    c := (1000 + floor(random() * 9000))::int::text;
    i := i + 1;
    if i > 500 then raise exception '입장 코드를 더 만들 수 없어요.'; end if;
    continue when c ~ '^(.)\1{3}$';
    continue when c in ('1234','2345','3456','4567','5678','6789','9876','8765','7654','6543','5432','4321');
    exit when not exists (select 1 from students where code = c);
  end loop;
  return c;
end; $$;

create or replace function public.students_fill()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  new.name := regexp_replace(trim(new.name), '\s+', ' ', 'g');
  if tg_op = 'INSERT' then new.code := new_student_code(); end if;   -- 코드는 늘 서버가 정함
  if tg_op = 'UPDATE' and coalesce(current_setting('cy.code_reset', true), '') <> '1' then
    new.code := old.code;                                              -- 바꾸기는 reset_student_code 로만
  end if;
  return new;
end; $$;

drop trigger if exists students_fill on public.students;
create trigger students_fill before insert or update on public.students
  for each row execute function public.students_fill();

-- ---------- 교사용: 새 코드 (예전 코드와 열쇠는 못 쓰게 됨) --------------
create or replace function public.reset_student_code(p_student_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare c text;
begin
  if not exists (select 1 from students where id = p_student_id and owner = auth.uid()) then
    raise exception '학생을 찾을 수 없습니다.';
  end if;
  c := new_student_code();
  perform set_config('cy.code_reset', '1', true);
  update students set code = c where id = p_student_id;
  perform set_config('cy.code_reset', '', true);
  delete from student_sessions where student_id = p_student_id;
  return c;
end; $$;

-- ---------- 학생용: 들어오기 · 나가기 ------------------------------------
--   이름은 띄어쓰기를 빼고 비교 (김 하늘 = 김하늘)
create or replace function public.student_login(p_name text, p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_key text := regexp_replace(coalesce(p_name, ''), '\s', '', 'g'); s students%rowtype; v_token uuid;
begin
  if v_key = '' or length(v_key) > 30 then raise exception '이름을 입력하세요.'; end if;
  delete from student_login_fails where at < now() - interval '1 day';
  if (select count(*) from student_login_fails where name = v_key and at > now() - interval '10 minutes') >= 8 then
    raise exception '여러 번 틀렸어요. 10분 뒤에 다시 해 보세요.';
  end if;
  select * into s from students
   where regexp_replace(name, '\s', '', 'g') = v_key and code = trim(coalesce(p_code, ''))
   limit 1;
  if s.id is null then
    insert into student_login_fails (name) values (v_key);
    raise exception '이름이나 입장 코드가 맞지 않아요.';
  end if;
  insert into student_sessions (student_id) values (s.id) returning token into v_token;
  return jsonb_build_object('token', v_token, 'name', s.name,
                            'class_name', coalesce((select name from classes where id = s.class_id), ''));
end; $$;

create or replace function public.student_logout(p_token uuid)
returns void
language sql security definer set search_path = public
as $$ delete from student_sessions where token = p_token; $$;

-- 열쇠 → 학생. 열쇠가 없거나 지워졌으면 '다시 들어와 주세요.' (앱은 이 말을 보고 입장 화면으로 돌아감)
create or replace function public.student_from_token(p_token uuid)
returns public.students
language plpgsql stable security definer set search_path = public
as $$
declare s students%rowtype;
begin
  select st.* into s from student_sessions ss join students st on st.id = ss.student_id where ss.token = p_token;
  if s.id is null then raise exception '다시 들어와 주세요.'; end if;
  return s;
end; $$;

revoke all on function public.new_student_code()            from public, anon, authenticated;
revoke all on function public.students_fill()               from public, anon, authenticated;
revoke all on function public.student_from_token(uuid)      from public, anon, authenticated;
revoke all on function public.reset_student_code(uuid)      from public;
revoke all on function public.student_login(text, text)     from public;
revoke all on function public.student_logout(uuid)          from public;
grant execute on function public.reset_student_code(uuid)   to authenticated;
grant execute on function public.student_login(text, text)  to anon, authenticated;
grant execute on function public.student_logout(uuid)       to anon, authenticated;

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.classes  to authenticated;
grant select, insert, update, delete on public.students to authenticated;
