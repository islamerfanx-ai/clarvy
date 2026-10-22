-- Organisations (decided 2026-10-22): the custom plan for groups of more than 10. An organisation is a
-- workspace of kind 'organisation', created only by the operator, with admins, members, departments,
-- a logo, an email domain and a private join link. Admins see people and the list of rooms (status and
-- call), never anyone's private answers.

-- ---------- Workspaces become personal or organisation ----------
alter table workspaces add column kind text not null default 'personal' check (kind in ('personal', 'organisation'));
alter table workspaces add column org_type text check (org_type is null or org_type in ('corporation', 'government', 'international', 'club', 'custom'));
alter table workspaces add column logo_url text check (logo_url is null or (length(logo_url) <= 500 and logo_url ~ '^https://'));
alter table workspaces add column email_domain text check (email_domain is null or email_domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$');
alter table workspaces add column domain_verified boolean not null default false;   -- set by the operator only
alter table workspaces add column join_token text unique default replace(gen_random_uuid()::text, '-', '');
alter table workspaces add column join_open boolean not null default false;
alter table workspaces add column memory_on boolean not null default false;          -- organisation memory, opt-in (later)

-- People can only create personal workspaces; organisations are made by the operator (service role).
drop policy "create own workspace" on workspaces;
create policy "create own workspace" on workspaces for insert with check (owner_id = (select auth.uid()) and kind = 'personal');

-- Organisation admins edit their organisation's name, logo and join link; the domain check and the kind
-- stay with the operator.
create function is_org_admin(wid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from workspace_members m join workspaces w on w.id = m.workspace_id
                 where m.workspace_id = wid and m.user_id = auth.uid() and m.role in ('owner', 'admin') and w.kind = 'organisation')
$$;
drop policy "owner edits workspace" on workspaces;
create policy "owner or org admin edits workspace" on workspaces for update
  using (owner_id = (select auth.uid()) or is_org_admin(id)) with check (owner_id = (select auth.uid()) or is_org_admin(id));
create function guard_workspace() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if new.kind <> old.kind or new.domain_verified <> old.domain_verified or new.owner_id <> old.owner_id
     or new.plan <> old.plan or new.email_domain is distinct from old.email_domain then
    raise exception 'operator_only' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger workspaces_guard before update on workspaces for each row execute function guard_workspace();
revoke execute on function guard_workspace() from public, anon, authenticated;

-- ---------- Departments ----------
create table departments (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces (id) on delete cascade,
  name         text not null check (length(trim(name)) between 1 and 80),
  created_at   timestamptz not null default now(),
  unique (workspace_id, name)
);
alter table departments enable row level security;
create policy "members see departments" on departments for select using (is_workspace_member(workspace_id));
create policy "admins add departments" on departments for insert with check (is_org_admin(workspace_id));
create policy "admins rename departments" on departments for update using (is_org_admin(workspace_id)) with check (is_org_admin(workspace_id));
create policy "admins remove departments" on departments for delete using (is_org_admin(workspace_id));

alter table workspace_members add column department_id uuid references departments (id) on delete set null;
create index workspace_members_department_idx on workspace_members (department_id);

-- Admins manage membership in their organisation (members can leave themselves); only the owner row is fixed.
drop policy "owner adds members" on workspace_members;
create policy "owner adds members" on workspace_members for insert
  with check (exists (select 1 from workspaces w where w.id = workspace_id and w.owner_id = (select auth.uid())) or is_org_admin(workspace_id));
create policy "admins change members" on workspace_members for update
  using (is_org_admin(workspace_id)) with check (is_org_admin(workspace_id) and role <> 'owner');
create policy "admins remove, members leave" on workspace_members for delete
  using ((is_org_admin(workspace_id) or user_id = (select auth.uid())) and role <> 'owner');

-- ---------- Invites by email ----------
create table org_invites (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references workspaces (id) on delete cascade,
  email         text not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 160),
  name          text check (name is null or length(name) <= 80),
  job_title     text check (job_title is null or length(job_title) <= 80),
  department_id uuid references departments (id) on delete set null,
  role          workspace_role not null default 'member' check (role <> 'owner'),
  invited_by    uuid references profiles (id) on delete set null,
  accepted_at   timestamptz,
  created_at    timestamptz not null default now(),
  unique (workspace_id, email)
);
create index org_invites_email_idx on org_invites (lower(email));
create index org_invites_invited_by_idx on org_invites (invited_by);
create index org_invites_department_idx on org_invites (department_id);
alter table org_invites enable row level security;
create policy "admins see invites" on org_invites for select using (is_org_admin(workspace_id));
create policy "admins invite" on org_invites for insert with check (is_org_admin(workspace_id) and invited_by = (select auth.uid()) and role <> 'owner');
create policy "admins edit invites" on org_invites for update using (is_org_admin(workspace_id)) with check (is_org_admin(workspace_id) and role <> 'owner');
create policy "admins cancel invites" on org_invites for delete using (is_org_admin(workspace_id));

