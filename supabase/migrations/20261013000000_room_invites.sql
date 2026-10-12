-- Decision Rooms v1: invite links and room validation.
--
-- An invite is a secret link token. Whoever holds the link can see the room's question and join
-- with the invite's role. The owner shares it by WhatsApp, email or copy-paste from their own device.

create table invites (
  token      text primary key default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  room_id    uuid not null references rooms (id) on delete cascade,
  role       member_role not null default 'member' check (role <> 'owner'),
  created_by uuid not null references profiles (id),
  expires_at timestamptz not null default now() + interval '30 days',
  revoked    boolean not null default false,
  uses       integer not null default 0,
  created_at timestamptz not null default now()
);
create index on invites (room_id);

alter table invites enable row level security;
create policy "owner sees invites" on invites for select using (room_role(room_id) = 'owner');
create policy "owner creates invites" on invites for insert
  with check (room_role(room_id) = 'owner' and created_by = auth.uid());
create policy "owner revokes invites" on invites for update
  using (room_role(room_id) = 'owner') with check (room_role(room_id) = 'owner');

-- What the join page shows before you join. Works signed out, so the link can say who's asking.
create function invite_preview(invite_token text)
returns table (room_id uuid, type room_type, question text, language app_language, owner_name text,
               named_views boolean, role member_role, usable boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.type, r.question, r.language, nullif(trim(p.name), ''), r.named_views, i.role,
         not i.revoked and i.expires_at > now() and r.status = 'open'
  from invites i join rooms r on r.id = i.room_id join profiles p on p.id = r.owner_id
  where i.token = invite_token
$$;

-- Join with a link. Returns the room id; joining twice is harmless.
create function join_room(invite_token text, consent boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  inv invites;
  st room_status;
begin
  if auth.uid() is null then
    raise exception 'sign_in_first' using errcode = 'insufficient_privilege';
  end if;
  select * into inv from invites where token = invite_token;
  if not found then
    raise exception 'invite_not_found' using errcode = 'no_data_found';
  end if;
  if exists (select 1 from memberships where room_id = inv.room_id and user_id = auth.uid()) then
    return inv.room_id;
  end if;
  select status into st from rooms where id = inv.room_id;
  if inv.revoked or inv.expires_at <= now() or st <> 'open' then
    raise exception 'invite_expired' using errcode = 'check_violation';
  end if;
  insert into memberships (room_id, user_id, role, named_view_consent)
  values (inv.room_id, auth.uid(), inv.role, coalesce(consent, false));
  update invites set uses = uses + 1 where token = invite_token;
  return inv.room_id;
end $$;

revoke execute on function invite_preview(text), join_room(text, boolean) from public, anon;
grant execute on function invite_preview(text) to anon, authenticated;
grant execute on function join_room(text, boolean) to authenticated;

-- Rooms: 2-6 options and 2-8 criteria, each with a unique id and a label; criteria weights are
-- whole numbers summing to 100. Options and criteria are frozen once anyone has given input,
-- because every input's weights are keyed to them.
create function validate_room() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if jsonb_array_length(new.options) not between 2 and 6 then
    raise exception 'room_needs_2_to_6_options' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(new.criteria) not between 2 and 8 then
    raise exception 'room_needs_2_to_8_criteria' using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(new.options || new.criteria) x
             where jsonb_typeof(x) <> 'object'
                or length(trim(coalesce(x ->> 'id', ''))) = 0
                or length(trim(coalesce(x ->> 'label', ''))) not between 1 and 200) then
    raise exception 'room_items_need_id_and_label' using errcode = 'check_violation';
  end if;
  if (select count(distinct x ->> 'id') from jsonb_array_elements(new.options) x) <> jsonb_array_length(new.options)
     or (select count(distinct x ->> 'id') from jsonb_array_elements(new.criteria) x) <> jsonb_array_length(new.criteria) then
    raise exception 'room_ids_must_be_unique' using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(new.criteria) x
             where jsonb_typeof(x -> 'weight') <> 'number'
                or (x ->> 'weight')::numeric <> trunc((x ->> 'weight')::numeric)
                or (x ->> 'weight')::numeric not between 0 and 100)
     or (select sum((x ->> 'weight')::numeric) from jsonb_array_elements(new.criteria) x) <> 100 then
    raise exception 'criteria_weights_must_sum_100' using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' and (new.options <> old.options or new.criteria <> old.criteria)
     and exists (select 1 from inputs where room_id = new.id) then
    raise exception 'room_has_inputs' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger rooms_validate before insert or update on rooms
  for each row execute function validate_room();
