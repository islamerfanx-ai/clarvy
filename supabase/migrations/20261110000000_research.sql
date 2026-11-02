-- Research room (decided 2026-11-02): a team gets one piece of research done with the same thinking models.
-- Frame (question, branches) → split (branches to people) → find (findings with source, date, how sure) →
-- pool (the analysis: agree, conflict, thin, old) → brief. The owner chooses whether findings are hidden until
-- each person submits (the default, so nobody anchors on the first finding) or open from the start.

create table research (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references profiles (id) on delete cascade,
  question   text not null check (length(trim(question)) between 3 and 400),
  context    text not null default '' check (length(context) <= 4000),
  language   app_language not null default 'en',
  method     jsonb not null default '{}',
  visibility text not null default 'hidden' check (visibility in ('hidden', 'open')),
  due_by     date,
  status     text not null default 'open' check (status in ('open', 'pooled', 'done')),
  pool       jsonb,
  brief      jsonb,
  brief_at   timestamptz,
  parent_id  uuid references research (id) on delete set null,
  to_room_at timestamptz,   -- the owner turned the brief into a decision room (for the admin numbers)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index research_owner_idx on research (owner_id);
create index research_parent_idx on research (parent_id);

create table research_branches (
  id          uuid primary key default gen_random_uuid(),
  research_id uuid not null references research (id) on delete cascade,
  position    int not null default 0,
  title       text not null check (length(trim(title)) between 1 and 200),
  ask         text not null default '' check (length(ask) <= 600),
  method      text not null default 'lookup' check (method in ('lookup', 'test')),
  returned_at timestamptz
);
create index research_branches_idx on research_branches (research_id, position);

create table research_people (
  research_id  uuid not null references research (id) on delete cascade,
  user_id      uuid not null references profiles (id) on delete cascade,
  role         text not null default 'member' check (role in ('owner', 'member')),
  branch_ids   uuid[] not null default '{}',
  joined_at    timestamptz not null default now(),
  submitted_at timestamptz,
  primary key (research_id, user_id)
);
create index research_people_user_idx on research_people (user_id);

create table research_invites (
  token          text primary key default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  research_id    uuid not null references research (id) on delete cascade,
  person_name    text not null check (length(trim(person_name)) between 1 and 80),
  person_contact text check (person_contact is null or length(person_contact) <= 120),
  branch_ids     uuid[] not null default '{}',
  created_by     uuid not null default auth.uid() references profiles (id) on delete cascade,
  joined_by      uuid references profiles (id) on delete set null,
  opened_at      timestamptz,
  revoked        boolean not null default false,
  created_at     timestamptz not null default now()
);
create index research_invites_idx on research_invites (research_id);
create index research_invites_created_by_idx on research_invites (created_by);
create index research_invites_joined_by_idx on research_invites (joined_by);

create table research_findings (
  id           uuid primary key default gen_random_uuid(),
  research_id  uuid not null references research (id) on delete cascade,
  branch_id    uuid not null references research_branches (id) on delete cascade,
  user_id      uuid not null default auth.uid() references profiles (id) on delete cascade,
  body         text not null check (length(trim(body)) between 1 and 1000),
  source_url   text check (source_url is null or (source_url ~ '^https?://' and length(source_url) <= 500)),
  source_label text check (source_label is null or length(source_label) <= 120),
  source_date  date,
  sure         text not null default 'fairly' check (sure in ('sure', 'fairly', 'guess')),
  created_at   timestamptz not null default now()
);
create index research_findings_idx on research_findings (research_id, branch_id);
create index research_findings_user_idx on research_findings (user_id);
create index research_findings_branch_idx on research_findings (branch_id);

alter table research enable row level security;
alter table research_branches enable row level security;
alter table research_people enable row level security;
alter table research_invites enable row level security;
alter table research_findings enable row level security;

create function research_role(rid uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from research_people where research_id = rid and user_id = auth.uid()
$$;

-- Who may read a finding: its author always; everyone in the research once it is pooled, or when findings are open;
-- while hidden, a submitted finding to the owner and to people who have submitted their own.
create function research_can_see(rid uuid, author uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select author = auth.uid() or exists (
    select 1 from research r join research_people me on me.research_id = r.id and me.user_id = auth.uid()
    where r.id = rid and (
      r.status <> 'open' or r.visibility = 'open'
      or (exists (select 1 from research_people a where a.research_id = rid and a.user_id = author and a.submitted_at is not null)
          and (me.role = 'owner' or me.submitted_at is not null))))
$$;

create policy "people in it read the research" on research for select using (research_role(id) is not null);
create policy "anyone signed in starts research" on research for insert
  with check (owner_id = (select auth.uid()) and (parent_id is null or research_role(parent_id) = 'owner'));
create policy "the owner edits the research" on research for update using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "the owner deletes the research" on research for delete using (owner_id = (select auth.uid()));

-- Status, the pooled analysis and the brief are written by the server only.
create function guard_research() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if auth.uid() is null or current_setting('app.research_trusted', true) = 'on' then return new; end if;
  if new.status is distinct from old.status or new.pool is distinct from old.pool or new.brief is distinct from old.brief
     or new.brief_at is distinct from old.brief_at or new.owner_id is distinct from old.owner_id or new.parent_id is distinct from old.parent_id then
    raise exception 'research_is_managed' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger research_guard before update on research for each row execute function guard_research();
revoke execute on function guard_research() from public, anon, authenticated;

create function research_owner_joins() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into research_people (research_id, user_id, role) values (new.id, new.owner_id, 'owner') on conflict do nothing;
  return new;
end $$;
create trigger research_created after insert on research for each row execute function research_owner_joins();
revoke execute on function research_owner_joins() from public, anon, authenticated;

create policy "people in it read the branches" on research_branches for select using (research_role(research_id) is not null);
create policy "the owner adds branches" on research_branches for insert
  with check (research_role(research_id) = 'owner' and exists (select 1 from research r where r.id = research_id and r.status = 'open'));
create policy "the owner changes branches" on research_branches for update
  using (research_role(research_id) = 'owner') with check (research_role(research_id) = 'owner');
create policy "the owner removes branches" on research_branches for delete
  using (research_role(research_id) = 'owner' and exists (select 1 from research r where r.id = research_id and r.status = 'open'));

create policy "people see who is in it" on research_people for select using (research_role(research_id) is not null);
create policy "the owner changes who does what" on research_people for update
  using (research_role(research_id) = 'owner') with check (research_role(research_id) = 'owner');
create policy "the owner removes people, people leave" on research_people for delete
  using (role <> 'owner' and (user_id = (select auth.uid()) or research_role(research_id) = 'owner'));
-- The owner only changes who does which branch; submitting goes through submit_research.
create function guard_research_people() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or current_setting('app.research_trusted', true) = 'on' then return new; end if;
  if new.role is distinct from old.role or new.submitted_at is distinct from old.submitted_at or new.user_id is distinct from old.user_id
     or new.research_id is distinct from old.research_id or new.joined_at is distinct from old.joined_at then
    raise exception 'only_branches_change' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger research_people_guard before update on research_people for each row execute function guard_research_people();
revoke execute on function guard_research_people() from public, anon, authenticated;

create policy "the owner sees invites" on research_invites for select using (research_role(research_id) = 'owner');
create policy "the owner invites" on research_invites for insert
  with check (created_by = (select auth.uid()) and research_role(research_id) = 'owner');
create policy "the owner changes invites" on research_invites for update
  using (research_role(research_id) = 'owner') with check (research_role(research_id) = 'owner');

create policy "findings follow the visibility rule" on research_findings for select using (research_can_see(research_id, user_id));
create policy "people add findings to their research" on research_findings for insert
  with check (user_id = (select auth.uid()) and research_role(research_id) is not null
              and exists (select 1 from research r where r.id = research_id and r.status = 'open')
              and exists (select 1 from research_branches b where b.id = branch_id and b.research_id = research_findings.research_id));
create policy "authors remove their findings while open" on research_findings for delete
  using (user_id = (select auth.uid()) and exists (select 1 from research r where r.id = research_id and r.status = 'open'));

-- The join page: what the research is about, before signing in.
create function research_invite_preview(invite_token text)
returns table (question text, language text, person_name text, owner_name text, branches text[], due_by date)
language sql stable security definer set search_path = public as $$
  select r.question, r.language::text, i.person_name, nullif(trim(o.name), ''),
         array(select b.title from research_branches b where b.research_id = r.id and b.id = any (i.branch_ids) order by b.position),
         r.due_by
  from research_invites i join research r on r.id = i.research_id left join profiles o on o.id = r.owner_id
  where i.token = invite_token and not i.revoked
$$;
create function research_invite_opened(invite_token text) returns void
language sql security definer set search_path = public as $$
  update research_invites set opened_at = coalesce(opened_at, now()) where token = invite_token and not revoked
$$;

create function join_research(invite_token text) returns uuid
language plpgsql security definer set search_path = public as $$
declare i research_invites;
begin
  if auth.uid() is null then raise exception 'sign_in_first' using errcode = 'insufficient_privilege'; end if;
  select * into i from research_invites where token = invite_token and not revoked;
  if not found then raise exception 'invite_not_found' using errcode = 'no_data_found'; end if;
  if i.joined_by is not null and i.joined_by <> auth.uid() then raise exception 'invite_used' using errcode = 'check_violation'; end if;
  insert into research_people (research_id, user_id, branch_ids) values (i.research_id, auth.uid(), i.branch_ids)
  on conflict (research_id, user_id) do update set branch_ids =
    (select array(select distinct unnest(research_people.branch_ids || excluded.branch_ids)));
  update research_invites set joined_by = auth.uid(), opened_at = coalesce(opened_at, now()) where token = invite_token;
  return i.research_id;
end $$;
revoke execute on function join_research(text) from public, anon;

-- Names, branches and who has submitted, plus (for the owner) invites not yet taken up.
create function research_roster(rid uuid)
returns table (user_id uuid, name text, role text, branch_ids uuid[], submitted_at timestamptz, invite_token text, opened_at timestamptz, me boolean)
language sql stable security definer set search_path = public as $$
  select p.user_id, coalesce(nullif(trim(pr.name), ''), ''), p.role, p.branch_ids, p.submitted_at, null::text, null::timestamptz, p.user_id = auth.uid()
  from research_people p join profiles pr on pr.id = p.user_id
  where p.research_id = rid and research_role(rid) is not null
  union all
  select null, i.person_name, 'invited', i.branch_ids, null, i.token, i.opened_at, false
  from research_invites i
  where i.research_id = rid and i.joined_by is null and not i.revoked and research_role(rid) = 'owner'
$$;

create function submit_research(rid uuid, undo boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from research where id = rid and status = 'open') then raise exception 'research_not_open' using errcode = 'check_violation'; end if;
  perform set_config('app.research_trusted', 'on', true);
  update research_people set submitted_at = case when undo then null else now() end where research_id = rid and user_id = auth.uid();
  perform set_config('app.research_trusted', 'off', true);
end $$;
revoke execute on function submit_research(uuid, boolean) from public, anon;

-- The owner sends a branch back: it opens again and the people on it submit again.
create function return_branch(rid uuid, bid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if research_role(rid) is distinct from 'owner' then raise exception 'only_owner' using errcode = 'insufficient_privilege'; end if;
  perform set_config('app.research_trusted', 'on', true);
  update research_branches set returned_at = now() where id = bid and research_id = rid;
  update research_people set submitted_at = null where research_id = rid and bid = any (branch_ids);
  update research set status = 'open' where id = rid and status <> 'done';
  perform set_config('app.research_trusted', 'off', true);
end $$;
revoke execute on function return_branch(uuid, uuid) from public, anon;

-- Your rooms: research you own or take part in.
create function my_research()
returns table (id uuid, question text, status text, role text, due_by date, language text, people bigint, submitted bigint,
               i_submitted boolean, brief_at timestamptz, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, r.question, r.status, me.role, r.due_by, r.language::text,
         (select count(*) from research_people p where p.research_id = r.id and p.role = 'member'),
         (select count(*) from research_people p where p.research_id = r.id and p.role = 'member' and p.submitted_at is not null),
         me.submitted_at is not null, r.brief_at, r.created_at
  from research r join research_people me on me.research_id = r.id and me.user_id = auth.uid()
  order by r.created_at desc
$$;

-- Daily limit for the research analysis.
alter table usage_counts drop constraint usage_counts_kind_check;
alter table usage_counts add constraint usage_counts_kind_check
  check (kind in ('triage', 'criteria', 'decide', 'roles', 'question', 'brief', 'helper', 'notes', 'simulate', 'research'));

-- Phone notifications for research: an invite to someone with an account, a submission (owner), the brief (everyone).
alter table push_outbox drop constraint push_outbox_event_check;
alter table push_outbox add constraint push_outbox_event_check check (event in ('invite', 'joined', 'answered', 'all_answered', 'objection',
  'call_ready', 'decided', 'talk', 'reopen', 'plan_assigned', 'plan_due', 'review_due', 'research_invite', 'research_submitted', 'research_brief'));
create or replace function push_kind(ev text) returns text language sql immutable set search_path = public as $$
  select case
    when ev in ('invite', 'research_invite') then 'invites'
    when ev in ('joined', 'answered', 'all_answered', 'objection', 'research_submitted') then 'progress'
    when ev in ('call_ready', 'decided', 'research_brief') then 'call'
    else 'after' end
$$;

create function push_on_research_invite() returns trigger language plpgsql security definer set search_path = public as $$
declare uid uuid; r research;
begin
  if new.person_contact is null or position('@' in new.person_contact) = 0 then return new; end if;
  select id into uid from profiles where lower(email) = lower(trim(new.person_contact)) limit 1;
  if uid is null or uid = new.created_by then return new; end if;
  select * into r from research where id = new.research_id;
  perform push_enqueue(uid, 'research_invite', null, jsonb_build_object('token', new.token, 'by', push_name(r.owner_id),
    'q', r.question, 'lang', r.language), 'rinvite:' || new.token);
  return new;
end $$;
create trigger push_research_invites after insert on research_invites for each row execute function push_on_research_invite();
revoke execute on function push_on_research_invite() from public, anon, authenticated;

create function push_on_research_submit() returns trigger language plpgsql security definer set search_path = public as $$
declare r research; n int; m int;
begin
  if new.submitted_at is null or old.submitted_at is not null or new.role = 'owner' then return new; end if;
  select * into r from research where id = new.research_id;
  select count(*) filter (where submitted_at is not null), count(*) into n, m from research_people where research_id = new.research_id and role = 'member';
  perform push_enqueue(r.owner_id, 'research_submitted', null, jsonb_build_object('rid', r.id, 'name', push_name(new.user_id),
    'n', n, 'm', m, 'q', r.question, 'lang', r.language), 'rsubmit:' || r.id || ':' || new.user_id || ':' || extract(epoch from new.submitted_at)::bigint);
  return new;
end $$;
create trigger push_research_people after update of submitted_at on research_people for each row execute function push_on_research_submit();
revoke execute on function push_on_research_submit() from public, anon, authenticated;

create function push_on_research_brief() returns trigger language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if new.status <> 'done' or old.status = 'done' then return new; end if;
  for p in select user_id from research_people where research_id = new.id and user_id <> new.owner_id loop
    perform push_enqueue(p.user_id, 'research_brief', null, jsonb_build_object('rid', new.id, 'q', new.question, 'lang', new.language),
      'rbrief:' || new.id || ':' || p.user_id || ':' || extract(epoch from now())::bigint);
  end loop;
  return new;
end $$;
create trigger push_research after update of status on research for each row execute function push_on_research_brief();
revoke execute on function push_on_research_brief() from public, anon, authenticated;
