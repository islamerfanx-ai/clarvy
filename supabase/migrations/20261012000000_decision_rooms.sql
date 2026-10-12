-- Clarvy Decision Rooms v1: data model (docs/decision-rooms-spec.md, "Data model and tech").
--
-- Privacy is the product, so it is enforced here with row-level security, not in the app:
--   * A member's raw input (weights, risk, gut pick, concern) is readable by that member only.
--     Not the owner, not other members. The server reads inputs with the service role to run
--     the combined analysis, and only aggregated results land in `analyses`.
--   * Sign-offs, trip briefs and trip votes are private the same way; groups see counts via
--     security-definer functions.
--   * Calendar tokens are never readable from the client.

-- ---------- Types ----------
create type app_language    as enum ('en', 'ar');
create type workspace_plan  as enum ('free', 'team', 'organisation');
create type workspace_role  as enum ('owner', 'admin', 'member');
create type room_type       as enum ('business', 'finance', 'politics', 'trip');
create type room_status     as enum ('open', 'deciding', 'decided', 'reviewed');
create type member_role     as enum ('owner', 'member', 'observer');
create type risk_appetite   as enum ('safe', 'balanced', 'bold');   -- Play it safe, Balanced, Go big
create type signoff_stance  as enum ('agree', 'disagree_commit', 'object');
create type verdict_decision as enum ('accepted', 'overridden');
create type calendar_provider as enum ('google', 'outlook', 'apple');

-- ---------- People ----------
create table profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text not null default '',
  email       text,
  phone       text,                       -- WhatsApp number, E.164
  language    app_language not null default 'en',
  home_city   text,
  time_zone   text,                       -- IANA name, e.g. Asia/Riyadh
  created_at  timestamptz not null default now()
);

create table workspaces (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  plan        workspace_plan not null default 'free',
  owner_id    uuid not null references profiles (id),
  created_at  timestamptz not null default now()
);

