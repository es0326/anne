-- ============================================================
--  독서 기록 (책갈피 · 내용 이해 빈칸 · 생각하기 보강) · Supabase 스키마
--  실행 위치: Supabase 대시보드 → SQL Editor → New query → 붙여넣고 Run
--  품사 시험지(schema.sql)와 같은 프로젝트에 추가로 한 번만 실행하면 됩니다.
--  (다시 실행해도 안전하도록 작성됨)
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- 테이블 ----------------------------------------------------
-- 책 한 권 = 수업 단위. 주차(sections) → 박스(boxes) → 생각하기 문제(questions)
--   sections: [{ "title": "1주차", "range": "읽을 범위",
--                "boxes": [{ "heading": "아버지를 버리고",
--                            "text": "줄거리. 빈칸은 [정답] 처럼 대괄호로 (여러 답은 [답1|답2])",
--                            "questions": [{ "prompt": "① …", "model": "예시 답안(교사만)" }] }] }]
create table if not exists public.books (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null references auth.users (id) on delete cascade,
  title       text not null default '제목 없는 책',
  author      text not null default '',
  grade       text not null default '',
  is_open     boolean not null default true,          -- false 면 학생 화면 닫힘
  sections    jsonb not null default '[]'::jsonb,
  created_at  timestamptz not null default now()
);

-- 학생 기록. 학생·주차·종류마다 한 줄
--   kind = 'bookmark' → data: { sentence, page, why, topic }      (다시 저장 가능)
--   kind = 'blanks'   → data: { first: [...], second: [...], third: [...] }  주차 안 빈칸 순서
--                       (처음 제출 → 틀린 칸만 두 번까지 다시. 처음 답이 그대로 남음)
--   kind = 'answers'  → data: { answers: ["…", …] }  주차 안 생각하기 순서 (결석 보강용, 다시 저장 가능)
create table if not exists public.entries (
  id           uuid primary key default gen_random_uuid(),
  book_id      uuid not null references public.books (id) on delete cascade,
  section      int  not null,
  kind         text not null,
  student_name text not null,
  data         jsonb not null default '{}'::jsonb,
  feedback     text not null default '',               -- 선생님 한마디
  checked      boolean not null default false,         -- 선생님 확인 완료
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (book_id, section, kind, student_name)
);
create index if not exists entries_book_idx on public.entries (book_id, section);

-- 반 (2026-10-19): 같은 책을 여러 반에 내줄 때. 반마다 학생 링크(?class=)와 제출 마감이 따로
--   books.classes: [{ "id": "c1a2b", "name": "목요일반" }]
--   sections[].dues: { "c1a2b": "2026-10-21" }  (반이 없으면 sections[].due 하나)
--   entries.class_id: 학생이 어느 반 링크로 냈는지 ('' = 반 없음)
alter table public.books   add column if not exists classes  jsonb not null default '[]'::jsonb;
alter table public.entries add column if not exists class_id text  not null default '';

-- 종류 제약 (이전 버전에서 넘어와도 맞도록 다시 만듦)
alter table public.entries drop constraint if exists entries_kind_check;
alter table public.entries add constraint entries_kind_check check (kind in ('bookmark', 'blanks', 'answers', 'quiz'));

-- 독서 퀴즈 (2026-11-26): 회차(sections[])마다 quiz 목록. 객관식은 보기를 고르고, 단답은 짧게 씀
--   sections[].quiz: [{ "q": "복서가 되풀이한 말은?", "choices": ["…", "…"], "key": "5" },     ← 객관식: key = 정답 보기 번호(1부터)
--                     { "q": "『동물농장』을 쓴 작가는?", "key": "조지 오웰@오웰" }]           ← 단답: key = 빈칸과 같은 규칙
--   entries kind = 'quiz' → data: { answers: ["5", "조지 오웰", …] }  한 번만 냄. 내면 바로 점수와 틀린 문제의 정답을 봄

-- 이전 시험판의 "나도 궁금해" 기능은 없앰 (친구 질문은 수업 시간에 처음 듣기)
drop function if exists public.get_topics(uuid, int, text);
drop function if exists public.toggle_vote(uuid, text);
drop table if exists public.votes;