-- On sign-in: join every organisation that invited this verified email, and any organisation whose
-- verified domain matches it. Returns how many were joined.
create function claim_org_invites() returns integer
language plpgsql security definer set search_path = public as $$
declare
  em text;
  n integer := 0;
  r record;
begin
  select lower(email) into em from auth.users where id = auth.uid() and not coalesce(is_anonymous, false) and email is not null;
  if em is null then return 0; end if;
  for r in select * from org_invites where lower(email) = em and accepted_at is null loop
    insert into workspace_members (workspace_id, user_id, role, department_id)
    values (r.workspace_id, auth.uid(), r.role, r.department_id)
    on conflict (workspace_id, user_id) do nothing;
    update org_invites set accepted_at = now() where id = r.id;
    update profiles set job_title = coalesce(nullif(job_title, ''), r.job_title) where id = auth.uid();
    n := n + 1;
  end loop;
  for r in select id from workspaces where kind = 'organisation' and domain_verified and email_domain = split_part(em, '@', 2) loop
    insert into workspace_members (workspace_id, user_id, role) values (r.id, auth.uid(), 'member')
    on conflict (workspace_id, user_id) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- The private join link.
create function join_org(token text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  w workspaces;
begin
  if auth.uid() is null or is_anon() then raise exception 'sign_in_first' using errcode = 'insufficient_privilege'; end if;
  select * into w from workspaces where join_token = token and kind = 'organisation';
  if not found or not w.join_open then raise exception 'org_link_closed' using errcode = 'check_violation'; end if;
  insert into workspace_members (workspace_id, user_id, role) values (w.id, auth.uid(), 'member') on conflict do nothing;
  return w.id;
end $$;

-- What a join link shows before joining (works signed out).
create function org_preview(token text) returns table (name text, logo_url text, usable boolean)
language sql stable security definer set search_path = public as $$
  select w.name, w.logo_url, w.join_open from workspaces w where w.join_token = token and w.kind = 'organisation'
$$;

-- My organisations, with my role.
create function my_orgs() returns table (id uuid, name text, logo_url text, org_type text, role workspace_role, members bigint)
language sql stable security definer set search_path = public as $$
  select w.id, w.name, w.logo_url, w.org_type, m.role, (select count(*) from workspace_members x where x.workspace_id = w.id)
  from workspace_members m join workspaces w on w.id = m.workspace_id
  where m.user_id = auth.uid() and w.kind = 'organisation'
  order by w.name
$$;

-- The colleague directory: name, title, department and work email, for members of the same organisation.
create function org_directory(wid uuid) returns table (user_id uuid, name text, job_title text, email text, department_id uuid, department text, role workspace_role)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.job_title, p.email, m.department_id, d.name, m.role
  from workspace_members m join profiles p on p.id = m.user_id left join departments d on d.id = m.department_id
  join workspaces w on w.id = m.workspace_id
  where m.workspace_id = wid and w.kind = 'organisation' and is_workspace_member(wid)
  order by p.name
$$;

-- For admins: the organisation's rooms (status and the call), never anyone's answers.
create function org_rooms(wid uuid) returns table (id uuid, question text, status room_status, owner_name text, created_at timestamptz,
                                                   members bigint, answered bigint, decided_at timestamptz, final_label text, review_date date)
language sql stable security definer set search_path = public as $$
  select r.id, r.question, r.status, p.name, r.created_at,
         (select count(*) from memberships x where x.room_id = r.id and x.role <> 'observer'),
         (select count(*) from inputs i where i.room_id = r.id),
         a.decided_at,
         (select o->>'label' from jsonb_array_elements(r.options) o where o->>'id' = a.final_option),
         r.review_date
  from rooms r join profiles p on p.id = r.owner_id
  left join lateral (select x.decided_at, x.final_option from analyses x where x.room_id = r.id order by x.created_at desc limit 1) a on true
  where r.workspace_id = wid and is_org_admin(wid)
  order by r.created_at desc
$$;

revoke execute on function is_org_admin(uuid), claim_org_invites(), join_org(text), org_preview(text), my_orgs(), org_directory(uuid), org_rooms(uuid) from public, anon;
grant execute on function is_org_admin(uuid), claim_org_invites(), join_org(text), my_orgs(), org_directory(uuid), org_rooms(uuid) to authenticated;
grant execute on function org_preview(text) to anon, authenticated;

-- ---------- Reports carry the organisation's name and logo ----------
create or replace function room_report(rid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'room', jsonb_build_object('question', r.question, 'type', r.type, 'type_label', r.type_label, 'language', r.language,
                               'context', r.context, 'options', r.options, 'links', r.links, 'model', r.model, 'rapid', r.rapid,
                               'status', r.status, 'review_date', r.review_date, 'created_at', r.created_at,
                               'override_rule', r.override_rule, 'report_mode', r.report_mode,
                               'override_role', (select x->>'title' from jsonb_array_elements(r.roles) x where x->>'id' = r.override_role_id)),
    'org', (select case when w.kind = 'organisation' then jsonb_build_object('name', w.name, 'logo_url', w.logo_url) end from workspaces w where w.id = r.workspace_id),
    'owner_name', nullif(trim(p.name), ''),
    'members', (select count(*) from memberships m where m.room_id = r.id and m.role <> 'observer'),
    'answered', (select count(*) from inputs i where i.room_id = r.id),
    'analysis', (select jsonb_build_object('frame', a.frame, 'verdict', a.verdict, 'disagreement_map', a.disagreement_map,
                                           'confidence', a.confidence, 'owner_decision', a.owner_decision,
                                           'override_reason', a.override_reason, 'final_option', a.final_option,
                                           'decided_at', a.decided_at, 'created_at', a.created_at)
                 from analyses a where a.room_id = r.id order by a.created_at desc limit 1),
    'signoffs', (select coalesce(jsonb_object_agg(s.stance, s.n), '{}'::jsonb)
                 from (select stance, count(*) n from signoffs where room_id = r.id group by stance) s),
    'objections', (select coalesce(jsonb_agg(jsonb_build_object(
                      'by_role', coalesce(m.role_title, 'Approver'), 'reason', ob.reason, 'option_id', ob.option_id,
                      'status', ob.status, 'override_reason', ob.override_reason,
                      'created_at', ob.created_at, 'resolved_at', ob.resolved_at) order by ob.created_at), '[]'::jsonb)
                   from objections ob left join memberships m on m.room_id = ob.room_id and m.user_id = ob.user_id
                   where ob.room_id = r.id),
    'plan', (select coalesce(jsonb_agg(jsonb_build_object(
                'kind', pi.kind, 'title', pi.title, 'owner', coalesce(pi.owner_label, mm.role_title, pp.name),
                'due_date', pi.due_date, 'status', pi.status) order by pi.due_date nulls last, pi.position), '[]'::jsonb)
             from plan_items pi
             left join memberships mm on mm.room_id = pi.room_id and mm.user_id = pi.assignee
             left join profiles pp on pp.id = pi.assignee
             where pi.room_id = r.id),
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object(
                   'review_no', o.review_no, 'logged_at', o.logged_at, 'what_happened', o.what_happened, 'rating', o.rating,
                   'lessons', o.lessons, 'plan_total', o.plan_total, 'plan_done', o.plan_done, 'plan_blocked', o.plan_blocked,
                   'raters', s.n, 'avg', case when s.n > 0 then round(s.avg, 1) end,
                   'min', case when s.n >= 3 then s.mn end, 'max', case when s.n >= 3 then s.mx end) order by o.review_no), '[]'::jsonb)
                from outcomes o
                left join lateral (select count(*) n, avg(rating) avg, min(rating) mn, max(rating) mx
                                   from review_ratings x where x.room_id = o.room_id and x.review_no = o.review_no) s on true
                where o.room_id = r.id)
  )
  from rooms r join profiles p on p.id = r.owner_id
  where r.id = rid
$$;
revoke execute on function room_report(uuid) from public, anon, authenticated;

-- ---------- The operator's list of organisations (admin page) ----------
create function admin_orgs() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', w.id, 'name', w.name, 'org_type', w.org_type, 'logo_url', w.logo_url, 'email_domain', w.email_domain,
    'domain_verified', w.domain_verified, 'join_open', w.join_open, 'created_at', w.created_at,
    'members', (select count(*) from workspace_members m where m.workspace_id = w.id),
    'admins', (select coalesce(jsonb_agg(p.email), '[]'::jsonb) from workspace_members m join profiles p on p.id = m.user_id
               where m.workspace_id = w.id and m.role in ('owner', 'admin')),
    'pending', (select count(*) from org_invites i where i.workspace_id = w.id and i.accepted_at is null),
    'rooms', (select count(*) from rooms r where r.workspace_id = w.id)
  ) order by w.created_at desc), '[]'::jsonb)
  from workspaces w where w.kind = 'organisation'
$$;
revoke execute on function admin_orgs() from public, anon, authenticated;
grant execute on function admin_orgs() to service_role;
