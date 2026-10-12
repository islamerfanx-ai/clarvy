-- Decision Rooms v1: the simple journey.
-- Members join with just a name (Supabase anonymous sign-in) and can add an email later.
-- Owners must have a real (email) account, because they come back to run and review the room.

alter table inputs add column ratings jsonb;        -- the member's 1-5 answers, so editing shows what they chose
alter table rooms add column decide_error text;     -- set by the server when "Decide now" fails
alter table analyses add column final_option text;  -- the option the group goes with (Clarvy's call, or the owner's override)

create function is_anon() returns boolean language sql stable as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

drop policy "create own workspace" on workspaces;
create policy "create own workspace" on workspaces for insert
  with check (owner_id = auth.uid() and not is_anon());
drop policy "workspace members open rooms" on rooms;
create policy "workspace members open rooms" on rooms for insert
  with check (owner_id = auth.uid() and is_workspace_member(workspace_id) and not is_anon());

-- Sign-off only once the owner has settled the call.
drop policy "sign off" on signoffs;
create policy "sign off" on signoffs for insert
  with check (user_id = auth.uid() and room_role(room_id) in ('owner', 'member')
              and exists (select 1 from rooms r where r.id = room_id and r.status in ('decided', 'reviewed')));

-- Owner accepts Clarvy's call, or overrides it with another option and one line on why.
drop function decide_verdict(uuid, verdict_decision, text);
create function decide_verdict(rid uuid, decision verdict_decision, reason text default null, option_id text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  a analyses;
begin
  if room_role(rid) is distinct from 'owner' then
    raise exception 'only_owner_decides' using errcode = 'insufficient_privilege';
  end if;
  select * into a from analyses where room_id = rid order by created_at desc limit 1;
  if not found then
    raise exception 'no_verdict_yet' using errcode = 'no_data_found';
  end if;
  if decision = 'overridden' and not exists (
       select 1 from rooms r, jsonb_array_elements(r.options) o where r.id = rid and o ->> 'id' = option_id) then
    raise exception 'override_needs_option' using errcode = 'check_violation';
  end if;
  update analyses
     set owner_decision = decision,
         override_reason = nullif(trim(reason), ''),
         final_option = case when decision = 'accepted' then a.verdict ->> 'call' else option_id end,
         decided_at = now()
   where id = a.id;
  update rooms set status = 'decided', decide_error = null where id = rid;
end $$;

-- My rooms: every room you're in, with where it stands. Counts only, never anyone's answers.
create function my_rooms()
returns table (id uuid, type room_type, question text, status room_status, role member_role, language app_language,
               review_date date, created_at timestamptz, quorum smallint, members bigint, submitted bigint,
               i_submitted boolean, has_verdict boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.type, r.question, r.status, m.role, r.language, r.review_date, r.created_at, r.quorum,
         (select count(*) from memberships x where x.room_id = r.id and x.role <> 'observer'),
         (select count(*) from inputs i where i.room_id = r.id),
         exists (select 1 from inputs i where i.room_id = r.id and i.user_id = auth.uid()),
         exists (select 1 from analyses a where a.room_id = r.id)
  from memberships m join rooms r on r.id = m.room_id
  where m.user_id = auth.uid()
  order by r.created_at desc
$$;

revoke execute on function decide_verdict(uuid, verdict_decision, text, text), my_rooms(), is_anon() from public, anon;
grant execute on function decide_verdict(uuid, verdict_decision, text, text), my_rooms(), is_anon() to authenticated;
