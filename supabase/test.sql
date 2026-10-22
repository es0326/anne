-- ============================================================
--  청연 되새김 (O·X + 현대어 풀이 등) · Supabase 스키마
--  실행 위치: Supabase 대시보드 → SQL Editor → New query → 붙여넣고 Run
--  reading.sql · students.sql 을 먼저 실행해 두어야 함 (blank_norm · blank_ok, 학생 명단을 같이 씀)
--  (다시 실행해도 안전하도록 작성됨)
-- ============================================================

create extension if not exists "pgcrypto";

-- 시험 한 개
--   parts: [{ "type": "ox",    "title": "…", "guide": "…", "items": [{ "q": "…", "a": "O|X", "exp": "해설" }] },
--           { "type": "write", "title": "…", "guide": "…", "items": [{ "q": "…", "model": "모범 풀이", "point": "핵심 포인트",
--                                                                   "kw": "핵심어,핵심어·바꿔쓸말" }] }]
create table if not exists public.tests (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null references auth.users (id) on delete cascade,
  title       text not null default '제목 없는 되새김',
  work        text not null default '',
  author      text not null default '',
  series      text not null default '',
  is_open     boolean not null default true,
  parts       jsonb not null default '[]'::jsonb,
  created_at  timestamptz not null default now()
);

-- 학생 응시 기록. data: { first: [...], second: [...], accept: { "번호": "정규화한 답" } }
--   답 배열은 모든 part 의 문항을 순서대로 이어 붙인 것 (O·X 는 "O"/"X", 풀이는 글)
create table if not exists public.test_entries (
  id           uuid primary key default gen_random_uuid(),
  test_id      uuid not null references public.tests (id) on delete cascade,
  student_name text not null,
  data         jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (test_id, student_name)
);

alter table public.tests        enable row level security;
alter table public.test_entries enable row level security;

drop policy if exists "owner manages tests" on public.tests;
create policy "owner manages tests" on public.tests
  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists "owner reads test entries" on public.test_entries;
create policy "owner reads test entries" on public.test_entries
  for select to authenticated
  using (exists (select 1 from public.tests t where t.id = test_entries.test_id and t.owner = auth.uid()));

drop policy if exists "owner deletes test entries" on public.test_entries;
create policy "owner deletes test entries" on public.test_entries
  for delete to authenticated
  using (exists (select 1 from public.tests t where t.id = test_entries.test_id and t.owner = auth.uid()));

-- ---------- 도우미: 모든 문항을 순서대로 펼치기 ----------------------
--   (type, 문항) 목록. 순서 = part 순서 → 문항 순서
create or replace function public.test_items(p_parts jsonb)
returns table (n int, kind text, item jsonb)
language sql immutable as $$
  select (row_number() over (order by pn, qn))::int - 1, p->>'type', q
    from jsonb_array_elements(coalesce(p_parts, '[]'::jsonb)) with ordinality as pp(p, pn),
         jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) with ordinality as qq(q, qn);
$$;

-- 한 문항 채점. O·X 는 그대로 비교, 풀이는 핵심어(blank_ok) + 선생님 인정
create or replace function public.test_item_ok(p_kind text, p_item jsonb, p_answer text, p_accept jsonb, p_n int)
returns boolean
language sql immutable as $$
  select case
    -- O·X 답은 'O' 또는 'X||고친 문장'. X 문항은 고친 문장의 핵심어(fkw)까지 맞아야 맞음
    when p_kind = 'ox' then
      upper(trim(split_part(coalesce(p_answer, ''), '||', 1))) <> ''
      and upper(trim(split_part(coalesce(p_answer, ''), '||', 1))) = upper(trim(coalesce(p_item->>'a', '')))
      and ( upper(trim(coalesce(p_item->>'a', ''))) <> 'X'
            or trim(coalesce(p_item->>'fkw', '')) = ''
            or (blank_norm(split_part(p_answer, '||', 2)) <> ''
                and coalesce(p_accept ->> p_n::text, '') = blank_norm(split_part(p_answer, '||', 2)))
            or blank_ok(split_part(p_answer, '||', 2), '@' || (p_item->>'fkw')) )
    else (blank_norm(p_answer) <> '' and coalesce(p_accept ->> p_n::text, '') = blank_norm(p_answer))
         or blank_ok(p_answer, '@' || coalesce(p_item->>'kw', ''))
  end;
$$;