-- ---------- Row Level Security -------------------------------------
alter table public.books   enable row level security;
alter table public.entries enable row level security;

-- books: 정답·예시 답안이 들어 있으므로 주인만 직접 접근. 학생은 RPC 사용
drop policy if exists "owner manages books" on public.books;
create policy "owner manages books" on public.books
  for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

-- entries: 책 주인만 조회·피드백 수정·삭제(다시 풀게 하기). 학생 기록은 RPC 로만
drop policy if exists "owner reads entries" on public.entries;
create policy "owner reads entries" on public.entries
  for select to authenticated
  using (exists (select 1 from public.books b where b.id = entries.book_id and b.owner = auth.uid()));

drop policy if exists "owner updates entries" on public.entries;
create policy "owner updates entries" on public.entries
  for update to authenticated
  using (exists (select 1 from public.books b where b.id = entries.book_id and b.owner = auth.uid()))
  with check (exists (select 1 from public.books b where b.id = entries.book_id and b.owner = auth.uid()));

drop policy if exists "owner deletes entries" on public.entries;
create policy "owner deletes entries" on public.entries
  for delete to authenticated
  using (exists (select 1 from public.books b where b.id = entries.book_id and b.owner = auth.uid()));

-- ---------- 2026-11-26 · 청연국어 학생 명단으로 열기 (students.sql 먼저) ----------
--   books.classes 에 학생 명단의 반(classes.id)을 넣으면 '명단 반'. 그 반 학생만 청연국어 앱 「내 숙제」에서 열림(입장 코드).
--   명단 반이 하나라도 있는 책은 예전 이름 링크(?book=)로는 안 열림. 명단 반이 없는 예전 책은 지금처럼 링크로 열림.
--   아래 st_r_* 함수가 열쇠(token)로 학생을 확인하고 cy.rst = '1' 을 켠 뒤 예전 함수를 부름.
create or replace function public.reading_link_ok(p_book_id uuid)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare v_owner uuid; v_cls jsonb;
begin
  if coalesce(current_setting('cy.rst', true), '') = '1' then return true; end if;
  select owner, classes into v_owner, v_cls from books where id = p_book_id;
  if v_owner is null or v_owner = auth.uid() then return true; end if;
  if to_regclass('public.classes') is not null and exists (
       select 1 from jsonb_array_elements(coalesce(v_cls, '[]'::jsonb)) c
         join public.classes k on k.id::text = c->>'id' and k.owner = v_owner) then
    raise exception '이 책은 청연국어 앱 「내 숙제」에서 열어요. 이름과 입장 코드로 들어와 주세요.';
  end if;
  return true;
end; $$;
revoke all on function public.reading_link_ok(uuid) from public, anon, authenticated;

