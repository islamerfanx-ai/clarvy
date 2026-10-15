-- Decision Rooms: useful links, and shareable reports.
-- Owner links are part of the room (everyone sees them). Member links travel with their private answers:
-- only they and the server read them; the analysis may cite them as facts.
-- A report share link lets anyone (board, advisers) read the call and its reasoning, never who said what.

alter table rooms add column links jsonb not null default '[]'
  check (jsonb_typeof(links) = 'array' and jsonb_array_length(links) <= 10);
alter table inputs add column links text[] not null default '{}'
  check (coalesce(array_length(links, 1), 0) <= 5);

create table report_shares (
  token      text primary key default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  room_id    uuid not null references rooms (id) on delete cascade,
  created_by uuid not null references profiles (id),
  revoked    boolean not null default false,
  created_at timestamptz not null default now()
);
create index on report_shares (room_id);
alter table report_shares enable row level security;
create policy "owner sees report links" on report_shares for select using (room_role(room_id) = 'owner');
create policy "owner creates report links" on report_shares for insert
  with check (room_role(room_id) = 'owner' and created_by = auth.uid());
create policy "owner switches report links off" on report_shares for update
  using (room_role(room_id) = 'owner') with check (room_role(room_id) = 'owner');

-- The report behind a share link (or for a member, by room id). Aggregates only: the call, the reasoning,
-- the anonymous map of where the group differs, and sign-off counts. Never anyone's answers or names
-- other than the owner's.
create function room_report(rid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'room', jsonb_build_object('question', r.question, 'type', r.type, 'type_label', r.type_label, 'language', r.language,
                               'context', r.context, 'options', r.options, 'links', r.links, 'model', r.model, 'rapid', r.rapid,
                               'status', r.status, 'review_date', r.review_date, 'created_at', r.created_at),
    'owner_name', nullif(trim(p.name), ''),
    'members', (select count(*) from memberships m where m.room_id = r.id and m.role <> 'observer'),
    'answered', (select count(*) from inputs i where i.room_id = r.id),
    'analysis', (select jsonb_build_object('frame', a.frame, 'verdict', a.verdict, 'disagreement_map', a.disagreement_map,
                                           'confidence', a.confidence, 'owner_decision', a.owner_decision,
                                           'override_reason', a.override_reason, 'final_option', a.final_option,
                                           'decided_at', a.decided_at, 'created_at', a.created_at)
                 from analyses a where a.room_id = r.id order by a.created_at desc limit 1),
    'signoffs', (select coalesce(jsonb_object_agg(s.stance, s.n), '{}'::jsonb)
                 from (select stance, count(*) n from signoffs where room_id = r.id group by stance) s)
  )
  from rooms r join profiles p on p.id = r.owner_id
  where r.id = rid
$$;
revoke execute on function room_report(uuid) from public, anon, authenticated;

create function report_by_token(share_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select room_report(s.room_id) from report_shares s where s.token = share_token and not s.revoked
$$;
create function report_for_member(rid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select room_report(rid) where room_role(rid) is not null
$$;
revoke execute on function report_by_token(text), report_for_member(uuid) from public, anon;
grant execute on function report_by_token(text) to anon, authenticated;
grant execute on function report_for_member(uuid) to authenticated;
