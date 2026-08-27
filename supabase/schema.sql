-- ============================================================
--  품사 시험지 · Supabase 스키마
--  실행 위치: Supabase 대시보드 → SQL Editor → New query → 붙여넣고 Run
--  한 번만 실행하면 됩니다. (다시 실행해도 안전하도록 작성됨)
-- ============================================================

create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- ---------- 테이블 ----------------------------------------------------
create table if not exists public.quizzes (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null references auth.users (id) on delete cascade,
  title       text not null default '제목 없는 시험',
  is_open     boolean not null default true,          -- false 면 학생이 응시 불가
  created_at  timestamptz not null default now()
);

create table if not exists public.questions (
  id          uuid primary key default gen_random_uuid(),
  quiz_id     uuid not null references public.quizzes (id) on delete cascade,
  position    int  not null,                          -- 0,1,2 … (연속)
  prompt      text not null default '',               -- 발문
  sentence    text not null default '',               -- 예문. 정답 낱말은 [ ] 로 감쌈
  options     jsonb not null default '[]'::jsonb,     -- ["명사","대명사", …]
  answer      int  not null default 0,                -- options 의 0-based 인덱스
  explanation text not null default ''                -- 해설
);
create index if not exists questions_quiz_idx on public.questions (quiz_id, position);

create table if not exists public.submissions (
  id           uuid primary key default gen_random_uuid(),
  quiz_id      uuid not null references public.quizzes (id) on delete cascade,
  student_name text not null,
  answers      jsonb not null,                        -- [0,2,1,null, …]  position 순서
  score        int  not null,
  total        int  not null,
  created_at   timestamptz not null default now()
);
create index if not exists submissions_quiz_idx on public.submissions (quiz_id, created_at);

-- ---------- Row Level Security -------------------------------------
alter table public.quizzes     enable row level security;
alter table public.questions   enable row level security;
alter table public.submissions enable row level security;

-- quizzes: 공개된 시험은 누구나 조회, 내 시험은 항상 조회
drop policy if exists "read open or own quizzes" on public.quizzes;
create policy "read open or own quizzes" on public.quizzes
  for select using (is_open or owner = auth.uid());

drop policy if exists "owner inserts quizzes" on public.quizzes;
create policy "owner inserts quizzes" on public.quizzes
  for insert to authenticated with check (owner = auth.uid());

drop policy if exists "owner updates quizzes" on public.quizzes;
create policy "owner updates quizzes" on public.quizzes
  for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists "owner deletes quizzes" on public.quizzes;
create policy "owner deletes quizzes" on public.quizzes
  for delete to authenticated using (owner = auth.uid());

-- questions: 정답 키가 들어 있으므로 출제자(소유자)만 접근. 학생은 아래 RPC 사용
drop policy if exists "owner manages questions" on public.questions;
create policy "owner manages questions" on public.questions
  for all to authenticated
  using      (exists (select 1 from public.quizzes z where z.id = questions.quiz_id and z.owner = auth.uid()))
  with check (exists (select 1 from public.quizzes z where z.id = questions.quiz_id and z.owner = auth.uid()));

-- submissions: 출제자만 조회. 직접 INSERT 는 아무도 못 함(아래 RPC 로만 기록)
drop policy if exists "owner reads submissions" on public.submissions;
create policy "owner reads submissions" on public.submissions
  for select to authenticated
  using (exists (select 1 from public.quizzes z where z.id = submissions.quiz_id and z.owner = auth.uid()));

-- ---------- 학생용 RPC: 문제 가져오기 (정답 키 제외) ----------------
create or replace function public.get_quiz(p_quiz_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text;
  v_open  boolean;
  v_qs    jsonb;
begin
  select title, is_open into v_title, v_open from quizzes where id = p_quiz_id;
  if v_title is null then raise exception '시험을 찾을 수 없습니다.'; end if;
  if not v_open   then raise exception '마감된 시험입니다.';       end if;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'position', position,
               'prompt',   prompt,
               'sentence', sentence,
               'options',  options
             ) order by position
           ),
           '[]'::jsonb
         )
    into v_qs
    from questions
   where quiz_id = p_quiz_id;

  return jsonb_build_object('title', v_title, 'questions', v_qs);
end;
$$;

-- ---------- 학생용 RPC: 채점 + 제출 기록 --------------------------
create or replace function public.submit_quiz(
  p_quiz_id      uuid,
  p_student_name text,
  p_answers      jsonb            -- position 순서로 정렬된 선택지 인덱스 배열
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open    boolean;
  v_total   int;
  v_score   int := 0;
  v_results jsonb := '[]'::jsonb;
  v_sub_id  uuid;
  r         record;
  v_given   int;
  v_ok      boolean;
begin
  select is_open into v_open from quizzes where id = p_quiz_id;
  if v_open is null then raise exception '시험을 찾을 수 없습니다.'; end if;
  if not v_open   then raise exception '마감된 시험입니다.';       end if;
  if coalesce(length(trim(p_student_name)), 0) = 0 then
    raise exception '이름을 입력하세요.';
  end if;

  select count(*) into v_total from questions where quiz_id = p_quiz_id;
  if v_total = 0 then raise exception '아직 문항이 없습니다.'; end if;

  for r in
    select position, answer, explanation
      from questions
     where quiz_id = p_quiz_id
     order by position
  loop
    begin
      v_given := (p_answers ->> r.position)::int;
    exception when others then
      v_given := null;
    end;
    v_ok := v_given is not null and v_given = r.answer;
    if v_ok then v_score := v_score + 1; end if;
    v_results := v_results || jsonb_build_object(
      'position', r.position,
      'given',    v_given,
      'answer',   r.answer,
      'correct',  v_ok,
      'explanation', r.explanation
    );
  end loop;

  insert into submissions (quiz_id, student_name, answers, score, total)
  values (p_quiz_id, trim(p_student_name), coalesce(p_answers, '[]'::jsonb), v_score, v_total)
  returning id into v_sub_id;

  return jsonb_build_object(
    'submission_id', v_sub_id,
    'score',         v_score,
    'total',         v_total,
    'results',       v_results
  );
end;
$$;

revoke all on function public.get_quiz(uuid)              from public;
revoke all on function public.submit_quiz(uuid, text, jsonb) from public;
grant execute on function public.get_quiz(uuid)              to anon, authenticated;
grant execute on function public.submit_quiz(uuid, text, jsonb) to anon, authenticated;

-- ---------- 테이블 권한 (RLS 와 별개로 필요) ----------------------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.quizzes   to authenticated;
grant select, insert, update, delete on public.questions to authenticated;
grant select on public.submissions to authenticated;
-- anon(학생)은 테이블 직접 권한 없음. 위 두 RPC 로만 접근.

-- ---------- 실시간(선택): 교사 화면에서 제출 즉시 반영 ------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename  = 'submissions'
  ) then
    execute 'alter publication supabase_realtime add table public.submissions';
  end if;
end $$;
