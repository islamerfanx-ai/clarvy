-- Assistants (decided 2026-10-24): an owner lets a PA or secretary manage their rooms. The assistant runs the
-- process but never makes the call: they can set up rooms for the owner, invite people, send reminders, manage
-- the plan and see status. They can't answer, accept or override the call, sign off, change the decision rule,
-- or see anyone's private answers (nobody can). Levels: view < organise < run (run may also press Decide now).
-- They are not room members, so they never count as answering. Members see who set the room up; the owner sees
-- everything the assistant did.

create table assistants (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references profiles (id) on delete cascade,
  assistant_id uuid not null references profiles (id) on delete cascade,
  level        text not null default 'organise' check (level in ('view', 'organise', 'run')),
  all_rooms    boolean not null default true,
  room_ids     uuid[] not null default '{}' check (cardinality(room_ids) <= 200),
  expires_at   timestamptz,
  created_at   timestamptz not null default now(),
  revoked_at   timestamptz,
  check (owner_id <> assistant_id)
);
create unique index assistants_one_live on assistants (owner_id, assistant_id) where revoked_at is null;
create index assistants_assistant_idx on assistants (assistant_id);
alter table assistants enable row level security;
create policy "owner and assistant see it" on assistants for select
  using (owner_id = (select auth.uid()) or assistant_id = (select auth.uid()));
create policy "owner changes it" on assistants for update
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
-- Either side can end it (the assistant can step down).
create policy "owner removes it" on assistants for delete using (owner_id = (select auth.uid()));

create function level_rank(l text) returns int language sql immutable set search_path = public as $$
  select case l when 'view' then 1 when 'organise' then 2 when 'run' then 3 else 0 end
$$;

-- Does the signed-in person assist this room's owner at this level or above? Inside an organisation the
-- assistant must also be a member of that organisation.
create function assists(rid uuid, need text default 'view') returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from rooms r
    join assistants a on a.owner_id = r.owner_id and a.assistant_id = auth.uid()
    join workspaces w on w.id = r.workspace_id
    where r.id = rid and a.revoked_at is null and (a.expires_at is null or a.expires_at > now())
      and (a.all_rooms or rid = any(a.room_ids)) and level_rank(a.level) >= level_rank(need)
      and (w.kind <> 'organisation' or exists (select 1 from workspace_members m where m.workspace_id = w.id and m.user_id = auth.uid())))
$$;
-- Same, for opening a new room on the owner's behalf (all-rooms assistants only).
create function assists_owner(oid uuid, need text default 'organise') returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from assistants a where a.owner_id = oid and a.assistant_id = auth.uid() and a.revoked_at is null
                 and (a.expires_at is null or a.expires_at > now()) and a.all_rooms and level_rank(a.level) >= level_rank(need))
$$;
revoke execute on function assists(uuid, text), assists_owner(uuid, text) from public, anon;
grant execute on function assists(uuid, text), assists_owner(uuid, text) to authenticated;

