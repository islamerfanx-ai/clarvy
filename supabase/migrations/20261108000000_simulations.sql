-- Simulation Room, quick version (decided 2026-10-27; grounded personas follow in version 2.0). Before a room
-- decides, its owner (or their assistant) can test the options on simulated people: stages, audiences with weights,
-- questions, a run, then findings. Personas are drawn in code from each audience's recipe; the AI answers in
-- character; code works out the numbers and ranges. Findings are marked simulated and, when the owner adds them,
-- go into what everyone should know and the analysis.

create table simulations (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references rooms (id) on delete cascade,
  created_by  uuid not null default auth.uid() references profiles (id) on delete set null,
  status      text not null default 'draft' check (status in ('draft', 'queued', 'running', 'done', 'failed')),
  stages      jsonb not null default '[]' check (jsonb_typeof(stages) = 'array' and jsonb_array_length(stages) <= 6),
  audiences   jsonb not null default '[]' check (jsonb_typeof(audiences) = 'array' and jsonb_array_length(audiences) <= 7),
  questions   jsonb not null default '[]' check (jsonb_typeof(questions) = 'array' and jsonb_array_length(questions) <= 16),
  size        int not null default 10 check (size between 1 and 300),
  results     jsonb,
  findings    jsonb,
  confidence  text check (confidence in ('low', 'medium', 'high')),
  error       text check (length(error) <= 200),
  progress    int not null default 0 check (progress between 0 and 100),
  added_at    timestamptz,
  requested_at timestamptz,
  started_at  timestamptz,
  finished_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index simulations_room_idx on simulations (room_id, created_at desc);
alter table simulations enable row level security;

-- The room sees its simulations; the owner (or an assistant who organises) edits a draft. Results, findings,
-- status and size are written by the server only.
create policy "the room sees its simulations" on simulations for select using (room_role(room_id) is not null or assists(room_id, 'view'));
create policy "owner edits a draft" on simulations for update
  using ((room_role(room_id) = 'owner' or assists(room_id, 'organise')) and status = 'draft')
  with check ((room_role(room_id) = 'owner' or assists(room_id, 'organise')) and status = 'draft');

create function guard_simulation() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if auth.uid() is null then return new; end if;
  if new.status is distinct from old.status or new.results is distinct from old.results or new.findings is distinct from old.findings
     or new.size is distinct from old.size or new.confidence is distinct from old.confidence or new.error is distinct from old.error
     or new.progress is distinct from old.progress or new.room_id is distinct from old.room_id or new.created_by is distinct from old.created_by
     or new.started_at is distinct from old.started_at or new.finished_at is distinct from old.finished_at
     or new.requested_at is distinct from old.requested_at or new.added_at is distinct from old.added_at then
    raise exception 'simulation_is_managed' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger simulations_guard before update on simulations for each row execute function guard_simulation();
revoke execute on function guard_simulation() from public, anon, authenticated;

-- The server's worker takes the next queued run (one at a time per run; a run cut off by a restart is picked up again).
create function claim_simulation(stale_after interval default '15 minutes') returns setof simulations
language plpgsql security definer set search_path = public as $$
declare s simulations;
begin
  update simulations set status = 'failed', error = 'timeout'
  where status = 'running' and started_at < now() - stale_after * 2;
  select * into s from simulations
  where status = 'queued' or (status = 'running' and started_at < now() - stale_after)
  order by requested_at nulls first limit 1 for update skip locked;
  if not found then return; end if;
  update simulations set status = 'running', started_at = now(), progress = 0 where id = s.id returning * into s;
  return next s;
end $$;
revoke execute on function claim_simulation(interval) from public, anon, authenticated;
grant execute on function claim_simulation(interval) to service_role;

-- Daily limit for simulation runs.
alter table usage_counts drop constraint usage_counts_kind_check;
alter table usage_counts add constraint usage_counts_kind_check
  check (kind in ('triage', 'criteria', 'decide', 'roles', 'question', 'brief', 'helper', 'notes', 'simulate'));
