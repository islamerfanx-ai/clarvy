-- Who's in the room (decided 2026-10-16, product-foundation section 0).
-- Each room says what kind of organisation it is and which roles take part. Every role has its own
-- invite link (with an optional limit on how many people use it) and an ask written for that role.
-- People join tagged with the role; their answer to the ask is private like the rest of their input.
-- Everyone counts equally and nothing is hidden by role.

-- ---------- Rooms: organisation type and roles ----------
alter table rooms add column org_type text
  check (org_type in ('corporation', 'government', 'international', 'club', 'custom'));
alter table rooms add column org_label text check (org_label is null or length(org_label) between 1 and 60);

-- roles: [{id, title, max (null = any number), ask, rapid (null | recommender | approver | performer)}]
create function roles_ok(r jsonb) returns boolean language sql immutable set search_path = public as $$
  select jsonb_typeof(r) = 'array' and jsonb_array_length(r) <= 12 and coalesce((
    select bool_and(
      jsonb_typeof(x) = 'object'
      and length(coalesce(x->>'id', '')) between 1 and 10
      and length(coalesce(x->>'title', '')) between 1 and 60
      and length(coalesce(x->>'ask', '')) <= 600
      and (x->'max' is null or jsonb_typeof(x->'max') = 'null'
           or (jsonb_typeof(x->'max') = 'number' and (x->>'max')::numeric between 1 and 500))
      and (x->>'rapid' is null or x->>'rapid' in ('recommender', 'approver', 'performer')))
    from jsonb_array_elements(r) x), true)
$$;
alter table rooms add column roles jsonb not null default '[]' constraint rooms_roles_shape check (roles_ok(roles));

-- ---------- Invites: one per role, with an optional limit ----------
alter table invites add column role_id text check (role_id is null or length(role_id) <= 10);
alter table invites add column max_uses integer check (max_uses is null or max_uses between 1 and 500);

-- ---------- Members carry the role they joined with ----------
alter table memberships add column role_id text check (role_id is null or length(role_id) <= 10);
alter table memberships add column role_title text check (role_title is null or length(role_title) <= 60);

-- Members can't retitle themselves; the owner can.
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
  if (new.rapid_role is distinct from old.rapid_role or new.role_id is distinct from old.role_id
      or new.role_title is distinct from old.role_title) and room_role(new.room_id) is distinct from 'owner' then
    raise exception 'only_owner_changes_roles' using errcode = 'insufficient_privilege';
  end if;
  if new.named_view_consent <> old.named_view_consent and new.user_id <> auth.uid() then
    raise exception 'consent_is_personal' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
revoke execute on function guard_membership_update() from public, anon, authenticated;

-- ---------- Inputs: the answer to the role's ask (private, like every input) ----------
alter table inputs add column role_answer text not null default '' check (length(role_answer) <= 4000);
-- Files the member added for the ask, read in their browser: [{name, text}]
alter table inputs add column role_files jsonb not null default '[]'
  check (jsonb_typeof(role_files) = 'array' and jsonb_array_length(role_files) <= 3 and length(role_files::text) <= 160000);

-- ---------- Joining with a role link ----------
create or replace function join_room(invite_token text, consent boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  inv invites;
  rm rooms;
  r jsonb;
begin
  if auth.uid() is null then
    raise exception 'sign_in_first' using errcode = 'insufficient_privilege';
  end if;
  select * into inv from invites where token = invite_token for update;
  if not found then
    raise exception 'invite_not_found' using errcode = 'no_data_found';
  end if;
  if exists (select 1 from memberships where room_id = inv.room_id and user_id = auth.uid()) then
    return inv.room_id;
  end if;
  select * into rm from rooms where id = inv.room_id;
  if inv.revoked or inv.expires_at <= now() or rm.status <> 'open' then
    raise exception 'invite_expired' using errcode = 'check_violation';
  end if;
  if inv.max_uses is not null and inv.uses >= inv.max_uses then
    raise exception 'role_full' using errcode = 'check_violation';
  end if;
  if inv.role_id is not null then
    select x into r from jsonb_array_elements(rm.roles) x where x->>'id' = inv.role_id;
  end if;
  insert into memberships (room_id, user_id, role, named_view_consent, role_id, role_title, rapid_role)
  values (inv.room_id, auth.uid(), inv.role, coalesce(consent, false), inv.role_id, r->>'title',
          case when rm.rapid then r->>'rapid' end);
  update invites set uses = uses + 1 where token = invite_token;
  return inv.room_id;
end $$;

-- ---------- What the join page shows: now with the role and its ask ----------
drop function invite_preview(text);
create function invite_preview(invite_token text)
returns table (room_id uuid, type room_type, type_label text, question text, language app_language, owner_name text,
               named_views boolean, role member_role, usable boolean, role_title text, role_ask text, is_full boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.type, r.type_label, r.question, r.language, nullif(trim(p.name), ''), r.named_views, i.role,
         not i.revoked and i.expires_at > now() and r.status = 'open'
           and (i.max_uses is null or i.uses < i.max_uses),
         x->>'title', nullif(x->>'ask', ''),
         i.max_uses is not null and i.uses >= i.max_uses
  from invites i join rooms r on r.id = i.room_id join profiles p on p.id = r.owner_id
  left join lateral (select y as x from jsonb_array_elements(r.roles) y where y->>'id' = i.role_id) rl on true
  where i.token = invite_token
$$;
revoke execute on function invite_preview(text) from public;
grant execute on function invite_preview(text) to anon, authenticated;

-- ---------- Roster: with the role title ----------
drop function room_roster(uuid);
create function room_roster(rid uuid)
returns table (user_id uuid, name text, role member_role, rapid_role text, submitted boolean, role_title text)
language sql stable security definer set search_path = public as $$
  select m.user_id, p.name, m.role, m.rapid_role,
         exists (select 1 from inputs i where i.room_id = m.room_id and i.user_id = m.user_id),
         m.role_title
  from memberships m join profiles p on p.id = m.user_id
  where m.room_id = rid and room_role(rid) is not null
  order by m.joined_at
$$;
revoke execute on function room_roster(uuid) from public, anon;
grant execute on function room_roster(uuid) to authenticated;

-- ---------- Daily limit for drafting role asks ----------
alter table usage_counts drop constraint usage_counts_kind_check;
alter table usage_counts add constraint usage_counts_kind_check check (kind in ('triage', 'criteria', 'decide', 'roles'));
