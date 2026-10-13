-- ============================================================
--  청연 문학 되새김 (O·X + 현대어 풀이 등) · Supabase 스키마
--  실행 위치: Supabase 대시보드 → SQL Editor → New query → 붙여넣고 Run
--  reading.sql 을 먼저 실행해 두어야 함 (blank_norm · blank_ok 를 같이 씀)
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
    when p_kind = 'ox' then upper(trim(coalesce(p_answer, ''))) = upper(trim(coalesce(p_item->>'a', '')))
    else (blank_norm(p_answer) <> '' and coalesce(p_accept ->> p_n::text, '') = blank_norm(p_answer))
         or blank_ok(p_answer, '@' || coalesce(p_item->>'kw', ''))
  end;
$$;

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
--   stage 0 안 냄 / 1 처음 냄 (맞고 틀림만) / 2 다시 냄 또는 처음에 다 맞음 (정답·해설 공개)
create or replace function public.get_test_status(p_test_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  t tests%rowtype; v_data jsonb; v_final jsonb; r record;
  v_marks jsonb := '[]'::jsonb; v_keys jsonb := '[]'::jsonb; v_all boolean := true; v_ok boolean; v_stage int;
begin
  select * into t from tests where id = p_test_id and is_open;
  if t.id is null then raise exception '문제를 열 수 없습니다.'; end if;
  select data into v_data from test_entries where test_id = p_test_id and student_name = trim(p_name);
  if v_data is null then return jsonb_build_object('stage', 0); end if;
  v_final := coalesce(v_data->'second', v_data->'first', '[]'::jsonb);
  for r in select * from test_items(t.parts) order by n loop
    v_ok := test_item_ok(r.kind, r.item, v_final ->> r.n, v_data->'accept', r.n);
    v_all := v_all and v_ok;
    v_marks := v_marks || to_jsonb(v_ok);
    v_keys := v_keys || case when r.kind = 'ox'
                then jsonb_build_object('a', r.item->>'a', 'exp', coalesce(r.item->>'exp', ''))
                else jsonb_build_object('model', coalesce(r.item->>'model', ''), 'point', coalesce(r.item->>'point', '')) end;
  end loop;
  v_stage := case when v_data ? 'second' or v_all then 2 else 1 end;
  return jsonb_build_object('stage', v_stage, 'first', coalesce(v_data->'first', '[]'::jsonb), 'second', v_data->'second',
                            'marks', v_marks, 'keys', case when v_stage = 2 then v_keys else null end);
end; $$;

-- ---------- 학생용 RPC: 제출 (처음 → 틀린 문항만 한 번 더) -------------
create or replace function public.submit_test(p_test_id uuid, p_name text, p_answers jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare t tests%rowtype; v_data jsonb; v_second jsonb := '[]'::jsonb; r record;
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
    if v_data ? 'second' then raise exception '이미 두 번 제출했어요.'; end if;
    for r in select * from test_items(t.parts) order by n loop
      if test_item_ok(r.kind, r.item, v_data->'first' ->> r.n, v_data->'accept', r.n) then
        v_second := v_second || to_jsonb(coalesce(v_data->'first' ->> r.n, ''));
      else
        v_second := v_second || to_jsonb(coalesce(p_answers ->> r.n, ''));
      end if;
    end loop;
    update test_entries set data = v_data || jsonb_build_object('second', v_second), updated_at = now()
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
revoke all on function public.set_test_accept(uuid, jsonb)     from public;
grant execute on function public.get_test(uuid)                 to anon, authenticated;
grant execute on function public.get_test_status(uuid, text)    to anon, authenticated;
grant execute on function public.submit_test(uuid, text, jsonb) to anon, authenticated;
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
