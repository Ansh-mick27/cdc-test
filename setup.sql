-- =====================================================================
--  CDC Online Test — database setup for Supabase
--  Paste this whole file into Supabase > SQL Editor > New query > Run.
--  Safe to run again: it only (re)creates functions, never deletes data.
-- =====================================================================

-- ---------- Tables ----------------------------------------------------
create table if not exists ct_admin (
  id int primary key default 1 check (id = 1),
  salt text not null,
  pass_hash text not null
);

create table if not exists ct_tests (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  title text not null,
  instructions text not null default '',
  duration_min int not null default 60,
  marks_correct numeric not null default 1,
  marks_wrong numeric not null default 0,
  shuffle_questions boolean not null default true,
  shuffle_options boolean not null default true,
  max_switches int not null default 3,          -- 0 = no limit
  access_code text not null default '',
  allowed_domain text not null default '',
  show_result boolean not null default false,
  is_open boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists ct_sections (
  id uuid primary key default gen_random_uuid(),
  test_id uuid not null references ct_tests(id) on delete cascade,
  name text not null,
  position int not null default 0
);

create table if not exists ct_questions (
  id uuid primary key default gen_random_uuid(),
  section_id uuid not null references ct_sections(id) on delete cascade,
  position int not null default 0,
  topic text not null default '',
  text text not null,
  options jsonb not null,           -- ["opt A","opt B",...]
  correct int not null              -- 0-based index into options
);

create table if not exists ct_students (
  test_id uuid not null references ct_tests(id) on delete cascade,
  email text not null,
  name text not null default '',
  roll text not null default '',
  primary key (test_id, email)
);

create table if not exists ct_attempts (
  id uuid primary key default gen_random_uuid(),   -- also the resume token
  test_id uuid not null references ct_tests(id) on delete cascade,
  email text not null,
  name text not null default '',
  roll text not null default '',
  started_at timestamptz not null default now(),
  deadline timestamptz not null,
  submitted_at timestamptz,
  submit_reason text,
  unlocked boolean not null default false,
  layout jsonb not null,
  answers jsonb not null default '{}',
  switches int not null default 0,
  last_seen timestamptz,
  score numeric,
  correct_count int,
  wrong_count int,
  total_count int,
  detail jsonb,
  unique (test_id, email)
);

-- Upgrades for databases created by an earlier version of this file.
alter table ct_students add column if not exists pin text not null default '';
alter table ct_attempts add column if not exists start_ip text not null default '';
alter table ct_attempts add column if not exists start_ua text not null default '';
alter table ct_attempts add column if not exists last_ip text not null default '';

-- Failed logins, used to slow down password / roll-number guessing.
create table if not exists ct_fails (
  key text not null,
  at timestamptz not null default now()
);
create index if not exists ct_fails_key on ct_fails(key, at);

create index if not exists ct_sections_test on ct_sections(test_id);
create index if not exists ct_questions_section on ct_questions(section_id);
create index if not exists ct_attempts_test on ct_attempts(test_id);
-- Answers change often during a test: leave room in each page for in-place updates
-- and clean up old row versions quickly so the database stays small.
alter table ct_attempts set (fillfactor = 70, autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 50, toast.autovacuum_vacuum_scale_factor = 0.01,
  toast.autovacuum_vacuum_threshold = 50);

-- Lock the tables: the browser may only use the functions below.
alter table ct_admin    enable row level security;
alter table ct_tests    enable row level security;
alter table ct_sections enable row level security;
alter table ct_questions enable row level security;
alter table ct_students enable row level security;
alter table ct_attempts enable row level security;
alter table ct_fails    enable row level security;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on ct_admin, ct_tests, ct_sections, ct_questions, ct_students, ct_attempts, ct_fails from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on ct_admin, ct_tests, ct_sections, ct_questions, ct_students, ct_attempts, ct_fails from authenticated';
  end if;
end $$;

-- ---------- Internal helpers (not callable from the browser) ----------

-- The paper a student sees: questions and options in their own order,
-- each option carrying its original index. No answers included.
create or replace function ct_paper(p_layout jsonb) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name,
      'questions', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'id', q.id, 'topic', q.topic, 'text', q.text,
            'options', (
              select jsonb_agg(jsonb_build_object('i', o.v::int, 't', q.options -> (o.v::int)) order by o.n)
              from jsonb_array_elements_text(lq -> 'o') with ordinality o(v, n))
          ) order by lq_n), '[]'::jsonb)
        from jsonb_array_elements(ls -> 'q') with ordinality x(lq, lq_n)
        join ct_questions q on q.id = (lq ->> 'id')::uuid)
    ) order by ls_n), '[]'::jsonb)
  from jsonb_array_elements(p_layout) with ordinality y(ls, ls_n)
  join ct_sections s on s.id = (ls ->> 's')::uuid
