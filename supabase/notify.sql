-- ============================================================
--  청연 알림 (학생이 숙제를 내면 선생님에게 알림) · Supabase 스키마
--  실행 위치: Supabase 대시보드 → SQL Editor → New query → 붙여넣고 Run
--  reading.sql · test.sql 을 먼저 실행해 두어야 함. (다시 실행해도 안전함)
--
--  ① 앱 안 알림: 학생이 청연 독서·청연 되새김·청연 문법에 내면 notices 에 한 줄 → 교사 첫 화면 「새로 낸 숙제」
--  ② 휴대폰 알림: notify_settings 에 ntfy 주제를 저장해 두면 ntfy.sh 로 바로 보냄 (pg_net 사용)
--     같은 학생·같은 숙제를 10분 안에 또 내면 새 줄을 만들지 않고 시간만 고침 (알림 폭탄 막기)
--     알림 보내기가 실패해도 학생 제출은 절대 막지 않음
-- ============================================================

create extension if not exists pg_net;

create table if not exists public.notices (
  id           uuid primary key default gen_random_uuid(),
  owner        uuid not null references auth.users (id) on delete cascade,
  app          text not null,                 -- 'reading' | 'test'(되새김) | 'grammar'
  ref_id       uuid not null,                 -- 책 id 또는 문제(tests) id
  title        text not null default '',      -- 책·작품 제목
  part         text not null default '',      -- 예: '1주차' (독서만)
  student_name text not null,
  what         text not null,                 -- 예: '빈칸 처음 제출', '다시 풀기 1'
  seen         boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists notices_owner_idx on public.notices (owner, created_at desc);

create table if not exists public.notify_settings (
  owner       uuid primary key references auth.users (id) on delete cascade,
  ntfy_topic  text not null default '',
  phone_on    boolean not null default false,
  with_names  boolean not null default true,
  updated_at  timestamptz not null default now()
);

alter table public.notices         enable row level security;
alter table public.notify_settings enable row level security;

drop policy if exists "owner reads notices" on public.notices;
create policy "owner reads notices" on public.notices
  for select to authenticated using (owner = auth.uid());
drop policy if exists "owner updates notices" on public.notices;
create policy "owner updates notices" on public.notices
  for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists "owner deletes notices" on public.notices;
create policy "owner deletes notices" on public.notices
  for delete to authenticated using (owner = auth.uid());

drop policy if exists "owner manages notify settings" on public.notify_settings;
create policy "owner manages notify settings" on public.notify_settings
  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

-- ---------- 알림 한 줄 남기기 + 휴대폰으로 보내기 ---------------------
create or replace function public.add_notice(p_owner uuid, p_app text, p_ref uuid, p_title text, p_part text, p_name text, p_what text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_id uuid; s notify_settings%rowtype; v_app text; v_msg text; v_page text;
begin
  select id into v_id from notices
   where owner = p_owner and app = p_app and ref_id = p_ref and part = coalesce(p_part, '') and student_name = p_name
     and what = p_what and created_at > now() - interval '10 minutes'
   order by created_at desc limit 1;
  if v_id is not null then
    update notices set created_at = now(), seen = false where id = v_id;
    return;                                   -- 10분 안에 같은 일 → 휴대폰은 다시 울리지 않음
  end if;

  insert into notices (owner, app, ref_id, title, part, student_name, what)
  values (p_owner, p_app, p_ref, coalesce(p_title, ''), coalesce(p_part, ''), p_name, p_what);

  select * into s from notify_settings where owner = p_owner;
  if s.owner is null or not s.phone_on or length(s.ntfy_topic) < 8 then return; end if;

  v_app  := case p_app when 'reading' then '청연 독서' when 'test' then '청연 되새김' else '청연 문법' end;
  v_page := case p_app when 'reading' then 'reading.html#book=' when 'test' then 'test.html#test=' else 'grammar.html#test=' end;
  v_msg  := case when s.with_names then p_name || ' · ' else '' end
         || coalesce(p_title, '') || case when coalesce(p_part, '') <> '' then ' ' || p_part else '' end
         || ' · ' || p_what;
  begin
    perform net.http_post(
      url  := 'https://ntfy.sh/',
      body := jsonb_build_object('topic', s.ntfy_topic, 'title', v_app || ' 새 제출', 'message', v_msg,
                                 'tags', jsonb_build_array('pencil2'),
                                 'click', 'https://es0326.github.io/anne/' || v_page || p_ref::text),
      headers := '{"Content-Type": "application/json"}'::jsonb);
  exception when others then
    null;                                     -- 휴대폰 알림이 안 가도 학생 제출은 그대로
  end;
end; $$;
revoke all on function public.add_notice(uuid, text, uuid, text, text, text, text) from public, anon, authenticated;

-- ---------- 청연 독서: entries 가 새로 생기거나 답이 바뀔 때 ---------------
create or replace function public.notice_on_entry()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare b books%rowtype; v_what text;
begin
  if tg_op = 'UPDATE' and new.data is not distinct from old.data then return new; end if;
  if tg_op = 'UPDATE' and new.kind = 'blanks'
     and (new.data - 'accept') is not distinct from (old.data - 'accept') then return new; end if;  -- 선생님 '인정'은 알림 아님
  select * into b from books where id = new.book_id;
  if b.id is null then return new; end if;
  v_what := case new.kind
              when 'blanks' then case when new.data ? 'third' then '빈칸 다시 풀기 2'
                                      when new.data ? 'second' then '빈칸 다시 풀기 1'
                                      else '빈칸 처음 제출' end
              when 'bookmark' then case when tg_op = 'INSERT' then '책갈피 제출' else '책갈피 고침' end
              when 'answers'  then case when tg_op = 'INSERT' then '생각하기 제출' else '생각하기 고침' end
              else new.kind end;
  begin
    perform add_notice(b.owner, 'reading', b.id, b.title, coalesce(b.sections -> new.section ->> 'title', (new.section + 1) || '주차'),
                       new.student_name, v_what);
  exception when others then null;
  end;
  return new;
end; $$;

drop trigger if exists entries_notice on public.entries;
create trigger entries_notice after insert or update on public.entries
  for each row execute function public.notice_on_entry();

-- ---------- 청연 되새김·청연 문법: test_entries (app = 'test' | 'grammar') -----------------
create or replace function public.notice_on_test_entry()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare t tests%rowtype; v_what text;
begin
  select * into t from tests where id = new.test_id;
  if t.id is null or t.app not in ('test', 'grammar') then return new; end if;
  -- 답을 새로 낸 때만 (다시 풀기 '시작' 단추, 선생님 인정·틀림 표시는 알림 아님)
  if tg_op = 'UPDATE' and (new.data->'first')  is not distinct from (old.data->'first')
                      and (new.data->'second') is not distinct from (old.data->'second')
                      and (new.data->'third')  is not distinct from (old.data->'third') then return new; end if;
  if not (new.data ? 'first') then return new; end if;
  v_what := case when new.data ? 'third' then '다시 풀기 2'
                 when new.data ? 'second' then '다시 풀기 1'
                 else '처음 제출' end;
  begin
    perform add_notice(t.owner, t.app, t.id, coalesce(nullif(t.title, ''), t.work), '', new.student_name, v_what);
  exception when others then null;
  end;
  return new;
end; $$;

drop trigger if exists test_entries_notice on public.test_entries;
create trigger test_entries_notice after insert or update on public.test_entries
  for each row execute function public.notice_on_test_entry();
