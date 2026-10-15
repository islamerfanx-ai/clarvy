-- Decision Rooms: thinking models, RAPID roles with a blocking objection, and the open trial.
-- docs/decision-models.md and docs/product-foundation.md (section 0) explain the decisions.

-- ---------- Thinking model per room ----------
-- The core five at launch; RAPID is an add-on (rooms.rapid), not a model.
alter table rooms add column model text not null default 'standard'
  check (model in ('standard', 'quick', 'wrap', 'cynefin', 'mece'));
alter table rooms add column rapid boolean not null default false;

-- ---------- RAPID roles ----------
-- Separate from the access role (owner/member/observer). The owner is always the D (decides).
-- recommender: proposes · approver: must agree, can object and block · performer: carries it out ·
-- null: input (advises, no vote, no veto).
alter table memberships add column rapid_role text
  check (rapid_role in ('recommender', 'approver', 'performer'));

-- Only the owner sets RAPID roles (the existing guard already stops members changing their access role).
create or replace function guard_membership_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if new.room_id <> old.room_id or new.user_id <> old.user_id then
    raise exception 'membership_identity_fixed' using errcode = 'check_violation';
  end if;
  if new.role <> old.role and (room_role(new.room_id) is distinct from 'owner' or 'owner' in (new.role, old.role)) then
    raise exception 'only_owner_changes_roles' using errcode = 'insufficient_privilege';
  end if;
  if new.rapid_role is distinct from old.rapid_role and room_role(new.room_id) is distinct from 'owner' then
    raise exception 'only_owner_changes_roles' using errcode = 'insufficient_privilege';
  end if;
  if new.named_view_consent <> old.named_view_consent and new.user_id <> auth.uid() then
    raise exception 'consent_is_personal' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

-- ---------- Objections (RAPID "agree" with a veto) ----------
-- An approver's open objection blocks Decide now until they withdraw it or the owner overrides it
-- on the record. Objections are visible to the whole room: in RAPID, who must agree is public.
create table objections (
  id              uuid primary key default gen_random_uuid(),
  room_id         uuid not null references rooms (id) on delete cascade,
  user_id         uuid not null references profiles (id) on delete cascade,
  reason          text not null check (length(trim(reason)) between 1 and 500),
  status          text not null default 'open' check (status in ('open', 'withdrawn', 'overridden')),
  override_reason text,
  created_at      timestamptz not null default now(),
  resolved_at     timestamptz,
  check (status <> 'overridden' or length(trim(coalesce(override_reason, ''))) > 0)
);
create index on objections (room_id);
alter table objections enable row level security;

create policy "members see objections" on objections for select using (room_role(room_id) is not null);
create policy "approvers object" on objections for insert
  with check (user_id = auth.uid()
              and exists (select 1 from memberships m where m.room_id = objections.room_id and m.user_id = auth.uid() and m.rapid_role = 'approver')
              and exists (select 1 from rooms r where r.id = objections.room_id and r.status = 'open' and r.rapid));

-- Withdraw your own; the owner overrides with a reason. Both through functions so the rules hold.
create function withdraw_objection(oid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update objections set status = 'withdrawn', resolved_at = now()
   where id = oid and user_id = auth.uid() and status = 'open';
  if not found then raise exception 'objection_not_found' using errcode = 'no_data_found'; end if;
end $$;

create function override_objection(oid uuid, why text) returns void
language plpgsql security definer set search_path = public as $$
declare o objections;
begin
  select * into o from objections where id = oid;
  if not found or room_role(o.room_id) is distinct from 'owner' then
    raise exception 'only_owner_decides' using errcode = 'insufficient_privilege';
  end if;
  if o.status <> 'open' then raise exception 'objection_not_open' using errcode = 'check_violation'; end if;
  update objections set status = 'overridden', override_reason = nullif(trim(why), ''), resolved_at = now() where id = oid;
end $$;

-- ---------- Roster with RAPID roles ----------
drop function room_roster(uuid);
create function room_roster(rid uuid)
returns table (user_id uuid, name text, role member_role, rapid_role text, submitted boolean)
language sql stable security definer set search_path = public as $$
  select m.user_id, p.name, m.role, m.rapid_role,
         exists (select 1 from inputs i where i.room_id = m.room_id and i.user_id = m.user_id)
  from memberships m join profiles p on p.id = m.user_id
  where m.room_id = rid and room_role(rid) is not null
  order by m.joined_at
$$;

-- ---------- Open trial ----------
-- Everyone gives a name and an email (unverified, stored on their profile) and may open rooms,
-- including accounts made without an email login (Supabase anonymous sign-in).
drop policy "create own workspace" on workspaces;
create policy "create own workspace" on workspaces for insert with check (owner_id = auth.uid());
drop policy "workspace members open rooms" on rooms;
create policy "workspace members open rooms" on rooms for insert
  with check (owner_id = auth.uid() and is_workspace_member(workspace_id));
alter table profiles add constraint profiles_email_shape check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');

revoke execute on function withdraw_objection(uuid), override_objection(uuid, text), room_roster(uuid) from public, anon;
grant execute on function withdraw_objection(uuid), override_objection(uuid, text), room_roster(uuid) to authenticated;