$$;

create or replace function ct_attempt_payload(p_id uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'token', a.id, 'email', a.email, 'name', a.name, 'roll', a.roll,
    'deadline', a.deadline, 'server_now', now(),
    'switches', a.switches, 'answers', a.answers,
    'test', jsonb_build_object('title', t.title, 'instructions', t.instructions,
        'duration_min', t.duration_min, 'max_switches', t.max_switches,
        'marks_correct', t.marks_correct, 'marks_wrong', t.marks_wrong),
    'sections', ct_paper(a.layout))
  from ct_attempts a join ct_tests t on t.id = a.test_id
  where a.id = p_id
$$;

create or replace function ct_grade(p_id uuid) returns void
language plpgsql set search_path = public as $$
declare
  a ct_attempts; t ct_tests;
  v_c int; v_w int; v_n int; v_det jsonb;
begin
  select * into a from ct_attempts where id = p_id;
  select * into t from ct_tests where id = a.test_id;
  with qs as (
    select s.name as sname,
           coalesce(nullif(q.topic, ''), s.name) as topic,
           q.correct,
           case when (a.answers ->> q.id::text) ~ '^[0-9]{1,2}$'
                then (a.answers ->> q.id::text)::int end as ans
    from jsonb_array_elements(a.layout) ls
    cross join jsonb_array_elements(ls -> 'q') lq
    join ct_sections s on s.id = (ls ->> 's')::uuid
    join ct_questions q on q.id = (lq ->> 'id')::uuid
  ), g as (
    select *, (ans is not null and ans = correct) as ok,
              (ans is not null and ans <> correct) as bad
    from qs
  )
  select count(*) filter (where ok), count(*) filter (where bad), count(*),
    jsonb_build_object(
      'sections', coalesce((select jsonb_object_agg(sname, x) from (
          select sname, jsonb_build_object('c', count(*) filter (where ok),
                 'w', count(*) filter (where bad), 'n', count(*)) x
          from g group by sname) z1), '{}'::jsonb),
      'topics', coalesce((select jsonb_object_agg(topic, x) from (
          select topic, jsonb_build_object('c', count(*) filter (where ok),
                 'w', count(*) filter (where bad), 'n', count(*)) x
          from g group by topic) z2), '{}'::jsonb))
  into v_c, v_w, v_n, v_det
  from g;

  update ct_attempts
     set correct_count = v_c, wrong_count = v_w, total_count = v_n, detail = v_det,
         score = v_c * t.marks_correct - v_w * t.marks_wrong
   where id = p_id;
end $$;

create or replace function ct_finish(p_id uuid, p_reason text) returns void
language plpgsql set search_path = public as $$
begin
  update ct_attempts set submitted_at = now(), submit_reason = p_reason
   where id = p_id and submitted_at is null;
  perform ct_grade(p_id);
end $$;