-- ---------- 학생용 RPC: 책 정보 (빈칸 정답 · 예시 답안 제외) ----------
--   줄거리의 [정답] 은 [] 로 바뀌어 전달됨
create or replace function public.get_book(p_book_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b books%rowtype;
  v_sections jsonb;
begin
  select * into b from books where id = p_book_id;
  if b.id is null then raise exception '책을 찾을 수 없습니다.'; end if;
  if not b.is_open then raise exception '선생님이 아직 열지 않은 책입니다.'; end if;
  perform reading_link_ok(p_book_id);

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'title', coalesce(s->>'title', ''),
             'range', coalesce(s->>'range', ''),
             'due',   coalesce(s->>'due', ''),        -- 제출 마감 (YYYY-MM-DD)
             'dues',  coalesce(s->'dues', '{}'::jsonb), -- 반별 제출 마감
             'boxes', (
               select coalesce(jsonb_agg(
                        jsonb_build_object(
                          'heading', coalesce(x->>'heading', ''),
                          -- [정답] → [] , [+긴 정답] → [+]  (정답은 학생에게 가지 않음)
                          'text', regexp_replace(
                                    regexp_replace(coalesce(x->>'text', ''), '\[[^]+][^]]*\]', '[]', 'g'),
                                    '\[\+[^]]+\]', '[+]', 'g'),
                          'questions', (
                            select coalesce(jsonb_agg(jsonb_build_object('prompt', q->>'prompt') order by qn), '[]'::jsonb)
                              from jsonb_array_elements(coalesce(x->'questions', '[]'::jsonb)) with ordinality as qq(q, qn))
                        ) order by xn), '[]'::jsonb)
                 from jsonb_array_elements(coalesce(s->'boxes', '[]'::jsonb)) with ordinality as xx(x, xn)),
             -- 독서 퀴즈: 문제와 보기만 (정답 key 는 학생에게 가지 않음)
             'quiz', (
               select coalesce(jsonb_agg(jsonb_build_object('q', coalesce(z->>'q', ''), 'choices', coalesce(z->'choices', '[]'::jsonb)) order by zn), '[]'::jsonb)
                 from jsonb_array_elements(coalesce(s->'quiz', '[]'::jsonb)) with ordinality as zz(z, zn))
           ) order by sn), '[]'::jsonb)
    into v_sections
    from jsonb_array_elements(b.sections) with ordinality as ss(s, sn);

  return jsonb_build_object('title', b.title, 'author', b.author, 'grade', b.grade, 'sections', v_sections,
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('id', c->>'id', 'name', c->>'name') order by cn), '[]'::jsonb)
                  from jsonb_array_elements(coalesce(b.classes, '[]'::jsonb)) with ordinality as cc(c, cn)));
end;
$$;

-- ---------- 학생용 RPC: 기록 저장 ----------------------------------
--   책갈피·생각하기용. 빈칸(blanks)은 아래 submit_blanks 로만 냄. p_class = 반 링크의 반 id
drop function if exists public.submit_entry(uuid, int, text, text, jsonb);
create or replace function public.submit_entry(
  p_book_id uuid, p_section int, p_kind text, p_name text, p_data jsonb, p_class text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open boolean;
  v_n    int;
  v_id   uuid;
begin
  perform reading_link_ok(p_book_id);
  select is_open, jsonb_array_length(sections) into v_open, v_n from books where id = p_book_id;
  if v_open is null then raise exception '책을 찾을 수 없습니다.'; end if;
  if not v_open then raise exception '선생님이 닫은 책입니다.'; end if;
  if p_section is null or p_section < 0 or p_section >= v_n then raise exception '주차가 올바르지 않습니다.'; end if;
  if p_kind not in ('bookmark', 'answers') then raise exception '종류가 올바르지 않습니다.'; end if;
  if coalesce(length(trim(p_name)), 0) = 0 then raise exception '이름을 입력하세요.'; end if;
  if length(trim(p_name)) > 40 then raise exception '이름이 너무 깁니다.'; end if;
  if length(coalesce(p_data, '{}'::jsonb)::text) > 20000 then raise exception '글이 너무 깁니다.'; end if;

  insert into entries (book_id, section, kind, student_name, data, class_id)
  values (p_book_id, p_section, p_kind, trim(p_name), coalesce(p_data, '{}'::jsonb), left(coalesce(trim(p_class), ''), 40))
  on conflict (book_id, section, kind, student_name)
  do update set data = excluded.data, updated_at = now(), checked = false,
                class_id = case when excluded.class_id <> '' then excluded.class_id else entries.class_id end
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end;
$$;

-- ---------- 학생용 RPC: 내 기록 + 선생님 한마디 ----------------------
create or replace function public.get_my_entries(p_book_id uuid, p_name text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'section', section, 'kind', kind, 'data', data,
           'feedback', feedback, 'checked', checked, 'updated_at', updated_at)), '[]'::jsonb)
    from entries
   where book_id = p_book_id and student_name = trim(p_name)
     and exists (select 1 from books b where b.id = p_book_id and b.is_open)
     and reading_link_ok(p_book_id);
$$;

-- ---------- 빈칸 채점 도우미 (앱의 grade() 와 같은 규칙) -------------
--   정답 형식: [정답] · [정답|다른 정답] · [정답@핵심어,핵심어·바꿔쓸말]
--   @ 핵심어가 있으면: 쉼표로 나눈 묶음마다 가운뎃점으로 나눈 말 중 하나가 답에 들어 있으면 맞음
--   없으면: 띄어쓰기·문장부호를 빼고 같거나, 정답을 품거나, 정답의 60% 이상을 맞게 쓰면 맞음
drop function if exists public.get_blank_key(uuid, int, text);

