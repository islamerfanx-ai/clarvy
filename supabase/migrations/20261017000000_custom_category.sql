-- Decision Rooms: custom categories. Business, Finance and Politics stay; owners can also name their own
-- (for example "Operations" or "Logistics"), and the analysis adapts to that name.

alter type room_type add value if not exists 'custom';
alter table rooms add column type_label text
  check (type_label is null or length(trim(type_label)) between 1 and 40);
-- A custom room must say what it is. (Compared as text so this works in the same transaction as the new enum value.)
alter table rooms add constraint rooms_custom_needs_label check (type::text <> 'custom' or type_label is not null);

-- My rooms and the invite preview also return the custom name.
drop function my_rooms();
create function my_rooms()
returns table (id uuid, type room_type, type_label text, question text, status room_status, role member_role, language app_language,
               review_date date, created_at timestamptz, quorum smallint, members bigint, submitted bigint,
               i_submitted boolean, has_verdict boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.type, r.type_label, r.question, r.status, m.role, r.language, r.review_date, r.created_at, r.quorum,
         (select count(*) from memberships x where x.room_id = r.id and x.role <> 'observer'),
         (select count(*) from inputs i where i.room_id = r.id),
         exists (select 1 from inputs i where i.room_id = r.id and i.user_id = auth.uid()),
         exists (select 1 from analyses a where a.room_id = r.id)
  from memberships m join rooms r on r.id = m.room_id
  where m.user_id = auth.uid()
  order by r.created_at desc
$$;

drop function invite_preview(text);
create function invite_preview(invite_token text)
returns table (room_id uuid, type room_type, type_label text, question text, language app_language, owner_name text,
               named_views boolean, role member_role, usable boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.type, r.type_label, r.question, r.language, nullif(trim(p.name), ''), r.named_views, i.role,
         not i.revoked and i.expires_at > now() and r.status = 'open'
  from invites i join rooms r on r.id = i.room_id join profiles p on p.id = r.owner_id
  where i.token = invite_token
$$;

revoke execute on function my_rooms(), invite_preview(text) from public, anon;
grant execute on function my_rooms() to authenticated;
grant execute on function invite_preview(text) to anon, authenticated;