-- Keep only valid answers: question ids from this paper, option index as a number.
create or replace function ct_clean_answers(p_layout jsonb, p_answers jsonb) returns jsonb
language sql immutable set search_path = public as $$
  select coalesce(jsonb_object_agg(e.k, e.v), '{}'::jsonb)
  from jsonb_each(coalesce(p_answers, '{}'::jsonb)) e(k, v)
  where jsonb_typeof(e.v) = 'number'
    and e.v::text ~ '^[0-9]{1,2}$'          -- whole option index only (0-99)
    and e.k in (select lq ->> 'id' from jsonb_array_elements(p_layout) ls,
                jsonb_array_elements(ls -> 'q') lq)
$$;

-- Caller's IP and browser as reported by the Supabase API gateway ('' if unknown).
create or replace function ct_req_header(p_name text) returns text
language sql stable set search_path = public as $$
  select coalesce((coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json) ->> p_name, '')
$$;
create or replace function ct_client_ip() returns text
language sql stable set search_path = public as $$
  select left(coalesce(nullif(ct_req_header('cf-connecting-ip'), ''),
                       trim(split_part(ct_req_header('x-forwarded-for'), ',', 1))), 64)
$$;
create or replace function ct_norm(p text) returns text
language sql immutable as $$ select lower(regexp_replace(coalesce(p, ''), '[^a-zA-Z0-9]', '', 'g')) $$;

create or replace function ct_fail_count(p_key text, p_minutes int) returns int
language sql stable set search_path = public as $$
  select count(*)::int from ct_fails where key = p_key and at > now() - make_interval(mins => p_minutes)
$$;
create or replace function ct_fail(p_key text) returns void
language sql set search_path = public as $$
  delete from ct_fails where at < now() - interval '1 day';
  insert into ct_fails (key) values (p_key);
$$;

drop function if exists ct_admin_auth(text);
create function ct_admin_auth(p_pass text) returns boolean
language plpgsql set search_path = public as $$
declare r ct_admin; v_key text := 'admin:' || ct_client_ip();
begin
  select * into r from ct_admin where id = 1;
  if not found then raise exception 'NO_ADMIN'; end if;
  -- 10 wrong passwords from one network in 15 minutes locks that network out for a while.
  if ct_client_ip() <> '' and ct_fail_count(v_key, 15) >= 10 then raise exception 'TOO_MANY_ATTEMPTS'; end if;
  if r.pass_hash <> encode(sha256(convert_to(r.salt || coalesce(p_pass, ''), 'UTF8')), 'hex') then
    if ct_client_ip() <> '' then perform ct_fail(v_key); end if;
    return false;
  end if;
  return true;
end $$;

-- ---------- Student functions ------------------------------------------

create or replace function ct_test_info(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'title', t.title, 'instructions', t.instructions, 'duration_min', t.duration_min,
    'is_open', t.is_open, 'needs_access_code', t.access_code <> '',
    'allowed_domain', t.allowed_domain, 'max_switches', t.max_switches,
    'marks_correct', t.marks_correct, 'marks_wrong', t.marks_wrong,
    'needs_roll', exists (select 1 from ct_students s where s.test_id = t.id and s.roll <> ''),
    'needs_pin', exists (select 1 from ct_students s where s.test_id = t.id and s.pin <> ''),
    'question_count', (select count(*) from ct_questions q join ct_sections s on s.id = q.section_id where s.test_id = t.id),
    'sections', (select coalesce(jsonb_agg(jsonb_build_object('name', s.name,
        'count', (select count(*) from ct_questions q where q.section_id = s.id)) order by s.position), '[]'::jsonb)
        from ct_sections s where s.test_id = t.id))
  from ct_tests t where t.code = upper(trim(p_code))
$$;