create or replace function public.blank_norm(s text) returns text
language sql immutable as $$
  select regexp_replace(coalesce(s, ''), '[[:space:].,·…‘’“”''"!?~()-]', '', 'g');
$$;

-- '정답@' 처럼 @ 뒤가 비면 핵심어 그룹이 없으므로(빈 배열) 무엇이든 쓰면 맞음 = '내 생각' 칸 (reading.html grade 와 같음)
create or replace function public.blank_ok(p_answer text, p_key text) returns boolean
language sql immutable as $$
  select blank_norm(p_answer) <> '' and case
    when strpos(coalesce(p_key, ''), '@') > 0 then not exists (
      select 1 from unnest(string_to_array(split_part(p_key, '@', 2), ',')) as g(grp)
       where not exists (
         select 1 from unnest(string_to_array(g.grp, '·')) as a(alt)
          where blank_norm(a.alt) <> '' and strpos(blank_norm(p_answer), blank_norm(a.alt)) > 0))
    else exists (
      select 1 from unnest(string_to_array(coalesce(p_key, ''), '|')) as k(v)
       where blank_norm(k.v) <> ''
         and (blank_norm(p_answer) = blank_norm(k.v)
              or strpos(blank_norm(p_answer), blank_norm(k.v)) > 0
              or (strpos(blank_norm(k.v), blank_norm(p_answer)) > 0
                  and length(blank_norm(p_answer)) >= ceil(length(blank_norm(k.v)) * 0.6))))
  end;
$$;

-- 선생님이 "인정"한 답까지 포함한 채점. accept = { "빈칸번호(0부터)": "정규화한 답" }
create or replace function public.blank_ok_acc(p_answer text, p_key text, p_accept jsonb, p_idx int) returns boolean
language sql immutable as $$
  select (blank_norm(p_answer) <> '' and coalesce(p_accept ->> p_idx::text, '') = blank_norm(p_answer))
         or blank_ok(p_answer, p_key);
$$;

-- 주차 안 빈칸 정답 목록 (줄거리 순서)
create or replace function public.section_keys(p_sections jsonb, p_section int) returns text[]
language sql immutable as $$
  select coalesce(array_agg(ltrim(m[1], '+') order by xn, mn), '{}')
    from jsonb_array_elements(coalesce(p_sections -> p_section -> 'boxes', '[]'::jsonb)) with ordinality as xx(x, xn),
         lateral regexp_matches(coalesce(x->>'text', ''), '\[([^]]+)\]', 'g') with ordinality as mm(m, mn);
$$;

