-- The owner's notepad (decided 2026-10-24): private notes only their author can read. A note can stand alone
-- (drafting a decision, then "Make it a room") or belong to a room the author owns. The room's analysis never
-- reads notes; the owner can choose to share a note into the room's context.

create table notes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references profiles (id) on delete cascade,
  room_id    uuid references rooms (id) on delete cascade,
  title      text not null default '' check (length(title) <= 120),
  body       text not null default '' check (length(body) <= 20000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index notes_user_idx on notes (user_id, updated_at desc);
create index notes_room_idx on notes (room_id);
create unique index notes_one_per_room on notes (user_id, room_id) where room_id is not null;

alter table notes enable row level security;
create policy "own notes: read" on notes for select using (user_id = (select auth.uid()));
create policy "own notes: write" on notes for insert
  with check (user_id = (select auth.uid()) and (room_id is null or room_role(room_id) = 'owner'));
create policy "own notes: change" on notes for update using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and (room_id is null or room_role(room_id) = 'owner'));
create policy "own notes: remove" on notes for delete using (user_id = (select auth.uid()));

create function touch_note() returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
create trigger notes_touch before update on notes for each row execute function touch_note();
revoke execute on function touch_note() from public, anon, authenticated;

-- At most 300 notes each.
create function limit_notes() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from notes where user_id = new.user_id) >= 300 then
    raise exception 'too_many_notes' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger notes_limit before insert on notes for each row execute function limit_notes();
revoke execute on function limit_notes() from public, anon, authenticated;

-- The analyst's help on notes counts against its own daily limit.
alter table usage_counts drop constraint usage_counts_kind_check;
alter table usage_counts add constraint usage_counts_kind_check
  check (kind in ('triage', 'criteria', 'decide', 'roles', 'question', 'brief', 'helper', 'notes'));
