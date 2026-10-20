-- Release 1 (decided 2026-10-20): personal invites, saved contacts, comments under ratings,
-- a "decide by" date, and what Your rooms needs for search and "Needs attention".

-- ---------- Decide by ----------
alter table rooms add column decide_by date;

-- ---------- Personal invites ----------
-- A personal invite is an invite with a person on it: one link per person, used once. The join page
-- greets them by name and fills in their contact while the link is unused. Role links stay as they
-- were for rooms that already use them.
alter table invites add column person_name text check (person_name is null or length(trim(person_name)) between 1 and 80);
alter table invites add column person_contact text check (person_contact is null or length(person_contact) <= 120);
alter table invites add column joined_by uuid references profiles (id) on delete set null;
alter table invites add constraint invites_personal_once check (person_name is null or coalesce(max_uses, 0) = 1);
create index invites_joined_by_idx on invites (joined_by);

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
    if inv.person_name is not null then
      raise exception 'invite_used' using errcode = 'check_violation';
    end if;
    raise exception 'role_full' using errcode = 'check_violation';
  end if;
  if inv.role_id is not null then
    select x into r from jsonb_array_elements(rm.roles) x where x->>'id' = inv.role_id;
  end if;
  insert into memberships (room_id, user_id, role, named_view_consent, role_id, role_title, rapid_role)
  values (inv.room_id, auth.uid(), inv.role, coalesce(consent, false), inv.role_id, r->>'title',
          case when rm.rapid then r->>'rapid' end);
  update invites set uses = uses + 1,
         joined_by = case when person_name is not null then auth.uid() else joined_by end
  where token = invite_token;
  return inv.room_id;
end $$;

drop function invite_preview(text);
create function invite_preview(invite_token text)
returns table (room_id uuid, type room_type, type_label text, question text, language app_language, owner_name text,
               named_views boolean, role member_role, usable boolean, role_title text, role_ask text, is_full boolean,
               person_name text, person_contact text)
language sql stable security definer set search_path = public as $$
  select r.id, r.type, r.type_label, r.question, r.language, nullif(trim(p.name), ''), r.named_views, i.role,
         not i.revoked and i.expires_at > now() and r.status = 'open'
           and (i.max_uses is null or i.uses < i.max_uses),
         x->>'title', nullif(x->>'ask', ''),
         i.max_uses is not null and i.uses >= i.max_uses,
         i.person_name,
         case when i.uses = 0 then i.person_contact end   -- only while the link is unused
  from invites i join rooms r on r.id = i.room_id join profiles p on p.id = r.owner_id
  left join lateral (select y as x from jsonb_array_elements(r.roles) y where y->>'id' = i.role_id) rl on true
  where i.token = invite_token
$$;
revoke execute on function invite_preview(text) from public;
grant execute on function invite_preview(text) to anon, authenticated;

-- ---------- Saved contacts (the owner's address book) ----------
create table contacts (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references profiles (id) on delete cascade,
  name       text not null check (length(trim(name)) between 1 and 80),
  contact    text not null default '' check (length(contact) <= 120),
  role_title text check (role_title is null or length(role_title) <= 60),
  used_at    timestamptz not null default now(),
  unique (owner_id, name, contact)
);
alter table contacts enable row level security;
create policy "own contacts: read" on contacts for select using (owner_id = (select auth.uid()));
create policy "own contacts: add" on contacts for insert with check (owner_id = (select auth.uid()));
-- At most 500 saved contacts each.
create function limit_contacts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from contacts where owner_id = new.owner_id) >= 500 then
    raise exception 'too_many_contacts' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger contacts_limit before insert on contacts for each row execute function limit_contacts();
revoke execute on function limit_contacts() from public, anon, authenticated;
create policy "own contacts: change" on contacts for update using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "own contacts: remove" on contacts for delete using (owner_id = (select auth.uid()));

-- ---------- Comments under ratings (private, like the rest of an input) ----------
-- {criterion_id: "short note"}
alter table inputs add column comments jsonb not null default '{}'
  check (jsonb_typeof(comments) = 'object' and length(comments::text) <= 6000);

-- ---------- Your rooms: search and "Needs attention" ----------
drop function my_rooms();
create function my_rooms()
returns table (id uuid, type room_type, type_label text, question text, status room_status, role member_role, language app_language,
               review_date date, created_at timestamptz, quorum smallint, members bigint, submitted bigint,
               i_submitted boolean, has_verdict boolean,
               options jsonb, decide_by date, decide_error text, last_input timestamptz,
               decided_at timestamptz, final_label text, signed bigint, invited bigint)
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
         case when m.role = 'owner' then (select count(*) from invites v where v.room_id = r.id and v.person_name is not null and not v.revoked) end
  from memberships m join rooms r on r.id = m.room_id
  left join lateral (select x.decided_at, x.final_option from analyses x where x.room_id = r.id order by x.created_at desc limit 1) a on true
  where m.user_id = auth.uid()
  order by r.created_at desc
$$;
revoke execute on function my_rooms() from public, anon;
grant execute on function my_rooms() to authenticated;