-- 틀린 까닭 (2026-10-19): 학생에게 어느 부분이 틀렸는지 알려 주기
--   null 맞음 · 'none' 안 풂 · 'ox' O·X를 잘못 고름 · 'fix' X는 맞고 고쳐 쓴 부분이 틀림 · 'write' 풀이가 틀림
create or replace function public.test_item_why(p_kind text, p_item jsonb, p_answer text, p_accept jsonb, p_n int)
returns text
language sql immutable as $$
  select case
    when test_item_ok(p_kind, p_item, p_answer, p_accept, p_n) then null
    when p_kind = 'ox' and trim(split_part(coalesce(p_answer, ''), '||', 1)) = '' then 'none'
    when p_kind = 'ox' and upper(trim(split_part(coalesce(p_answer, ''), '||', 1))) <> upper(trim(coalesce(p_item->>'a', ''))) then 'ox'
    when p_kind = 'ox' then 'fix'
    when blank_norm(p_answer) = '' then 'none'
    else 'write'
  end;
$$;

-- 틀린 문제 다시 풀기: 두 번까지, 한 번에 10분. '다시 풀기 시작'을 누른 때부터 셈
--   data.start = { "1": 첫 번째 다시 풀기 시작 시각, "2": 두 번째 }, data.late = { "1": true } (시간 넘겨 낸 것)
--   시간(+1분 여유)을 넘겨 내면 새 답은 받지 않고 그 전 답으로 끝냄 = '쓴 데까지 자동 제출'을 서버에서도 지킴
create or replace function public.test_retry_minutes() returns int language sql immutable as $$ select 10 $$;

-- ---------- 학생용 RPC: 시험 문제 (정답·해설·핵심어 제외) -------------
create or replace function public.get_test(p_test_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare t tests%rowtype; v_parts jsonb;
begin
  select * into t from tests where id = p_test_id;
  if t.id is null then raise exception '문제를 찾을 수 없습니다.'; end if;
  if not t.is_open then raise exception '선생님이 아직 열지 않은 문제입니다.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'type', p->>'type', 'title', coalesce(p->>'title', ''), 'guide', coalesce(p->>'guide', ''),
           'items', (select coalesce(jsonb_agg(jsonb_build_object('q', q->>'q') order by qn), '[]'::jsonb)
                       from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) with ordinality as qq(q, qn))
         ) order by pn), '[]'::jsonb)
    into v_parts
    from jsonb_array_elements(t.parts) with ordinality as pp(p, pn);
  return jsonb_build_object('title', t.title, 'work', t.work, 'author', t.author, 'series', t.series, 'parts', v_parts);
end; $$;

