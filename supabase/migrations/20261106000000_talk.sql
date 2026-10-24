-- Talk space after the call (decided 2026-10-24). Opens once the call is made, so private input stays honest
-- before it. Messages are named and visible to the room: one thread for everyone, and one per plan step and per
-- tripwire. Anyone in the room can ask to reopen it when something changed; others back the request; the owner
-- decides. New messages show as a count in Your rooms.

create table room_messages (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references rooms (id) on delete cascade,
  user_id    uuid not null default auth.uid() references profiles (id) on delete cascade,
  thread     text not null default 'room' check (thread = 'room' or thread ~ '^(plan:[0-9a-f-]{36}|tripwire:[0-9]{1,2})$'),
  body       text not null check (length(trim(body)) between 1 and 2000),
  hidden     boolean not null default false,
  created_at timestamptz not null default now()
);
create index room_messages_room_idx on room_messages (room_id, created_at);
alter table room_messages enable row level security;
create policy "the room reads its talk" on room_messages for select using (room_role(room_id) is not null or assists(room_id, 'view'));
create policy "the room talks after the call" on room_messages for insert
  with check (user_id = (select auth.uid()) and (room_role(room_id) in ('owner', 'member') or assists(room_id, 'organise'))
              and exists (select 1 from rooms r where r.id = room_id and r.status in ('decided', 'reviewed')));
-- The owner can hide a message; the author can take theirs back. Nothing else changes.
create policy "owner or author hides" on room_messages for update
  using (room_role(room_id) = 'owner' or user_id = (select auth.uid()))
  with check (room_role(room_id) = 'owner' or user_id = (select auth.uid()));
create function guard_message() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.body <> old.body or new.room_id <> old.room_id or new.user_id <> old.user_id or new.thread <> old.thread or new.created_at <> old.created_at then
    raise exception 'messages_are_not_edited' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger room_messages_guard before update on room_messages for each row execute function guard_message();
revoke execute on function guard_message() from public, anon, authenticated;

-- A slow-down: at most 30 messages a person per room per hour.
create function limit_messages() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from room_messages where room_id = new.room_id and user_id = new.user_id and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'too_many_messages' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger room_messages_limit before insert on room_messages for each row execute function limit_messages();
revoke execute on function limit_messages() from public, anon, authenticated;

-- Talk with names (profiles are private otherwise).
create function room_talk(rid uuid) returns table (id uuid, user_id uuid, name text, thread text, body text, hidden boolean, created_at timestamptz, mine boolean)
language sql stable security definer set search_path = public as $$
  select m.id, m.user_id, p.name, m.thread, case when m.hidden then '' else m.body end, m.hidden, m.created_at, m.user_id = auth.uid()
  from room_messages m join profiles p on p.id = m.user_id
  where m.room_id = rid and (room_role(rid) is not null or assists(rid, 'view'))
  order by m.created_at
  limit 500
$$;
revoke execute on function room_talk(uuid) from public, anon;
grant execute on function room_talk(uuid) to authenticated;

