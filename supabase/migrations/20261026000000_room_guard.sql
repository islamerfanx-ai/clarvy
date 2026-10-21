-- Room status and the decide-job columns are managed by the server and the database's own functions
-- (found 2026-10-21). Before this, the owner's "edit room" permission let a signed-in person create a
-- room already in 'deciding', or flip one to it, and the worker would run a full analysis with no quorum
-- and no daily limit; an owner could also reopen a decided room or mark any room reviewed.
-- The server uses the service role (no auth.uid()); functions that may change status set
-- app.room_trusted for the one statement that needs it.

create function guard_room_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or current_setting('app.room_trusted', true) = 'on' then return new; end if;
  if tg_op = 'INSERT' then
    if new.status <> 'open' or new.decide_requested_at is not null or new.decide_started_at is not null
       or new.decide_attempts <> 0 or new.decide_error is not null or new.decide_stage is not null then
      raise exception 'room_status_is_managed' using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;
  if new.status is distinct from old.status
     or new.decide_requested_at is distinct from old.decide_requested_at
     or new.decide_started_at is distinct from old.decide_started_at
     or new.decide_attempts is distinct from old.decide_attempts
     or new.decide_error is distinct from old.decide_error
     or new.decide_stage is distinct from old.decide_stage
     or new.workspace_id is distinct from old.workspace_id then
    raise exception 'room_status_is_managed' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger rooms_guard_write before insert or update on rooms for each row execute function guard_room_write();
revoke execute on function guard_room_write() from public, anon, authenticated;

-- Settling the call is the one place an owner moves a room to 'decided'.
create or replace function decide_verdict(rid uuid, decision verdict_decision, reason text default null, option_id text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  a analyses;
  final_opt text;
begin
  if room_role(rid) is distinct from 'owner' then
    raise exception 'only_owner_decides' using errcode = 'insufficient_privilege';
  end if;
  select * into a from analyses where room_id = rid order by created_at desc limit 1;
  if not found then
    raise exception 'no_verdict_yet' using errcode = 'no_data_found';
  end if;
  if decision = 'overridden' and not exists (
       select 1 from rooms r, jsonb_array_elements(r.options) o where r.id = rid and o ->> 'id' = decide_verdict.option_id) then
    raise exception 'override_needs_option' using errcode = 'check_violation';
  end if;
  final_opt := case when decision = 'accepted' then a.verdict ->> 'call' else decide_verdict.option_id end;
  if exists (select 1 from objections ob where ob.room_id = rid and ob.status = 'open'
             and (ob.option_id is null or ob.option_id = final_opt)) then
    raise exception 'objection_open' using errcode = 'check_violation';
  end if;
  update analyses
     set owner_decision = decision,
         override_reason = nullif(trim(reason), ''),
         final_option = final_opt,
         decided_at = now()
   where id = a.id;
  perform set_config('app.room_trusted', 'on', true);
  update rooms set status = 'decided', decide_error = null where id = rid;
  perform set_config('app.room_trusted', 'off', true);
end $$;