create table workspace_members (
  workspace_id uuid not null references workspaces (id) on delete cascade,
  user_id      uuid not null references profiles (id) on delete cascade,
  role         workspace_role not null default 'member',
  joined_at    timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

-- ---------- Rooms ----------
-- options:  [{"id": "a", "label": "Open in Jeddah this year"}, ...]
-- criteria: [{"id": "cash", "label": "Cash risk", "weight": 30}, ...]  weight = Clarvy's suggestion, sums to 100
create table rooms (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces (id) on delete cascade,
  type         room_type not null,
  question     text not null check (length(trim(question)) > 0),
  context      text not null default '',
  options      jsonb not null default '[]' check (jsonb_typeof(options) = 'array'),
  criteria     jsonb not null default '[]' check (jsonb_typeof(criteria) = 'array'),
  language     app_language not null default 'en',
  status       room_status not null default 'open',
  owner_id     uuid not null references profiles (id),
  review_date  date,
  quorum       smallint not null default 2 check (quorum >= 1),  -- inputs needed before "decide now"
  named_views  boolean not null default false,  -- only honoured if every member consented on joining
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table memberships (
  room_id            uuid not null references rooms (id) on delete cascade,
  user_id            uuid not null references profiles (id) on delete cascade,
  role               member_role not null default 'member',
  named_view_consent boolean not null default false,
  joined_at          timestamptz not null default now(),
  primary key (room_id, user_id)
);

-- Private member input. weights: {"cash": 40, "upside": 25, ...}, whole numbers summing to 100,
-- one key per room criterion (checked by trigger below).
create table inputs (
  room_id       uuid not null,
  user_id       uuid not null,
  weights       jsonb not null,
  risk_appetite risk_appetite not null,
  gut_pick      text,                      -- an option id
  concern       text not null default '' check (length(concern) <= 280),
  submitted_at  timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  primary key (room_id, user_id),
  foreign key (room_id, user_id) references memberships (room_id, user_id) on delete cascade
);

create table attachments (
  id             uuid primary key default gen_random_uuid(),
  room_id        uuid not null references rooms (id) on delete cascade,
  file_name      text not null,
  storage_path   text,                     -- object in the private room-files bucket
  extracted_text text not null default '',
  uploaded_by    uuid not null references profiles (id),
  created_at     timestamptz not null default now()
);

-- One analysis per room run. Written by the server (service role) only.
-- member_scores is keyed by an anonymous label ("Member 1"), never by user id, unless named views are on.
create table analyses (
  id               uuid primary key default gen_random_uuid(),
  room_id          uuid not null references rooms (id) on delete cascade,
  frame            jsonb not null default '{}',   -- shared facts, options, criteria, unknowns
  outcomes         jsonb not null default '{}',   -- Analyst scores and best/likely/worst with odds
  member_scores    jsonb not null default '[]',
  disagreement_map jsonb not null default '{}',
  verdict          jsonb not null default '{}',
  confidence       text,
  owner_decision   verdict_decision,
  override_reason  text,
  decided_at       timestamptz,
  created_at       timestamptz not null default now(),
  check (owner_decision is distinct from 'overridden' or length(trim(coalesce(override_reason, ''))) > 0)
);

create table signoffs (
  room_id    uuid not null,
  user_id    uuid not null,
  stance     signoff_stance not null,
  note       text not null default '' check (length(note) <= 500),
  created_at timestamptz not null default now(),
  primary key (room_id, user_id),
  foreign key (room_id, user_id) references memberships (room_id, user_id) on delete cascade
);

create table outcomes (
  room_id       uuid primary key references rooms (id) on delete cascade,
  what_happened text not null,
  rating        smallint not null check (rating between 1 and 5),  -- 1 the call was wrong ... 5 the call was right
  lessons       text not null default '',
  logged_by     uuid not null references profiles (id),
  logged_at     timestamptz not null default now()
);

create table outcome_comments (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references outcomes (room_id) on delete cascade,
  user_id    uuid not null references profiles (id) on delete cascade,
  body       text not null check (length(trim(body)) > 0 and length(body) <= 1000),
  created_at timestamptz not null default now()
);

-- ---------- Trip rooms ----------
create table calendar_links (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references profiles (id) on delete cascade,
  provider         calendar_provider not null,
  token_ciphertext text not null,          -- encrypted by the server; never sent to the client
  scope            text not null default 'freebusy' check (scope = 'freebusy'),
  created_at       timestamptz not null default now(),
  unique (user_id, provider)
);

create table trip_briefs (
  room_id     uuid primary key references rooms (id) on delete cascade,
  date_from   date not null,
  date_to     date not null,
  length_days smallint not null check (length_days between 1 and 60),
  must_haves  text not null default '',
  check (date_to >= date_from)
);

create table trip_member_briefs (
  room_id         uuid not null,
  user_id         uuid not null,
  budget          numeric(12, 2) check (budget >= 0),
  budget_currency char(3),
  vibes           text[] not null default '{}'
                  check (vibes <@ array['beach', 'city', 'nature', 'food', 'adventure']),
  no_gos          text not null default '',
  updated_at      timestamptz not null default now(),
  primary key (room_id, user_id),
  foreign key (room_id, user_id) references memberships (room_id, user_id) on delete cascade
);

-- per_member: [{"member": "Member 1", "travel_minutes": 320, "fare": 410, "currency": "USD"}, ...]
create table trip_options (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references rooms (id) on delete cascade,
  rank        smallint not null,
  date_from   date not null,
  date_to     date not null,
  destination text not null,
  per_member  jsonb not null default '[]',
  weather     jsonb not null default '{}',
  events      jsonb not null default '[]',
  created_at  timestamptz not null default now()
);

create table trip_votes (
  room_id   uuid not null,
  user_id   uuid not null,
  option_id uuid not null references trip_options (id) on delete cascade,
  voted_at  timestamptz not null default now(),
  primary key (room_id, user_id),
  foreign key (room_id, user_id) references memberships (room_id, user_id) on delete cascade
);

-- ---------- Indexes ----------
create index on workspace_members (user_id);
create index on rooms (workspace_id);
create index on rooms (owner_id);
create index on memberships (user_id);
create index on attachments (room_id);
create index on analyses (room_id, created_at desc);
create index on outcome_comments (room_id);
create index on trip_options (room_id, rank);

-- ---------- Helpers (security definer so policies don't recurse through RLS) ----------
create function room_role(rid uuid) returns member_role
language sql stable security definer set search_path = public as $$
  select role from memberships where room_id = rid and user_id = auth.uid()
$$;

create function is_workspace_member(wid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from workspace_members where workspace_id = wid and user_id = auth.uid())
$$;

create function shares_room_with(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from memberships a join memberships b on a.room_id = b.room_id
    where a.user_id = auth.uid() and b.user_id = other)
$$;

-- ---------- Triggers ----------
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name, email, phone, language)
  values (new.id,
          coalesce(new.raw_user_meta_data ->> 'name', ''),
          new.email,
          new.phone,
          case when new.raw_user_meta_data ->> 'language' = 'ar' then 'ar'::app_language else 'en' end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

create function add_workspace_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into workspace_members (workspace_id, user_id, role) values (new.id, new.owner_id, 'owner');
  return new;
end $$;
create trigger on_workspace_created after insert on workspaces
  for each row execute function add_workspace_owner();

create function add_room_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into memberships (room_id, user_id, role, named_view_consent) values (new.id, new.owner_id, 'owner', true);
  return new;
end $$;
create trigger on_room_created after insert on rooms
  for each row execute function add_room_owner();

create function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger rooms_touch before update on rooms for each row execute function touch_updated_at();
create trigger trip_member_briefs_touch before update on trip_member_briefs for each row execute function touch_updated_at();

-- Memberships: only the owner changes roles (never to or from owner), and only you give your consent.
-- auth.uid() is null for the service role and SQL editor, which may change anything.
create function guard_membership_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if new.room_id <> old.room_id or new.user_id <> old.user_id then
    raise exception 'membership_identity_fixed' using errcode = 'check_violation';
  end if;
  if new.role <> old.role and (room_role(new.room_id) is distinct from 'owner' or 'owner' in (new.role, old.role)) then
    raise exception 'only_owner_changes_roles' using errcode = 'insufficient_privilege';
  end if;
  if new.named_view_consent <> old.named_view_consent and new.user_id <> auth.uid() then
    raise exception 'consent_is_personal' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger memberships_guard before update on memberships
  for each row execute function guard_membership_update();

-- Inputs: only while the room is open, only owners and members, weights must cover exactly the
-- room's criteria with whole numbers 0-100 summing to 100, and the gut pick must be a real option.
create function validate_input() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r rooms;
  want text[];
  got text[];
begin
  select * into r from rooms where id = new.room_id;
  if r.status <> 'open' then
    raise exception 'room_not_open' using errcode = 'check_violation';
  end if;
  if (select role from memberships where room_id = new.room_id and user_id = new.user_id) = 'observer' then
    raise exception 'observers_do_not_give_input' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(new.weights) <> 'object' then
    raise exception 'weights_must_be_object' using errcode = 'check_violation';
  end if;
  select coalesce(array_agg(c ->> 'id' order by c ->> 'id'), '{}') into want from jsonb_array_elements(r.criteria) c;
  select coalesce(array_agg(k order by k), '{}') into got from jsonb_object_keys(new.weights) k;
  if want <> got then
    raise exception 'weights_must_cover_criteria' using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_each(new.weights) e
             where jsonb_typeof(e.value) <> 'number'
                or (e.value)::numeric <> trunc((e.value)::numeric)
                or (e.value)::numeric not between 0 and 100) then
    raise exception 'weights_must_be_whole_0_100' using errcode = 'check_violation';
  end if;
  if (select sum((e.value)::numeric) from jsonb_each(new.weights) e) <> 100 then
    raise exception 'weights_must_sum_100' using errcode = 'check_violation';
  end if;
  if new.gut_pick is not null
     and not exists (select 1 from jsonb_array_elements(r.options) o where o ->> 'id' = new.gut_pick) then
    raise exception 'gut_pick_not_an_option' using errcode = 'check_violation';
  end if;
  new.updated_at = now();
  if tg_op = 'UPDATE' then new.submitted_at = old.submitted_at; end if;
  return new;
end $$;
create trigger inputs_validate before insert or update on inputs
  for each row execute function validate_input();

-- ---------- Row-level security ----------
alter table profiles           enable row level security;
alter table workspaces         enable row level security;
alter table workspace_members  enable row level security;
alter table rooms              enable row level security;
alter table memberships        enable row level security;
alter table inputs             enable row level security;
alter table attachments        enable row level security;
alter table analyses           enable row level security;
alter table signoffs           enable row level security;
alter table outcomes           enable row level security;
alter table outcome_comments   enable row level security;
alter table calendar_links     enable row level security;
alter table trip_briefs        enable row level security;
alter table trip_member_briefs enable row level security;
alter table trip_options       enable row level security;
alter table trip_votes         enable row level security;

-- Profiles: your own in full. Co-members see names only, through room_roster() below.
create policy "own profile" on profiles for select using (id = auth.uid());
create policy "edit own profile" on profiles for update using (id = auth.uid()) with check (id = auth.uid());

create policy "workspace members read" on workspaces for select using (is_workspace_member(id));
create policy "create own workspace" on workspaces for insert with check (owner_id = auth.uid());
create policy "owner edits workspace" on workspaces for update using (owner_id = auth.uid());

create policy "see co-members" on workspace_members for select using (is_workspace_member(workspace_id));
create policy "owner adds members" on workspace_members for insert
  with check (exists (select 1 from workspaces w where w.id = workspace_id and w.owner_id = auth.uid()));

create policy "members read room" on rooms for select using (room_role(id) is not null);
create policy "workspace members open rooms" on rooms for insert
  with check (owner_id = auth.uid() and is_workspace_member(workspace_id));
create policy "owner edits room" on rooms for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "owner deletes room" on rooms for delete using (owner_id = auth.uid());

create policy "members see memberships" on memberships for select using (room_role(room_id) is not null);
create policy "owner adds people" on memberships for insert
  with check (room_role(room_id) = 'owner' and role <> 'owner');
create policy "owner changes roles" on memberships for update
  using (room_role(room_id) = 'owner' and user_id <> auth.uid());
create policy "own consent" on memberships for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "owner removes, members leave" on memberships for delete
  using ((room_role(room_id) = 'owner' and user_id <> auth.uid()) or (user_id = auth.uid() and role <> 'owner'));

-- Inputs: yours and nobody else's.
create policy "own input" on inputs for select using (user_id = auth.uid());
create policy "give input" on inputs for insert with check (user_id = auth.uid());
create policy "change input" on inputs for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "members read files" on attachments for select using (room_role(room_id) is not null);
create policy "owner adds files" on attachments for insert
  with check (room_role(room_id) = 'owner' and uploaded_by = auth.uid());
create policy "owner deletes files" on attachments for delete using (room_role(room_id) = 'owner');

create policy "members read analysis" on analyses for select using (room_role(room_id) is not null);

create policy "own signoff" on signoffs for select using (user_id = auth.uid());
create policy "sign off" on signoffs for insert
  with check (user_id = auth.uid() and room_role(room_id) in ('owner', 'member'));
create policy "change signoff" on signoffs for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "members read outcome" on outcomes for select using (room_role(room_id) is not null);
create policy "owner logs outcome" on outcomes for insert
  with check (room_role(room_id) = 'owner' and logged_by = auth.uid());
create policy "owner edits outcome" on outcomes for update using (room_role(room_id) = 'owner');

create policy "members read comments" on outcome_comments for select using (room_role(room_id) is not null);
create policy "members comment" on outcome_comments for insert
  with check (user_id = auth.uid() and room_role(room_id) in ('owner', 'member'));

-- Calendar links: you can list and disconnect yours; the token column is never granted.
create policy "own calendar links" on calendar_links for select using (user_id = auth.uid());
create policy "disconnect calendar" on calendar_links for delete using (user_id = auth.uid());
revoke all on calendar_links from anon, authenticated;
grant select (id, user_id, provider, scope, created_at), delete on calendar_links to authenticated;

create policy "members read trip brief" on trip_briefs for select using (room_role(room_id) is not null);
create policy "owner sets trip brief" on trip_briefs for all
  using (room_role(room_id) = 'owner') with check (room_role(room_id) = 'owner');

create policy "own trip brief" on trip_member_briefs for select using (user_id = auth.uid());
create policy "add trip brief" on trip_member_briefs for insert
  with check (user_id = auth.uid() and room_role(room_id) in ('owner', 'member'));
create policy "change trip brief" on trip_member_briefs for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "members read trip options" on trip_options for select using (room_role(room_id) is not null);

create policy "own vote" on trip_votes for select using (user_id = auth.uid());
create policy "vote" on trip_votes for insert
  with check (user_id = auth.uid() and room_role(room_id) in ('owner', 'member')
              and exists (select 1 from trip_options o where o.id = option_id and o.room_id = trip_votes.room_id));
create policy "change vote" on trip_votes for update using (user_id = auth.uid())
  with check (user_id = auth.uid()
              and exists (select 1 from trip_options o where o.id = option_id and o.room_id = trip_votes.room_id));

-- ---------- Group views (counts and ticks, never content) ----------
-- Waiting screen: who is in the room and who has submitted.
create function room_roster(rid uuid)
returns table (user_id uuid, name text, role member_role, submitted boolean)
language sql stable security definer set search_path = public as $$
  select m.user_id, p.name, m.role, exists (select 1 from inputs i where i.room_id = m.room_id and i.user_id = m.user_id)
  from memberships m join profiles p on p.id = m.user_id
  where m.room_id = rid and room_role(rid) is not null
  order by m.joined_at
$$;

create function signoff_counts(rid uuid)
returns table (stance signoff_stance, n bigint)
language sql stable security definer set search_path = public as $$
  select s.stance, count(*) from signoffs s where s.room_id = rid and room_role(rid) is not null group by s.stance
$$;

create function trip_vote_counts(rid uuid)
returns table (option_id uuid, n bigint)
language sql stable security definer set search_path = public as $$
  select v.option_id, count(*) from trip_votes v where v.room_id = rid and room_role(rid) is not null group by v.option_id
$$;

-- Owner accepts or overrides the latest verdict; an override needs one line on why.
create function decide_verdict(rid uuid, decision verdict_decision, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if room_role(rid) is distinct from 'owner' then
    raise exception 'only_owner_decides' using errcode = 'insufficient_privilege';
  end if;
  update analyses set owner_decision = decision, override_reason = nullif(trim(reason), ''), decided_at = now()
  where id = (select id from analyses where room_id = rid order by created_at desc limit 1);
  update rooms set status = 'decided' where id = rid;
end $$;

revoke execute on function room_roster(uuid), signoff_counts(uuid), trip_vote_counts(uuid),
  decide_verdict(uuid, verdict_decision, text) from public, anon;
grant execute on function room_roster(uuid), signoff_counts(uuid), trip_vote_counts(uuid),
  decide_verdict(uuid, verdict_decision, text) to authenticated;

-- ---------- File storage ----------
-- Files live at room-files/<room id>/<file name>. Members read; the owner uploads and deletes.
insert into storage.buckets (id, name, public) values ('room-files', 'room-files', false)
on conflict (id) do nothing;

create function room_id_from_path(path text) returns uuid
language plpgsql immutable as $$
begin
  return split_part(path, '/', 1)::uuid;
exception when invalid_text_representation then
  return null;
end $$;

create policy "members read room files" on storage.objects for select
  using (bucket_id = 'room-files' and room_role(room_id_from_path(name)) is not null);
create policy "owner uploads room files" on storage.objects for insert
  with check (bucket_id = 'room-files' and room_role(room_id_from_path(name)) = 'owner');
create policy "owner deletes room files" on storage.objects for delete
  using (bucket_id = 'room-files' and room_role(room_id_from_path(name)) = 'owner');