-- When each person last read the room's talk, for the count in Your rooms.
create table room_reads (
  room_id      uuid not null references rooms (id) on delete cascade,
  user_id      uuid not null default auth.uid() references profiles (id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
alter table room_reads enable row level security;
create policy "own read marks" on room_reads for all using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create function mark_talk_read(rid uuid) returns void language sql volatile security definer set search_path = public as $$
  insert into room_reads (room_id, user_id, last_read_at) select rid, auth.uid(), now()
  where room_role(rid) is not null or assists(rid, 'view')
  on conflict (room_id, user_id) do update set last_read_at = now()
$$;
revoke execute on function mark_talk_read(uuid) from public, anon;
grant execute on function mark_talk_read(uuid) to authenticated;

-- ---------- Reopen requests: "something changed" ----------
create table reopen_requests (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references rooms (id) on delete cascade,
  user_id    uuid not null default auth.uid() references profiles (id) on delete cascade,
  reason     text not null check (length(trim(reason)) between 3 and 600),
  status     text not null default 'open' check (status in ('open', 'reopened', 'declined')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index reopen_requests_room_idx on reopen_requests (room_id);
create unique index reopen_one_open_each on reopen_requests (room_id, user_id) where status = 'open';
create table reopen_backers (
  request_id uuid not null references reopen_requests (id) on delete cascade,
  user_id    uuid not null default auth.uid() references profiles (id) on delete cascade,
  primary key (request_id, user_id)
);
alter table reopen_requests enable row level security;
alter table reopen_backers enable row level security;
create policy "the room sees reopen requests" on reopen_requests for select using (room_role(room_id) is not null or assists(room_id, 'view'));
create policy "members ask to reopen" on reopen_requests for insert
  with check (user_id = (select auth.uid()) and room_role(room_id) in ('owner', 'member') and status = 'open'
              and exists (select 1 from rooms r where r.id = room_id and r.status in ('decided', 'reviewed')));
create policy "the room sees backers" on reopen_backers for select
  using (exists (select 1 from reopen_requests q where q.id = request_id and (room_role(q.room_id) is not null or assists(q.room_id, 'view'))));
create policy "members back a request" on reopen_backers for insert
  with check (user_id = (select auth.uid()) and exists (select 1 from reopen_requests q where q.id = request_id and q.status = 'open' and room_role(q.room_id) in ('owner', 'member')));
create policy "members withdraw their backing" on reopen_backers for delete using (user_id = (select auth.uid()));

create function room_reopen_requests(rid uuid) returns table (id uuid, name text, reason text, status text, created_at timestamptz, backers bigint, backed boolean, mine boolean)
language sql stable security definer set search_path = public as $$
  select q.id, p.name, q.reason, q.status, q.created_at,
         (select count(*) from reopen_backers b where b.request_id = q.id),
         exists (select 1 from reopen_backers b where b.request_id = q.id and b.user_id = auth.uid()),
         q.user_id = auth.uid()
  from reopen_requests q join profiles p on p.id = q.user_id
  where q.room_id = rid and (room_role(rid) is not null or assists(rid, 'view'))
  order by q.created_at desc
$$;
revoke execute on function room_reopen_requests(uuid) from public, anon;
grant execute on function room_reopen_requests(uuid) to authenticated;

-- The owner reopens the room (with or without a request) or declines a request. Reopening sends the room back to
-- 'open': members can change their answers and the owner runs the analysis again. Earlier calls stay on record;
-- sign-offs start fresh for the new call.
create function reopen_room(rid uuid, request_id uuid default null, decline boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if room_role(rid) is distinct from 'owner' then raise exception 'only_owner_reopens' using errcode = 'insufficient_privilege'; end if;
  if decline then
    update reopen_requests set status = 'declined', decided_at = now() where id = request_id and room_id = rid and status = 'open';
    return;
  end if;
  if not exists (select 1 from rooms where id = rid and status in ('decided', 'reviewed')) then
    raise exception 'room_not_decided' using errcode = 'check_violation';
  end if;
  perform set_config('app.room_trusted', 'on', true);
  update rooms set status = 'open', decide_requested_at = null, decide_started_at = null, decide_attempts = 0, decide_error = null, decide_stage = null where id = rid;
  delete from signoffs where room_id = rid;
  update reopen_requests set status = 'reopened', decided_at = now() where room_id = rid and status = 'open';
end $$;
revoke execute on function reopen_room(uuid, uuid, boolean) from public, anon;
grant execute on function reopen_room(uuid, uuid, boolean) to authenticated;

-- ---------- Your rooms: unread talk and open reopen requests ----------
drop function my_rooms();
create function my_rooms()
returns table (id uuid, type room_type, type_label text, question text, status room_status, role member_role, language app_language,
               review_date date, created_at timestamptz, quorum smallint, members bigint, submitted bigint,
               i_submitted boolean, has_verdict boolean,
               options jsonb, decide_by date, decide_error text, last_input timestamptz,
               decided_at timestamptz, final_label text, signed bigint, invited bigint, review_due boolean,
               unread bigint, reopen_asks bigint)
language sql stable security definer set search_path = public as $$
  select r.id, r.type, r.type_label, r.question, r.status, m.role, r.language, r.review_date, r.created_at, r.quorum,
         (select count(*) from memberships x where x.room_id = r.id and x.role <> 'observer'),
         (select count(*) from inputs i where i.room_id = r.id),
         exists (select 1 from inputs i where i.room_id = r.id and i.user_id = auth.uid()),
         exists (select 1 from analyses a where a.room_id = r.id),
         r.options, r.decide_by, r.decide_error,
         (select max(i.submitted_at) from inputs i where i.room_id = r.id),
         a.decided_at,
         (select o->>'label' from jsonb_array_elements(r.options) o where o->>'id' = a.final_option),
         (select count(*) from signoffs s where s.room_id = r.id),
         case when m.role = 'owner' then (select count(*) from invites v where v.room_id = r.id and v.person_name is not null and not v.revoked) end,
         review_round(r.id) is not null and r.review_date <= current_date,
         (select count(*) from room_messages x where x.room_id = r.id and not x.hidden and x.user_id <> auth.uid()
            and x.created_at > coalesce((select rr.last_read_at from room_reads rr where rr.room_id = r.id and rr.user_id = auth.uid()), '-infinity')),
         case when m.role = 'owner' then (select count(*) from reopen_requests q where q.room_id = r.id and q.status = 'open') end
  from memberships m join rooms r on r.id = m.room_id
  left join lateral (select x.decided_at, x.final_option from analyses x where x.room_id = r.id order by x.created_at desc limit 1) a on true
  where m.user_id = auth.uid()
  order by r.created_at desc
$$;
revoke execute on function my_rooms() from public, anon;
grant execute on function my_rooms() to authenticated;