drop function if exists ct_start(text, text, text, text, text, uuid);
create or replace function ct_start(p_code text, p_email text, p_name text default '',
    p_roll text default '', p_access text default '', p_token uuid default null,
    p_pin text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t ct_tests; a ct_attempts; st ct_students;
  e text := lower(trim(coalesce(p_email, '')));
  v_name text; v_roll text; v_layout jsonb; v_key text; v_listed boolean;
begin
  select * into t from ct_tests where code = upper(trim(coalesce(p_code, '')));
  if not found then raise exception 'TEST_NOT_FOUND'; end if;
  if length(e) > 200 or e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  v_key := 'start:' || t.id || ':' || e;

  -- Identity check against the uploaded student list (roll number / PIN).
  select exists (select 1 from ct_students where test_id = t.id) into v_listed;
  if v_listed then
    select * into st from ct_students where test_id = t.id and email = e;
    -- Skip the check only when resuming with this student's own valid token.
    if found and not exists (select 1 from ct_attempts where id = p_token and test_id = t.id and email = e) then
      if ct_fail_count(v_key, 10) >= 8 then return jsonb_build_object('error', 'TOO_MANY_ATTEMPTS'); end if;
      if st.roll <> '' and ct_norm(p_roll) <> ct_norm(st.roll) then
        perform ct_fail(v_key); return jsonb_build_object('error', 'BAD_ROLL');
      end if;
      if st.pin <> '' and ct_norm(p_pin) <> ct_norm(st.pin) then
        perform ct_fail(v_key); return jsonb_build_object('error', 'BAD_PIN');
      end if;
    end if;
  end if;

  -- Existing attempt: resume on the same device, or after the admin unlocks it.
  select * into a from ct_attempts where test_id = t.id and email = e for update;
  if found then
    if a.submitted_at is not null then raise exception 'ALREADY_SUBMITTED'; end if;
    if a.deadline + interval '60 seconds' < now() then
      perform ct_finish(a.id, 'time_up');
      raise exception 'ALREADY_SUBMITTED';
    end if;
    if not (coalesce(a.id = p_token, false) or a.unlocked) then raise exception 'IN_PROGRESS_ELSEWHERE'; end if;
    update ct_attempts set unlocked = false, last_seen = now(), last_ip = ct_client_ip() where id = a.id;
    return ct_attempt_payload(a.id);
  end if;

  if not t.is_open then raise exception 'TEST_CLOSED'; end if;
  if t.access_code <> '' and upper(trim(coalesce(p_access, ''))) <> upper(t.access_code) then
    raise exception 'BAD_ACCESS_CODE';
  end if;

  if v_listed then
    if st.email is null then raise exception 'NOT_REGISTERED'; end if;
  elsif t.allowed_domain <> '' and split_part(e, '@', 2) <> lower(trim(t.allowed_domain, ' @')) then
    raise exception 'WRONG_DOMAIN';
  end if;

  v_name := coalesce(nullif(trim(st.name), ''), trim(coalesce(p_name, '')));
  v_roll := coalesce(nullif(trim(st.roll), ''), trim(coalesce(p_roll, '')));
  if v_name = '' then raise exception 'NAME_REQUIRED'; end if;

  select jsonb_agg(jsonb_build_object('s', s.id, 'q', (
      select jsonb_agg(jsonb_build_object('id', q.id, 'o', (
          select jsonb_agg(i order by case when t.shuffle_options then random() else i end)
          from generate_series(0, jsonb_array_length(q.options) - 1) i))
        order by case when t.shuffle_questions then random() else q.position end)
      from ct_questions q where q.section_id = s.id)) order by s.position)
  into v_layout
  from ct_sections s
  where s.test_id = t.id and exists (select 1 from ct_questions q where q.section_id = s.id);
  if v_layout is null then raise exception 'NO_QUESTIONS'; end if;

  insert into ct_attempts (test_id, email, name, roll, deadline, layout, last_seen, start_ip, start_ua, last_ip)
  values (t.id, e, left(v_name, 120), left(v_roll, 40), now() + make_interval(mins => t.duration_min), v_layout, now(),
          ct_client_ip(), left(ct_req_header('user-agent'), 200), ct_client_ip())
  on conflict (test_id, email) do nothing
  returning * into a;
  if a.id is null then raise exception 'IN_PROGRESS_ELSEWHERE'; end if;

  return ct_attempt_payload(a.id);
end $$;

create or replace function ct_save(p_token uuid, p_answers jsonb, p_switches int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a ct_attempts; t ct_tests; v_ans jsonb; v_sw int;
begin
  if pg_column_size(p_answers) > 65536 then raise exception 'PAYLOAD_TOO_LARGE'; end if;
  select * into a from ct_attempts where id = p_token for update;
  if not found then raise exception 'NO_ATTEMPT'; end if;
  select * into t from ct_tests where id = a.test_id;
  if a.submitted_at is not null then
    return jsonb_build_object('submitted', true, 'reason', a.submit_reason, 'server_now', now());
  end if;
  if now() > a.deadline + interval '60 seconds' then
    perform ct_finish(a.id, 'time_up');
    return jsonb_build_object('submitted', true, 'reason', 'time_up', 'server_now', now());
  end if;
  v_ans := ct_clean_answers(a.layout, p_answers);
  v_sw := greatest(a.switches, least(coalesce(p_switches, 0), 1000));
  if v_ans = a.answers and v_sw = a.switches then
    -- Nothing changed (routine check-in): only touch the small columns, so the
    -- stored answers are not rewritten and the database does not grow.
    if a.last_seen < now() - interval '30 seconds' or a.last_ip <> ct_client_ip() then
      update ct_attempts set last_seen = now(), last_ip = ct_client_ip() where id = a.id;
    end if;
  else
    update ct_attempts set answers = v_ans, switches = v_sw, last_seen = now(), last_ip = ct_client_ip()
     where id = a.id
    returning * into a;
  end if;
  if t.max_switches > 0 and a.switches > t.max_switches then
    perform ct_finish(a.id, 'tab_switch_limit');
    return jsonb_build_object('submitted', true, 'reason', 'tab_switch_limit', 'server_now', now());
  end if;
  return jsonb_build_object('submitted', false, 'deadline', a.deadline, 'server_now', now());
end $$;

create or replace function ct_submit(p_token uuid, p_answers jsonb, p_switches int default 0,
    p_reason text default 'submitted') returns jsonb
language plpgsql security definer set search_path = public as $$
declare a ct_attempts; t ct_tests;
begin
  if pg_column_size(p_answers) > 65536 then raise exception 'PAYLOAD_TOO_LARGE'; end if;
  select * into a from ct_attempts where id = p_token for update;
  if not found then raise exception 'NO_ATTEMPT'; end if;
  select * into t from ct_tests where id = a.test_id;
  if a.submitted_at is null then
    if now() <= a.deadline + interval '60 seconds' then
      update ct_attempts
         set answers = ct_clean_answers(a.layout, p_answers),
             switches = greatest(a.switches, least(coalesce(p_switches, 0), 1000)),
             last_seen = now(), last_ip = ct_client_ip()
       where id = a.id;
    end if;
    perform ct_finish(a.id, case when p_reason in ('submitted', 'time_up', 'tab_switch_limit')
                                 then p_reason else 'submitted' end);
  end if;
  select * into a from ct_attempts where id = p_token;
  if not t.show_result then
    return jsonb_build_object('submitted', true, 'reason', a.submit_reason);
  end if;
  return jsonb_build_object('submitted', true, 'reason', a.submit_reason,
    'result', jsonb_build_object('score', a.score, 'correct', a.correct_count,
       'wrong', a.wrong_count, 'total', a.total_count, 'detail', a.detail,
       'max_score', a.total_count * t.marks_correct));
end $$;

-- ---------- Admin functions -------------------------------------------

create or replace function ct_admin_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('configured', exists (select 1 from ct_admin))
$$;

create or replace function ct_admin_setup(p_pass text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_salt text := md5(random()::text || clock_timestamp()::text);
begin
  if exists (select 1 from ct_admin) then raise exception 'ALREADY_CONFIGURED'; end if;
  if length(coalesce(p_pass, '')) < 10 then raise exception 'PASSWORD_TOO_SHORT'; end if;
  insert into ct_admin (id, salt, pass_hash)
  values (1, v_salt, encode(sha256(convert_to(v_salt || p_pass, 'UTF8')), 'hex'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function ct_admin(p_pass text, p_action text, p_args jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_res jsonb; v_pos int; v_salt text; v_code text; q jsonb; i int := 0;
begin
  if not ct_admin_auth(p_pass) then return jsonb_build_object('error', 'BAD_PASSWORD'); end if;
  p_args := coalesce(p_args, '{}'::jsonb);

  if p_action = 'tests' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'code', t.code, 'title', t.title, 'is_open', t.is_open,
        'duration_min', t.duration_min, 'created_at', t.created_at,
        'questions', (select count(*) from ct_questions q join ct_sections s on s.id = q.section_id where s.test_id = t.id),
        'attempts', (select count(*) from ct_attempts a where a.test_id = t.id),
        'submitted', (select count(*) from ct_attempts a where a.test_id = t.id and a.submitted_at is not null))
      order by t.created_at desc), '[]'::jsonb)
    into v_res from ct_tests t;
    return v_res;

  elsif p_action = 'get_test' then
    v_id := (p_args ->> 'id')::uuid;
    select to_jsonb(t) || jsonb_build_object(
        'students', (select count(*) from ct_students s where s.test_id = t.id),
        'attempts', (select count(*) from ct_attempts a where a.test_id = t.id),
        'sections', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'position', s.position,
            'questions', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'topic', q.topic, 'text', q.text,
                'options', q.options, 'correct', q.correct) order by q.position), '[]'::jsonb)
                from ct_questions q where q.section_id = s.id)) order by s.position), '[]'::jsonb)
          from ct_sections s where s.test_id = t.id))
    into v_res from ct_tests t where t.id = v_id;
    if v_res is null then raise exception 'TEST_NOT_FOUND'; end if;
    return v_res;

  elsif p_action = 'save_test' then
    v_id := nullif(p_args ->> 'id', '')::uuid;
    if coalesce(trim(p_args ->> 'title'), '') = '' then raise exception 'TITLE_REQUIRED'; end if;
    if v_id is null then
      loop
        v_code := upper(substr(md5(random()::text), 1, 6));
        exit when not exists (select 1 from ct_tests where code = v_code);
      end loop;
      insert into ct_tests (code, title) values (v_code, trim(p_args ->> 'title')) returning id into v_id;
    end if;
    update ct_tests set
      title = trim(p_args ->> 'title'),
      instructions = coalesce(p_args ->> 'instructions', instructions),
      duration_min = greatest(1, coalesce((p_args ->> 'duration_min')::int, duration_min)),
      marks_correct = coalesce((p_args ->> 'marks_correct')::numeric, marks_correct),
      marks_wrong = abs(coalesce((p_args ->> 'marks_wrong')::numeric, marks_wrong)),
      shuffle_questions = coalesce((p_args ->> 'shuffle_questions')::boolean, shuffle_questions),
      shuffle_options = coalesce((p_args ->> 'shuffle_options')::boolean, shuffle_options),
      max_switches = greatest(0, coalesce((p_args ->> 'max_switches')::int, max_switches)),
      access_code = trim(coalesce(p_args ->> 'access_code', access_code)),
      allowed_domain = lower(trim(coalesce(p_args ->> 'allowed_domain', allowed_domain), ' @')),
      show_result = coalesce((p_args ->> 'show_result')::boolean, show_result),
      is_open = coalesce((p_args ->> 'is_open')::boolean, is_open)
    where id = v_id;
    return ct_admin(p_pass, 'get_test', jsonb_build_object('id', v_id));

  elsif p_action = 'set_open' then
    update ct_tests set is_open = (p_args ->> 'is_open')::boolean where id = (p_args ->> 'id')::uuid;
    return jsonb_build_object('ok', true);

  elsif p_action = 'delete_test' then
    delete from ct_tests where id = (p_args ->> 'id')::uuid;
    return jsonb_build_object('ok', true);

  elsif p_action = 'add_section' then
    v_id := (p_args ->> 'test_id')::uuid;
    if not exists (select 1 from ct_tests where id = v_id) then raise exception 'TEST_NOT_FOUND'; end if;
    if jsonb_array_length(coalesce(p_args -> 'questions', '[]'::jsonb)) = 0 then raise exception 'NO_QUESTIONS'; end if;
    select coalesce(max(position), 0) + 1 into v_pos from ct_sections where test_id = v_id;
    insert into ct_sections (test_id, name, position)
    values (v_id, coalesce(nullif(trim(p_args ->> 'name'), ''), 'Section ' || v_pos), v_pos)
    returning id into v_id;
    for q in select * from jsonb_array_elements(p_args -> 'questions') loop
      i := i + 1;
      if jsonb_typeof(q -> 'options') <> 'array' or jsonb_array_length(q -> 'options') < 2
         or (q ->> 'correct')::int < 0 or (q ->> 'correct')::int >= jsonb_array_length(q -> 'options') then
        raise exception 'BAD_QUESTION_%', i;
      end if;
      insert into ct_questions (section_id, position, topic, text, options, correct)
      values (v_id, i, coalesce(q ->> 'topic', ''), q ->> 'text', q -> 'options', (q ->> 'correct')::int);
    end loop;
    return jsonb_build_object('ok', true, 'section_id', v_id, 'count', i);

  elsif p_action = 'rename_section' then
    update ct_sections set name = trim(p_args ->> 'name') where id = (p_args ->> 'id')::uuid;
    return jsonb_build_object('ok', true);

  elsif p_action = 'delete_section' then
    delete from ct_sections where id = (p_args ->> 'id')::uuid;
    return jsonb_build_object('ok', true);

  elsif p_action = 'set_students' then
    v_id := (p_args ->> 'test_id')::uuid;
    delete from ct_students where test_id = v_id;
    insert into ct_students (test_id, email, name, roll, pin)
    select distinct on (lower(trim(s ->> 'email'))) v_id, lower(trim(s ->> 'email')),
           left(coalesce(trim(s ->> 'name'), ''), 120), left(coalesce(trim(s ->> 'roll'), ''), 40),
           left(coalesce(trim(s ->> 'pin'), ''), 40)
    from jsonb_array_elements(coalesce(p_args -> 'students', '[]'::jsonb)) s
    where coalesce(trim(s ->> 'email'), '') like '%@%';
    return jsonb_build_object('ok', true, 'count', (select count(*) from ct_students where test_id = v_id));

  elsif p_action = 'get_students' then
    select coalesce(jsonb_agg(jsonb_build_object('email', email, 'name', name, 'roll', roll, 'pin', pin) order by roll, name), '[]'::jsonb)
    into v_res from ct_students where test_id = (p_args ->> 'test_id')::uuid;
    return v_res;

  elsif p_action = 'results' then
    v_id := (p_args ->> 'test_id')::uuid;
    perform ct_finish(a.id, 'time_up') from ct_attempts a
     where a.test_id = v_id and a.submitted_at is null and a.deadline + interval '60 seconds' < now();
    select coalesce(jsonb_agg(jsonb_build_object(
        'email', a.email, 'name', a.name, 'roll', a.roll, 'started_at', a.started_at,
        'deadline', a.deadline, 'submitted_at', a.submitted_at, 'submit_reason', a.submit_reason,
        'switches', a.switches, 'last_seen', a.last_seen, 'unlocked', a.unlocked,
        'start_ip', a.start_ip, 'last_ip', a.last_ip, 'start_ua', a.start_ua,
        'answered', (select count(*) from jsonb_object_keys(a.answers)),
        'score', a.score, 'correct', a.correct_count, 'wrong', a.wrong_count,
        'total', coalesce(a.total_count, (select sum(jsonb_array_length(ls -> 'q')) from jsonb_array_elements(a.layout) ls)),
        'detail', a.detail) order by a.score desc nulls last, a.name), '[]'::jsonb)
    into v_res from ct_attempts a where a.test_id = v_id;
    return jsonb_build_object('server_now', now(), 'attempts', v_res,
      'sections', (select coalesce(jsonb_agg(name order by position), '[]'::jsonb) from ct_sections where test_id = v_id),
      'topics', (select coalesce(jsonb_agg(distinct coalesce(nullif(q.topic, ''), s.name)), '[]'::jsonb)
                 from ct_questions q join ct_sections s on s.id = q.section_id where s.test_id = v_id));

  elsif p_action = 'reset_attempt' then
    delete from ct_attempts where test_id = (p_args ->> 'test_id')::uuid and email = lower(trim(p_args ->> 'email'));
    delete from ct_fails where key = 'start:' || (p_args ->> 'test_id') || ':' || lower(trim(p_args ->> 'email'));
    return jsonb_build_object('ok', true);

  elsif p_action = 'unlock' then
    update ct_attempts set unlocked = true
     where test_id = (p_args ->> 'test_id')::uuid and email = lower(trim(p_args ->> 'email')) and submitted_at is null;
    delete from ct_fails where key = 'start:' || (p_args ->> 'test_id') || ':' || lower(trim(p_args ->> 'email'));
    return jsonb_build_object('ok', true);

  elsif p_action = 'extend' then
    update ct_attempts set deadline = deadline + make_interval(mins => (p_args ->> 'minutes')::int)
     where test_id = (p_args ->> 'test_id')::uuid and email = lower(trim(p_args ->> 'email')) and submitted_at is null;
    return jsonb_build_object('ok', true);

  elsif p_action = 'finish_all' then
    perform ct_finish(a.id, 'ended_by_admin') from ct_attempts a
     where a.test_id = (p_args ->> 'test_id')::uuid and a.submitted_at is null;
    update ct_tests set is_open = false where id = (p_args ->> 'test_id')::uuid;
    return jsonb_build_object('ok', true);

  elsif p_action = 'change_password' then
    if length(coalesce(p_args ->> 'new', '')) < 10 then raise exception 'PASSWORD_TOO_SHORT'; end if;
    v_salt := md5(random()::text || clock_timestamp()::text);
    update ct_admin set salt = v_salt,
      pass_hash = encode(sha256(convert_to(v_salt || (p_args ->> 'new'), 'UTF8')), 'hex') where id = 1;
    return jsonb_build_object('ok', true);
  end if;

  raise exception 'UNKNOWN_ACTION';
end $$;

-- ---------- Permissions -----------------------------------------------
revoke execute on function ct_paper(jsonb), ct_attempt_payload(uuid), ct_grade(uuid),
  ct_finish(uuid, text), ct_clean_answers(jsonb, jsonb), ct_admin_auth(text),
  ct_req_header(text), ct_client_ip(), ct_norm(text), ct_fail_count(text, int), ct_fail(text) from public;

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke execute on function ct_paper(jsonb), ct_attempt_payload(uuid), ct_grade(uuid), ct_finish(uuid, text), ct_clean_answers(jsonb, jsonb), ct_admin_auth(text), ct_req_header(text), ct_client_ip(), ct_norm(text), ct_fail_count(text, int), ct_fail(text) from %I', r);
      execute format('grant execute on function ct_test_info(text), ct_start(text, text, text, text, text, uuid, text), ct_save(uuid, jsonb, int), ct_submit(uuid, jsonb, int, text), ct_admin_status(), ct_admin_setup(text), ct_admin(text, text, jsonb) to %I', r);
    end if;
  end loop;
end $$;

-- Ask the API to pick up the new functions right away.
notify pgrst, 'reload schema';
