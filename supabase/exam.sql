-- ============================================================
--  청연 성적 (학교 시험 · 모의고사 기록과 오답 분석) · Supabase 스키마 (2026-10-28)
--  실행 위치: Supabase 대시보드 → SQL Editor → New query → 붙여넣고 Run
--  students.sql 을 먼저 실행해 두어야 함 (학생 명단을 같이 씀)
--  (다시 실행해도 안전하도록 작성됨)
--
--  선생님만 읽고 씀. 학생 성적과 시험지 내용은 공개되지 않음.
-- ============================================================

create extension if not exists "pgcrypto";

-- 시험 한 개 (예: 2026 2학기 중간고사 · 성사중 2학년)
--   items:  객관식 [{ "a": "3" (복수 정답은 "2,4"), "pts": 4, "unit": "일용할 양식", "memo": "서술상 특징",
--                    "q": "발문(한글 파일에서, 없어도 됨)", "c": ["선지1", …] (없어도 됨),
--                    "notes": { "4": "헷갈린 선지 메모" } }]
--   essays: 서술형 [{ "label": "서술형 1", "pts": 5, "unit": "…", "memo": "…" }]
create table if not exists public.exams (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  year        int  not null default extract(year from now())::int,
  term        text not null default '',          -- 1학기 · 2학기 · (모의고사는 '3월' 처럼)
  kind        text not null default '중간고사',    -- 중간고사 · 기말고사 · 모의고사 · 기타
  school      text not null default '',
  grade       text not null default '',          -- 중1 · 고2 …
  subject     text not null default '국어',
  nchoice     int  not null default 5 check (nchoice between 2 and 9),
  items       jsonb not null default '[]'::jsonb,
  essays      jsonb not null default '[]'::jsonb,
  memo        text not null default '',
  created_at  timestamptz not null default now()
);

-- 학생 한 명의 답 · 서술형 점수
--   answers: ["3","1","",…] (빈칸 = 안 씀) · essay: [4, 2.5, null, …] · absent: 시험 안 봄
create table if not exists public.exam_scores (
  id           uuid primary key default gen_random_uuid(),
  owner        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  exam_id      uuid not null references public.exams (id) on delete cascade,
  student_id   uuid references public.students (id) on delete set null,
  student_name text not null,
  answers      jsonb not null default '[]'::jsonb,
  essay        jsonb not null default '[]'::jsonb,
  official     numeric,                          -- 학교 성적표 점수(가채점과 다를 때)
  note         text not null default '',
  updated_at   timestamptz not null default now(),
  unique (exam_id, student_name)
);

-- 2026-10-29: 학교에서 알려 준 1등급컷 (점수)
alter table public.exams add column if not exists cut1 numeric;

alter table public.exams       enable row level security;
alter table public.exam_scores enable row level security;

drop policy if exists "owner manages exams" on public.exams;
create policy "owner manages exams" on public.exams
  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists "owner manages exam scores" on public.exam_scores;
create policy "owner manages exam scores" on public.exam_scores
  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

grant select, insert, update, delete on public.exams       to authenticated;
grant select, insert, update, delete on public.exam_scores to authenticated;