-- ---------- 학생용 RPC: 상태 ----------------------------------------
--   stage 0 안 냄 / 1 틀린 문제 다시 푸는 중 (맞고 틀림 + 틀린 까닭, retry = 몇 번째 다시 풀기)
--   2 두 번 다시 냄 또는 다 맞음 (정답·해설 공개)
create or replace function public.get_test_status(p_test_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  t tests%rowtype; v_data jsonb; v_final jsonb; r record;
  v_marks jsonb := '[]'::jsonb; v_why jsonb := '[]'::jsonb; v_keys jsonb := '[]'::jsonb; v_all boolean := true; v_ok boolean; v_stage int;
  v_retry text; v_start timestamptz;
begin
  select * into t from tests where id = p_test_id and is_open;
  if t.id is null then raise exception '문제를 열 수 없습니다.'; end if;
  select data into v_data from test_entries where test_id = p_test_id and student_name = trim(p_name);
  if v_data is null then return jsonb_build_object('stage', 0); end if;
  v_final := coalesce(v_data->'third', v_data->'second', v_data->'first', '[]'::jsonb);
  for r in select * from test_items(t.parts) order by n loop
    v_ok := test_item_ok(r.kind, r.item, v_final ->> r.n, v_data->'accept', r.n);
    v_all := v_all and v_ok;
    v_marks := v_marks || to_jsonb(v_ok);
    v_why := v_why || coalesce(to_jsonb(test_item_why(r.kind, r.item, v_final ->> r.n, v_data->'accept', r.n)), 'null'::jsonb);
    v_keys := v_keys || case when r.kind = 'ox'
                then jsonb_build_object('a', r.item->>'a', 'exp', coalesce(r.item->>'exp', ''), 'fix', coalesce(r.item->>'fix', ''))
                else jsonb_build_object('model', coalesce(r.item->>'model', ''), 'point', coalesce(r.item->>'point', '')) end;
  end loop;
  v_stage := case when v_data ? 'third' or v_all then 2 else 1 end;
  v_retry := case when v_data ? 'second' then '2' else '1' end;
  v_start := (v_data->'start'->>v_retry)::timestamptz;
  return jsonb_build_object('stage', v_stage, 'first', coalesce(v_data->'first', '[]'::jsonb), 'second', v_data->'second', 'third', v_data->'third',
                            'marks', v_marks, 'why', v_why, 'retry', v_retry::int, 'late', coalesce(v_data->'late', '{}'::jsonb),
                            'limit_min', test_retry_minutes(), 'server_now', now(),
                            'deadline', case when v_stage = 1 and v_start is not null then v_start + make_interval(mins => test_retry_minutes()) else null end,
                            'keys', case when v_stage = 2 then v_keys else null end);
end; $$;

-- ---------- 학생용 RPC: 다시 풀기 시작 (10분 재기 시작) ------------------
create or replace function public.start_test_retry(p_test_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_data jsonb; v_retry text;
begin
  select data into v_data from test_entries where test_id = p_test_id and student_name = trim(p_name);
  if v_data is null or v_data ? 'third' then return get_test_status(p_test_id, p_name); end if;
  v_retry := case when v_data ? 'second' then '2' else '1' end;
  if (v_data->'start'->>v_retry) is null then
    update test_entries
       set data = data || jsonb_build_object('start', coalesce(data->'start', '{}'::jsonb) || jsonb_build_object(v_retry, now()))
     where test_id = p_test_id and student_name = trim(p_name);
  end if;
  return get_test_status(p_test_id, p_name);
end; $$;

-- ---------- 학생용 RPC: 제출 (처음 → 틀린 문항만 다시, 두 번까지) -------------
create or replace function public.submit_test(p_test_id uuid, p_name text, p_answers jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare t tests%rowtype; v_data jsonb; v_prev jsonb; v_next jsonb := '[]'::jsonb; r record;
        v_retry text; v_start timestamptz; v_late boolean;
begin
  select * into t from tests where id = p_test_id and is_open;
  if t.id is null then raise exception '선생님이 닫은 문제입니다.'; end if;
  if coalesce(length(trim(p_name)), 0) = 0 then raise exception '이름을 입력하세요.'; end if;
  if length(trim(p_name)) > 40 then raise exception '이름이 너무 깁니다.'; end if;
  if jsonb_typeof(p_answers) is distinct from 'array' then raise exception '답이 올바르지 않습니다.'; end if;
  if length(p_answers::text) > 30000 then raise exception '글이 너무 깁니다.'; end if;
  select data into v_data from test_entries where test_id = p_test_id and student_name = trim(p_name);
  if v_data is null then
    insert into test_entries (test_id, student_name, data) values (p_test_id, trim(p_name), jsonb_build_object('first', p_answers));
  else
    if v_data ? 'third' then raise exception '이미 세 번 제출했어요.'; end if;
    v_retry := case when v_data ? 'second' then '2' else '1' end;
    v_prev  := coalesce(v_data->'second', v_data->'first', '[]'::jsonb);
    v_start := (v_data->'start'->>v_retry)::timestamptz;
    v_late  := v_start is not null and now() > v_start + make_interval(mins => test_retry_minutes() + 1);
    for r in select * from test_items(t.parts) order by n loop
      if v_late or test_item_ok(r.kind, r.item, v_prev ->> r.n, v_data->'accept', r.n) then
        v_next := v_next || to_jsonb(coalesce(v_prev ->> r.n, ''));
      else
        v_next := v_next || to_jsonb(coalesce(p_answers ->> r.n, ''));
      end if;
    end loop;
    update test_entries
       set data = v_data || jsonb_build_object(case when v_data ? 'second' then 'third' else 'second' end, v_next)
                         || case when v_late then jsonb_build_object('late', coalesce(v_data->'late', '{}'::jsonb) || jsonb_build_object(v_retry, true)) else '{}'::jsonb end,
           updated_at = now()
     where test_id = p_test_id and student_name = trim(p_name);
  end if;
  return get_test_status(p_test_id, p_name);
end; $$;

-- ---------- 교사용 RPC: 풀이 답 "인정" ----------------------------------
create or replace function public.set_test_accept(p_entry_id uuid, p_accept jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if jsonb_typeof(p_accept) is distinct from 'object' then raise exception '형식이 올바르지 않습니다.'; end if;
  update test_entries e set data = jsonb_set(e.data, '{accept}', p_accept, true)
   where e.id = p_entry_id and exists (select 1 from tests t where t.id = e.test_id and t.owner = auth.uid());
  if not found then raise exception '기록을 찾을 수 없습니다.'; end if;
end; $$;

revoke all on function public.get_test(uuid)                   from public;
revoke all on function public.get_test_status(uuid, text)      from public;
revoke all on function public.submit_test(uuid, text, jsonb)   from public;
revoke all on function public.start_test_retry(uuid, text)     from public;
revoke execute on function public.start_test_retry(uuid, text)  from anon, authenticated;   -- 2026-10-22: 이름만으로는 못 들어옴 (아래 st_ 함수로만)
revoke all on function public.set_test_accept(uuid, jsonb)     from public;
revoke execute on function public.get_test(uuid)                 from anon, authenticated;
revoke execute on function public.get_test_status(uuid, text)    from anon, authenticated;
revoke execute on function public.submit_test(uuid, text, jsonb) from anon, authenticated;
grant execute on function public.set_test_accept(uuid, jsonb)   to authenticated;

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.tests to authenticated;
grant select, delete on public.test_entries to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'test_entries') then
    execute 'alter publication supabase_realtime add table public.test_entries';
  end if;
end $$;

-- ============================================================
--  2026-10-22 · 우리 학생만: 이름 + 입장 코드 (students.sql)
--   학생 링크 + 이름만으로는 더 이상 못 들어옴. 학생은 '내 숙제' 목록에서 고름
--   tests.class_ids = 이 작품을 연 반들. 비어 있으면 아무 학생에게도 안 보임
-- ============================================================
alter table public.tests add column if not exists class_ids uuid[] not null default '{}';

-- 열쇠 + 작품 → 학생 이름 (그 학생 반에 열린 작품이어야 함)
create or replace function public.st_name_for(p_token uuid, p_test_id uuid)
returns text
language plpgsql stable security definer set search_path = public
as $$
declare s students%rowtype;
begin
  s := student_from_token(p_token);
  if not exists (select 1 from tests t where t.id = p_test_id and t.owner = s.owner and t.is_open
                    and s.class_id is not null and s.class_id = any(t.class_ids)) then
    raise exception '선생님이 아직 열지 않은 문제입니다.';
  end if;
  return s.name;
end; $$;

-- 내 숙제: 내 반에 열린 작품 + 어디까지 했는지 (stage 0 안 냄 · 1 다시 풀기 남음 · 2 끝)
create or replace function public.st_tests(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare s students%rowtype; v_list jsonb := '[]'::jsonb; r record;
begin
  s := student_from_token(p_token);
  for r in select t.id, t.title, t.work, t.author, t.series from tests t
            where t.owner = s.owner and t.is_open and s.class_id is not null and s.class_id = any(t.class_ids)
            order by t.created_at desc loop
    v_list := v_list || jsonb_build_object('id', r.id, 'title', r.title, 'work', r.work, 'author', r.author, 'series', r.series,
                                           'stage', (get_test_status(r.id, s.name)->>'stage')::int);
  end loop;
  return jsonb_build_object('name', s.name, 'class_name', coalesce((select name from classes where id = s.class_id), ''), 'tests', v_list);
end; $$;

create or replace function public.st_get_test(p_token uuid, p_test_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$ begin perform st_name_for(p_token, p_test_id); return get_test(p_test_id); end; $$;

create or replace function public.st_status(p_token uuid, p_test_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$ begin return get_test_status(p_test_id, st_name_for(p_token, p_test_id)); end; $$;

create or replace function public.st_start_retry(p_token uuid, p_test_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$ begin return start_test_retry(p_test_id, st_name_for(p_token, p_test_id)); end; $$;

create or replace function public.st_submit(p_token uuid, p_test_id uuid, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$ begin return submit_test(p_test_id, st_name_for(p_token, p_test_id), p_answers); end; $$;

revoke all on function public.st_name_for(uuid, uuid)            from public, anon, authenticated;
revoke all on function public.st_tests(uuid)                     from public;
revoke all on function public.st_get_test(uuid, uuid)            from public;
revoke all on function public.st_status(uuid, uuid)              from public;
revoke all on function public.st_start_retry(uuid, uuid)         from public;
revoke all on function public.st_submit(uuid, uuid, jsonb)       from public;
grant execute on function public.st_tests(uuid)                  to anon, authenticated;
grant execute on function public.st_get_test(uuid, uuid)         to anon, authenticated;
grant execute on function public.st_status(uuid, uuid)           to anon, authenticated;
grant execute on function public.st_start_retry(uuid, uuid)      to anon, authenticated;
grant execute on function public.st_submit(uuid, uuid, jsonb)    to anon, authenticated;
