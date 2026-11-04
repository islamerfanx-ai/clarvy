-- File tools (2026-11-04): the owner chooses who sees each file.
--   everyone : every member of the room (as before)
--   some     : only the people (personal invite tokens) and roles (room role ids) picked
--   analysis : nobody reads it; only the analysis uses it (the server reads with the service role)
-- The owner, the person who uploaded it and assistants who may view the room always see it.

alter table attachments add column visibility text not null default 'everyone'
  check (visibility in ('everyone', 'some', 'analysis'));
alter table attachments add column visible_roles text[] not null default '{}'
  check (cardinality(visible_roles) <= 20);
alter table attachments add column visible_tokens text[] not null default '{}'
  check (cardinality(visible_tokens) <= 50);

create function can_read_attachment(a_room uuid, a_by uuid, a_vis text, a_roles text[], a_tokens text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when (select auth.uid()) is null then false
    when room_role(a_room) = 'owner' or a_by = (select auth.uid()) then true
    when room_role(a_room) is null then false
    when a_vis = 'everyone' then true
    when a_vis = 'some' then exists (
        select 1 from memberships m
        where m.room_id = a_room and m.user_id = (select auth.uid()) and m.role_id is not null and m.role_id = any (a_roles))
      or exists (
        select 1 from invites v
        where v.room_id = a_room and v.joined_by = (select auth.uid()) and v.token = any (a_tokens))
    else false
  end
$$;
revoke all on function can_read_attachment(uuid, uuid, text, text[], text[]) from public, anon;
grant execute on function can_read_attachment(uuid, uuid, text, text[], text[]) to authenticated;

drop policy "members read files" on attachments;
create policy "members read files they may see" on attachments for select
  using (can_read_attachment(room_id, uploaded_by, visibility, visible_roles, visible_tokens));

-- The owner can change who sees a file later.
create policy "owner changes who sees files" on attachments for update
  using (room_role(room_id) = 'owner') with check (room_role(room_id) = 'owner');

-- The stored file follows the same rule as its row.
drop policy "members read room files" on storage.objects;
create policy "members read room files they may see" on storage.objects for select
  using (bucket_id = 'room-files' and exists (
    select 1 from attachments a
    where a.storage_path = storage.objects.name
      and can_read_attachment(a.room_id, a.uploaded_by, a.visibility, a.visible_roles, a.visible_tokens)));