-- The owner adds an assistant by the email they sign in with.
create function add_assistant(email text, level text default 'organise', all_rooms boolean default true,
                              room_ids uuid[] default '{}', expires_at timestamptz default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  aid uuid;
  new_id uuid;
begin
  if auth.uid() is null then raise exception 'sign_in_first' using errcode = 'insufficient_privilege'; end if;
  select p.id into aid from profiles p join auth.users u on u.id = p.id
  where lower(u.email) = lower(trim(add_assistant.email)) and not coalesce(u.is_anonymous, false);
  if aid is null then raise exception 'no_account' using errcode = 'no_data_found'; end if;
  if aid = auth.uid() then raise exception 'not_yourself' using errcode = 'check_violation'; end if;
  if exists (select 1 from unnest(add_assistant.room_ids) x where not exists (select 1 from rooms r where r.id = x and r.owner_id = auth.uid())) then
    raise exception 'not_your_room' using errcode = 'insufficient_privilege';
  end if;
  update assistants set revoked_at = now() where owner_id = auth.uid() and assistant_id = aid and revoked_at is null;
  insert into assistants (owner_id, assistant_id, level, all_rooms, room_ids, expires_at)
  values (auth.uid(), aid, add_assistant.level, add_assistant.all_rooms, add_assistant.room_ids, add_assistant.expires_at)
  returning id into new_id;
  return new_id;
end $$;
revoke execute on function add_assistant(text, text, boolean, uuid[], timestamptz) from public, anon;
grant execute on function add_assistant(text, text, boolean, uuid[], timestamptz) to authenticated;

-- Names for both sides (profiles are private otherwise).
create function my_assistants() returns table (id uuid, side text, other_id uuid, other_name text, other_email text, level text,
                                              all_rooms boolean, room_ids uuid[], expires_at timestamptz, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, case when a.owner_id = auth.uid() then 'mine' else 'helping' end,
         case when a.owner_id = auth.uid() then a.assistant_id else a.owner_id end, p.name, p.email,
         a.level, a.all_rooms, a.room_ids, a.expires_at, a.created_at
  from assistants a join profiles p on p.id = case when a.owner_id = auth.uid() then a.assistant_id else a.owner_id end
  where (a.owner_id = auth.uid() or a.assistant_id = auth.uid()) and a.revoked_at is null and (a.expires_at is null or a.expires_at > now())
  order by a.created_at desc
$$;
create function stop_assisting(aid uuid) returns void
language sql security definer set search_path = public as $$
  update assistants set revoked_at = now() where id = aid and (owner_id = auth.uid() or assistant_id = auth.uid()) and revoked_at is null
$$;
revoke execute on function my_assistants(), stop_assisting(uuid) from public, anon;
grant execute on function my_assistants(), stop_assisting(uuid) to authenticated;

-- Where an assistant can open a room for the owner: the owner's personal workspace, and organisations both belong to.
create function assist_targets() returns table (owner_id uuid, owner_name text, workspace_id uuid, workspace_name text, kind text)
language sql stable security definer set search_path = public as $$
  select a.owner_id, p.name, w.id, w.name, w.kind
  from assistants a join profiles p on p.id = a.owner_id
  join workspace_members om on om.user_id = a.owner_id join workspaces w on w.id = om.workspace_id
  where a.assistant_id = auth.uid() and a.revoked_at is null and (a.expires_at is null or a.expires_at > now())
    and a.all_rooms and level_rank(a.level) >= 2
    and (w.kind = 'personal' and w.owner_id = a.owner_id
         or w.kind = 'organisation' and exists (select 1 from workspace_members m where m.workspace_id = w.id and m.user_id = auth.uid()))
  order by p.name, w.kind desc
$$;
revoke execute on function assist_targets() from public, anon;
grant execute on function assist_targets() to authenticated;

-- ---------- Who set the room up ----------
alter table rooms add column created_by uuid references profiles (id) on delete set null default auth.uid();

-- ---------- What assistants may do: extra policies (the owner's own rules are unchanged) ----------
create policy "assistants read rooms" on rooms for select using (assists(id, 'view'));
create policy "assistants open rooms for the owner" on rooms for insert
  with check (assists_owner(owner_id, 'organise') and created_by = (select auth.uid())
              and exists (select 1 from assist_targets() x where x.owner_id = rooms.owner_id and x.workspace_id = rooms.workspace_id));
create policy "assistants edit rooms" on rooms for update using (assists(id, 'organise')) with check (assists(id, 'organise'));
create policy "assistants see memberships" on memberships for select using (assists(room_id, 'view'));
create policy "assistants see invites" on invites for select using (assists(room_id, 'organise'));
create policy "assistants create invites" on invites for insert with check (assists(room_id, 'organise') and created_by = (select auth.uid()));
create policy "assistants change invites" on invites for update using (assists(room_id, 'organise')) with check (assists(room_id, 'organise'));
create policy "assistants see the plan" on plan_items for select using (assists(room_id, 'view'));
create policy "assistants add plan items" on plan_items for insert
  with check (assists(room_id, 'organise') and created_by = (select auth.uid())
              and (assignee is null or exists (select 1 from memberships m where m.room_id = plan_items.room_id and m.user_id = plan_items.assignee)));
create policy "assistants update plan items" on plan_items for update using (assists(room_id, 'organise')) with check (assists(room_id, 'organise'));
create policy "assistants remove plan items" on plan_items for delete using (assists(room_id, 'organise'));
create policy "assistants read files" on attachments for select using (assists(room_id, 'view'));
create policy "assistants add files" on attachments for insert with check (assists(room_id, 'organise') and uploaded_by = (select auth.uid()));
create policy "assistants read the call" on analyses for select using (assists(room_id, 'view'));
create policy "assistants see objections" on objections for select using (assists(room_id, 'view'));

-- An assistant may edit the plan like the owner.
create or replace function guard_plan_item() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if auth.uid() is null or room_role(new.room_id) = 'owner' or assists(new.room_id, 'organise') then return new; end if;
  if new.room_id <> old.room_id or new.kind <> old.kind or new.title <> old.title
     or new.assignee is distinct from old.assignee or new.owner_label is distinct from old.owner_label
     or new.due_date is distinct from old.due_date or new.position <> old.position or new.created_by <> old.created_by then
    raise exception 'only_owner_edits_plan' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

-- Assistants never change the decision rule, the owner, confidentiality or the thinking model.
create function guard_assistant_room() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or auth.uid() = new.owner_id then return new; end if;
  if tg_op = 'UPDATE' and (new.owner_id is distinct from old.owner_id or new.override_rule is distinct from old.override_rule
     or new.override_role_id is distinct from old.override_role_id or new.strict_confidential is distinct from old.strict_confidential
     or new.rapid is distinct from old.rapid or new.model is distinct from old.model or new.created_by is distinct from old.created_by) then
    raise exception 'owner_only_setting' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger rooms_guard_assistant before update on rooms for each row execute function guard_assistant_room();
revoke execute on function guard_assistant_room() from public, anon, authenticated;

-- ---------- Room page helpers: the roster, reminders and the assistant's level ----------
create or replace function room_roster(rid uuid)
returns table (user_id uuid, name text, role member_role, rapid_role text, submitted boolean, role_title text)
language sql stable security definer set search_path = public as $$
  select m.user_id, p.name, m.role, m.rapid_role,
         exists (select 1 from inputs i where i.room_id = m.room_id and i.user_id = m.user_id),
         m.role_title
  from memberships m join profiles p on p.id = m.user_id
  where m.room_id = rid and (room_role(rid) is not null or assists(rid, 'view'))
  order by m.joined_at
$$;
create or replace function room_nudges(rid uuid)
returns table (invite_token text, user_id uuid, n bigint, last_at timestamptz)
language sql stable security definer set search_path = public as $$
  select n.invite_token, n.user_id, count(*), max(n.sent_at)
  from nudges n where n.room_id = rid and (room_role(rid) = 'owner' or assists(rid, 'organise'))
  group by n.invite_token, n.user_id
$$;
create function my_assist_level(rid uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when assists(rid, 'run') then 'run' when assists(rid, 'organise') then 'organise' when assists(rid, 'view') then 'view' end
$$;
-- Who set the room up, for everyone in it (shown when it wasn't the owner).
create function room_setup_by(rid uuid) returns text
language sql stable security definer set search_path = public as $$
  select nullif(trim(p.name), '') from rooms r join profiles p on p.id = r.created_by
  where r.id = rid and r.created_by is distinct from r.owner_id and (room_role(rid) is not null or assists(rid, 'view'))
$$;
revoke execute on function my_assist_level(uuid), room_setup_by(uuid) from public, anon;
grant execute on function my_assist_level(uuid), room_setup_by(uuid) to authenticated;

-- The rooms an assistant helps with, for their Your rooms page.
create function assisted_rooms() returns table (id uuid, question text, status room_status, owner_name text, level text, created_at timestamptz,
                                               members bigint, submitted bigint, decide_by date, has_verdict boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.question, r.status, p.name, my_assist_level(r.id), r.created_at,
         (select count(*) from memberships x where x.room_id = r.id and x.role <> 'observer'),
         (select count(*) from inputs i where i.room_id = r.id),
         r.decide_by, exists (select 1 from analyses a where a.room_id = r.id)
  from rooms r join profiles p on p.id = r.owner_id
  where r.owner_id in (select a.owner_id from assistants a where a.assistant_id = auth.uid() and a.revoked_at is null)
    and assists(r.id, 'view')
  order by r.created_at desc
  limit 200
$$;
revoke execute on function assisted_rooms() from public, anon;
grant execute on function assisted_rooms() to authenticated;

-- ---------- Everything an assistant does is logged for the owner ----------
create table assistant_log (
  id           bigint generated always as identity primary key,
  room_id      uuid references rooms (id) on delete cascade,
  owner_id     uuid not null references profiles (id) on delete cascade,
  assistant_id uuid references profiles (id) on delete set null,
  action       text not null check (length(action) <= 40),
  detail       text check (length(detail) <= 300),
  at           timestamptz not null default now()
);
create index assistant_log_owner_idx on assistant_log (owner_id, at desc);
create index assistant_log_room_idx on assistant_log (room_id);
alter table assistant_log enable row level security;
create policy "owner and assistant read the log" on assistant_log for select
  using (owner_id = (select auth.uid()) or assistant_id = (select auth.uid()));

create function log_assistant() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rid uuid := coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'room_id', (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id')::uuid;
  oid uuid;
  what text;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  select owner_id into oid from rooms where id = rid;
  if oid is null or oid = auth.uid() then return coalesce(new, old); end if;
  if not assists(rid, 'view') then return coalesce(new, old); end if;
  what := case tg_table_name
    when 'rooms' then case when tg_op = 'INSERT' then 'opened the room' else 'edited the room' end
    when 'invites' then case when tg_op = 'INSERT' then 'invited ' || coalesce(to_jsonb(new)->>'person_name', 'people') else 'changed an invite' end
    when 'plan_items' then case tg_op when 'INSERT' then 'added a plan step' when 'DELETE' then 'removed a plan step' else 'updated a plan step' end
    when 'attachments' then 'added a file'
    else tg_table_name end;
  insert into assistant_log (room_id, owner_id, assistant_id, action, detail)
  values (rid, oid, auth.uid(), tg_op, what);
  return coalesce(new, old);
end $$;
create trigger rooms_log_assistant after insert or update on rooms for each row execute function log_assistant();
create trigger invites_log_assistant after insert or update on invites for each row execute function log_assistant();
create trigger plan_items_log_assistant after insert or update or delete on plan_items for each row execute function log_assistant();
create trigger attachments_log_assistant after insert on attachments for each row execute function log_assistant();
revoke execute on function log_assistant() from public, anon, authenticated;

-- The room's log, for its owner (and the assistant's own entries).
create function room_assistant_log(rid uuid) returns table (who text, detail text, at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.name, l.detail, l.at from assistant_log l left join profiles p on p.id = l.assistant_id
  where l.room_id = rid and (l.owner_id = auth.uid() or l.assistant_id = auth.uid())
  order by l.at desc limit 50
$$;
revoke execute on function room_assistant_log(uuid) from public, anon;
grant execute on function room_assistant_log(uuid) to authenticated;
