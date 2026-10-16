-- "Decide now" as a job that survives a restart (decided 2026-10-16, product-foundation section 0).
-- A room in status 'deciding' with no analysis since it was asked for is a job. The server claims
-- one at a time (at most a few at once), and a claim that goes quiet (the server restarted mid-run)
-- is picked up again. After too many failed tries the room reopens with decide_error set.

alter table rooms add column decide_requested_at timestamptz;
alter table rooms add column decide_started_at timestamptz;
alter table rooms add column decide_attempts integer not null default 0;

create index rooms_deciding_idx on rooms (decide_requested_at) where status = 'deciding';

-- Server only. Returns the next room to analyse (or nothing), marking it started.
create function claim_decide_job(stale_after interval default '8 minutes', max_attempts integer default 2)
returns setof rooms language plpgsql security definer set search_path = public as $$
declare r rooms;
begin
  -- Rooms that failed too often go back to open, so the owner can try again.
  update rooms set status = 'open', decide_error = coalesce(decide_error, 'upstream'), decide_started_at = null
  where status = 'deciding' and decide_attempts >= max_attempts
    and (decide_started_at is null or decide_started_at < now() - stale_after)
    and not exists (select 1 from analyses a where a.room_id = rooms.id
                    and a.created_at >= coalesce(rooms.decide_requested_at, '-infinity'));
  select * into r from rooms
  where status = 'deciding'
    and (decide_started_at is null or decide_started_at < now() - stale_after)
    and not exists (select 1 from analyses a where a.room_id = rooms.id
                    and a.created_at >= coalesce(rooms.decide_requested_at, '-infinity'))
  order by decide_requested_at nulls first
  limit 1
  for update skip locked;
  if not found then return; end if;
  update rooms set decide_started_at = now(), decide_attempts = decide_attempts + 1 where id = r.id returning * into r;
  return next r;
end $$;
revoke execute on function claim_decide_job(interval, integer) from public, anon, authenticated;
grant execute on function claim_decide_job(interval, integer) to service_role;