-- ---------- 학생용 RPC: 빈칸 상태 -----------------------------------
--   stage 0 = 아직 안 냄 / 1 = 틀린 칸 다시 쓰는 중 (맞고 틀림만, 정답 없음, retry = 몇 번째 다시 쓰기)
--   2 = 두 번 다시 냄 (그래도 틀린 칸만 정답)
--   처음에 모두 맞으면 바로 stage 2
create or replace function public.get_blank_status(p_book_id uuid, p_section int, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sections jsonb;
  v_keys     text[];
  v_data     jsonb;
  v_final    jsonb;
  v_marks    jsonb := '[]'::jsonb;
  v_show     jsonb := '[]'::jsonb;
  v_ok       boolean;
  v_all      boolean := true;
  v_stage    int;
  i          int;
begin
  perform reading_link_ok(p_book_id);
  select sections into v_sections from books where id = p_book_id and is_open;
  if v_sections is null then raise exception '책을 열 수 없습니다.'; end if;
  select data into v_data from entries
   where book_id = p_book_id and section = p_section and kind = 'blanks' and student_name = trim(p_name);
  if v_data is null then return jsonb_build_object('stage', 0); end if;

  v_keys  := section_keys(v_sections, p_section);
  v_final := coalesce(v_data->'third', v_data->'second', v_data->'first', '[]'::jsonb);
  for i in 1 .. coalesce(array_length(v_keys, 1), 0) loop
    v_ok := blank_ok_acc(v_final ->> (i - 1), v_keys[i], v_data->'accept', i - 1);
    v_all := v_all and v_ok;
    v_marks := v_marks || to_jsonb(v_ok);
    v_show  := v_show  || case when v_ok then 'null'::jsonb else to_jsonb(split_part(split_part(v_keys[i], '@', 1), '|', 1)) end;
  end loop;

  v_stage := case when v_data ? 'third' or v_all then 2 else 1 end;
  return jsonb_build_object(
    'stage',  v_stage,
    'first',  coalesce(v_data->'first', '[]'::jsonb),
    'second', v_data->'second',
    'third',  v_data->'third',
    'retry',  case when v_data ? 'second' then 2 else 1 end,
    'marks',  v_marks,
    'keys',   case when v_stage = 2 then v_show else null end);
end;
$$;

-- ---------- 학생용 RPC: 빈칸 제출 (처음 → 틀린 칸만 다시, 두 번까지) ---------
--   다시 낼 때는 앞에서 맞은 칸은 그대로 두고 틀린 칸만 바뀜 (second → third)
drop function if exists public.submit_blanks(uuid, int, text, jsonb);
create or replace function public.submit_blanks(p_book_id uuid, p_section int, p_name text, p_answers jsonb, p_class text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sections jsonb;
  v_keys     text[];
  v_data     jsonb;
  v_prev     jsonb;
  v_next     jsonb := '[]'::jsonb;
  i          int;
begin
  perform reading_link_ok(p_book_id);
  select sections into v_sections from books where id = p_book_id and is_open;
  if v_sections is null then raise exception '선생님이 닫은 책입니다.'; end if;
  if p_section is null or p_section < 0 or p_section >= jsonb_array_length(v_sections) then raise exception '주차가 올바르지 않습니다.'; end if;
  if coalesce(length(trim(p_name)), 0) = 0 then raise exception '이름을 입력하세요.'; end if;
  if length(trim(p_name)) > 40 then raise exception '이름이 너무 깁니다.'; end if;
  if jsonb_typeof(p_answers) is distinct from 'array' then raise exception '답이 올바르지 않습니다.'; end if;
  if length(p_answers::text) > 20000 then raise exception '글이 너무 깁니다.'; end if;

  v_keys := section_keys(v_sections, p_section);
  select data into v_data from entries
   where book_id = p_book_id and section = p_section and kind = 'blanks' and student_name = trim(p_name);

  if v_data is null then
    insert into entries (book_id, section, kind, student_name, data, class_id)
    values (p_book_id, p_section, 'blanks', trim(p_name), jsonb_build_object('first', p_answers), left(coalesce(trim(p_class), ''), 40));
  else
    if v_data ? 'third' then raise exception '이미 세 번 제출했어요.'; end if;
    v_prev := coalesce(v_data->'second', v_data->'first', '[]'::jsonb);
    for i in 1 .. coalesce(array_length(v_keys, 1), 0) loop
      if blank_ok_acc(v_prev ->> (i - 1), v_keys[i], v_data->'accept', i - 1) then
        v_next := v_next || to_jsonb(coalesce(v_prev ->> (i - 1), ''));
      else
        v_next := v_next || to_jsonb(coalesce(p_answers ->> (i - 1), ''));
      end if;
    end loop;
    update entries set data = v_data || jsonb_build_object(case when v_data ? 'second' then 'third' else 'second' end, v_next),
           updated_at = now(), checked = false
     where book_id = p_book_id and section = p_section and kind = 'blanks' and student_name = trim(p_name);
  end if;

  return get_blank_status(p_book_id, p_section, p_name);
end;
$$;

-- ---------- 교사용 RPC: 빈칸 답 "인정" 저장 ---------------------------
--   학생 답(first/second)은 건드리지 않고 accept 만 바꿈. 책 주인만 가능
create or replace function public.set_blank_accept(p_entry_id uuid, p_accept jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if jsonb_typeof(p_accept) is distinct from 'object' then raise exception '형식이 올바르지 않습니다.'; end if;
  update entries e set data = jsonb_set(e.data, '{accept}', p_accept, true)
   where e.id = p_entry_id and e.kind = 'blanks'
     and exists (select 1 from books b where b.id = e.book_id and b.owner = auth.uid());
  if not found then raise exception '기록을 찾을 수 없습니다.'; end if;
end;
$$;
revoke all on function public.set_blank_accept(uuid, jsonb) from public;
grant execute on function public.set_blank_accept(uuid, jsonb) to authenticated;

-- ---------- 독서 퀴즈 (2026-11-26) -----------------------------------
--   한 문제 채점: 보기가 있으면 고른 번호가 key 와 같아야 맞음, 없으면 빈칸과 같은 규칙(blank_ok) — reading.html quizOk 와 같음
create or replace function public.quiz_ok(p_answer text, p_item jsonb) returns boolean
language sql immutable as $$
  select case
    when jsonb_typeof(p_item->'choices') = 'array' and jsonb_array_length(p_item->'choices') > 0
      then trim(coalesce(p_answer, '')) <> '' and trim(coalesce(p_answer, '')) = trim(coalesce(p_item->>'key', ''))
    else blank_ok(p_answer, coalesce(p_item->>'key', ''))
  end;
$$;

-- 학생용: 냈는지, 냈으면 내 답 · 맞고 틀림 · 틀린 문제의 정답
create or replace function public.get_quiz_status(p_book_id uuid, p_section int, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_quiz  jsonb;
  v_data  jsonb;
  v_marks jsonb := '[]'::jsonb;
  v_show  jsonb := '[]'::jsonb;
  v_ok    boolean;
  i       int;
begin
  perform reading_link_ok(p_book_id);
  select coalesce(sections -> p_section -> 'quiz', '[]'::jsonb) into v_quiz from books where id = p_book_id and is_open;
  if v_quiz is null then raise exception '책을 열 수 없습니다.'; end if;
  select data into v_data from entries
   where book_id = p_book_id and section = p_section and kind = 'quiz' and student_name = trim(p_name);
  if v_data is null then return jsonb_build_object('done', false); end if;
  for i in 0 .. jsonb_array_length(v_quiz) - 1 loop
    v_ok := quiz_ok(v_data->'answers'->>i, v_quiz->i);
    v_marks := v_marks || to_jsonb(v_ok);
    v_show  := v_show  || case when v_ok then 'null'::jsonb else to_jsonb(split_part(split_part(coalesce(v_quiz->i->>'key', ''), '@', 1), '|', 1)) end;
  end loop;
  return jsonb_build_object('done', true, 'answers', coalesce(v_data->'answers', '[]'::jsonb), 'marks', v_marks, 'keys', v_show);
end;
$$;

-- 학생용: 퀴즈 내기 (한 번만. 다시 풀게 하려면 선생님이 수업 보기에서 지움)
create or replace function public.submit_quiz(p_book_id uuid, p_section int, p_name text, p_answers jsonb, p_class text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sections jsonb;
begin
  perform reading_link_ok(p_book_id);
  select sections into v_sections from books where id = p_book_id and is_open;
  if v_sections is null then raise exception '선생님이 닫은 책입니다.'; end if;
  if p_section is null or p_section < 0 or p_section >= jsonb_array_length(v_sections) then raise exception '주차가 올바르지 않습니다.'; end if;
  if jsonb_array_length(coalesce(v_sections -> p_section -> 'quiz', '[]'::jsonb)) = 0 then raise exception '이 회차에는 독서 퀴즈가 없어요.'; end if;
  if coalesce(length(trim(p_name)), 0) = 0 then raise exception '이름을 입력하세요.'; end if;
  if length(trim(p_name)) > 40 then raise exception '이름이 너무 깁니다.'; end if;
  if jsonb_typeof(p_answers) is distinct from 'array' then raise exception '답이 올바르지 않습니다.'; end if;
  if length(p_answers::text) > 20000 then raise exception '글이 너무 깁니다.'; end if;
  if exists (select 1 from entries where book_id = p_book_id and section = p_section and kind = 'quiz' and student_name = trim(p_name)) then
    raise exception '이미 냈어요. 다시 풀려면 선생님께 말씀드리세요.';
  end if;
  insert into entries (book_id, section, kind, student_name, data, class_id)
  values (p_book_id, p_section, 'quiz', trim(p_name), jsonb_build_object('answers', p_answers), left(coalesce(trim(p_class), ''), 40));
  return get_quiz_status(p_book_id, p_section, p_name);
end;
$$;
revoke all on function public.get_quiz_status(uuid, int, text)              from public;
revoke all on function public.submit_quiz(uuid, int, text, jsonb, text)     from public;
grant execute on function public.get_quiz_status(uuid, int, text)           to anon, authenticated;
grant execute on function public.submit_quiz(uuid, int, text, jsonb, text)  to anon, authenticated;

revoke all on function public.get_book(uuid)                        from public;
revoke all on function public.submit_entry(uuid, int, text, text, jsonb, text) from public;
revoke all on function public.get_my_entries(uuid, text)            from public;
revoke all on function public.get_blank_status(uuid, int, text)     from public;
revoke all on function public.submit_blanks(uuid, int, text, jsonb, text) from public;
grant execute on function public.get_book(uuid)                        to anon, authenticated;
grant execute on function public.submit_entry(uuid, int, text, text, jsonb, text) to anon, authenticated;
grant execute on function public.get_my_entries(uuid, text)            to anon, authenticated;
grant execute on function public.get_blank_status(uuid, int, text)     to anon, authenticated;
grant execute on function public.submit_blanks(uuid, int, text, jsonb, text) to anon, authenticated;

-- ---------- 테이블 권한 ---------------------------------------------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.books to authenticated;
grant select, update, delete on public.entries to authenticated;

-- ---------- 실시간(선택): 교사 화면에 제출 즉시 반영 ----------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'entries'
  ) then
    execute 'alter publication supabase_realtime add table public.entries';
  end if;
end $$;

-- ============================================================
--  2026-11-26 · 청연국어 앱 「내 숙제」에서 독서 열기 (입장 코드 · students.sql 먼저)
--   선생님이 책의 반에 학생 명단의 반을 고르면, 그 반 학생 「내 숙제」에 책이 뜸.
--   이름은 명단 이름, 반은 학생의 반으로 저장 (반별 마감 · 수업 보기 그대로).
-- ============================================================
create or replace function public.rst_student(p_token uuid, p_book_id uuid)
returns public.students
language plpgsql security definer set search_path = public
as $$
declare s students%rowtype;
begin
  s := student_from_token(p_token);
  if not exists (select 1 from books b where b.id = p_book_id and b.owner = s.owner and b.is_open and s.class_id is not null
                    and exists (select 1 from jsonb_array_elements(coalesce(b.classes, '[]'::jsonb)) c where c->>'id' = s.class_id::text)) then
    raise exception '선생님이 아직 열지 않은 책입니다.';
  end if;
  perform set_config('cy.rst', '1', true);
  return s;
end; $$;

-- 내 숙제 목록: 내 반에 열린 책 + 어디까지 했는지 (stage 0 안 함 · 1 하는 중 · 2 책갈피·내용 이해 모두 냄)
create or replace function public.st_books(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare s students%rowtype; v_list jsonb := '[]'::jsonb; r record; v_n int; v_done int; v_any int;
begin
  s := student_from_token(p_token);
  for r in select b.id, b.title, b.author, b.grade, b.sections from books b
            where b.owner = s.owner and b.is_open and s.class_id is not null
              and exists (select 1 from jsonb_array_elements(coalesce(b.classes, '[]'::jsonb)) c where c->>'id' = s.class_id::text)
            order by b.created_at desc loop
    v_n := jsonb_array_length(coalesce(r.sections, '[]'::jsonb));
    select count(*) into v_any from entries e where e.book_id = r.id and e.student_name = s.name;
    select count(*) into v_done from generate_series(0, greatest(v_n - 1, 0)) g(i)
     where v_n > 0
       and exists (select 1 from entries e where e.book_id = r.id and e.student_name = s.name and e.section = g.i and e.kind = 'bookmark')
       and exists (select 1 from entries e where e.book_id = r.id and e.student_name = s.name and e.section = g.i and e.kind = 'blanks');
    v_list := v_list || jsonb_build_object('id', r.id, 'title', r.title, 'author', r.author, 'grade', r.grade, 'app', 'reading',
                                           'stage', case when v_n > 0 and v_done = v_n then 2 when v_any > 0 then 1 else 0 end);
  end loop;
  return jsonb_build_object('name', s.name, 'books', v_list);
end; $$;

create or replace function public.st_r_book(p_token uuid, p_book_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$ declare s students%rowtype; begin s := rst_student(p_token, p_book_id);
  return get_book(p_book_id) || jsonb_build_object('me', s.name, 'my_class', s.class_id::text); end; $$;

create or replace function public.st_r_entries(p_token uuid, p_book_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$ declare s students%rowtype; begin s := rst_student(p_token, p_book_id); return get_my_entries(p_book_id, s.name); end; $$;

create or replace function public.st_r_submit_entry(p_token uuid, p_book_id uuid, p_section int, p_kind text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$ declare s students%rowtype; begin s := rst_student(p_token, p_book_id);
  return submit_entry(p_book_id, p_section, p_kind, s.name, p_data, s.class_id::text); end; $$;

create or replace function public.st_r_blank_status(p_token uuid, p_book_id uuid, p_section int)
returns jsonb language plpgsql security definer set search_path = public
as $$ declare s students%rowtype; begin s := rst_student(p_token, p_book_id); return get_blank_status(p_book_id, p_section, s.name); end; $$;

create or replace function public.st_r_submit_blanks(p_token uuid, p_book_id uuid, p_section int, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$ declare s students%rowtype; begin s := rst_student(p_token, p_book_id);
  return submit_blanks(p_book_id, p_section, s.name, p_answers, s.class_id::text); end; $$;

create or replace function public.st_r_quiz_status(p_token uuid, p_book_id uuid, p_section int)
returns jsonb language plpgsql security definer set search_path = public
as $$ declare s students%rowtype; begin s := rst_student(p_token, p_book_id); return get_quiz_status(p_book_id, p_section, s.name); end; $$;

create or replace function public.st_r_submit_quiz(p_token uuid, p_book_id uuid, p_section int, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$ declare s students%rowtype; begin s := rst_student(p_token, p_book_id);
  return submit_quiz(p_book_id, p_section, s.name, p_answers, s.class_id::text); end; $$;

revoke all on function public.rst_student(uuid, uuid)                          from public, anon, authenticated;
revoke all on function public.st_books(uuid)                                   from public;
revoke all on function public.st_r_book(uuid, uuid)                            from public;
revoke all on function public.st_r_entries(uuid, uuid)                         from public;
revoke all on function public.st_r_submit_entry(uuid, uuid, int, text, jsonb)  from public;
revoke all on function public.st_r_blank_status(uuid, uuid, int)               from public;
revoke all on function public.st_r_submit_blanks(uuid, uuid, int, jsonb)       from public;
revoke all on function public.st_r_quiz_status(uuid, uuid, int)                from public;
revoke all on function public.st_r_submit_quiz(uuid, uuid, int, jsonb)         from public;
grant execute on function public.st_books(uuid)                                to anon, authenticated;
grant execute on function public.st_r_book(uuid, uuid)                         to anon, authenticated;
grant execute on function public.st_r_entries(uuid, uuid)                      to anon, authenticated;
grant execute on function public.st_r_submit_entry(uuid, uuid, int, text, jsonb) to anon, authenticated;
grant execute on function public.st_r_blank_status(uuid, uuid, int)            to anon, authenticated;
grant execute on function public.st_r_submit_blanks(uuid, uuid, int, jsonb)    to anon, authenticated;
grant execute on function public.st_r_quiz_status(uuid, uuid, int)             to anon, authenticated;
grant execute on function public.st_r_submit_quiz(uuid, uuid, int, jsonb)      to anon, authenticated;
