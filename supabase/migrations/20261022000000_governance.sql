-- RAPID governance and the decision record (persona drill fixes, 2026-10-17).
-- - Each room says who may override an approver's objection: the owner, only the approver (by
--   withdrawing), or a named higher-authority role.
-- - An objection can be to the whole decision or to one option.
-- - Objections no longer block the analysis; they block settling the call, so the recommended call
--   can say whether it meets each objection first.
-- - The report carries the decision record: the override rule and every objection with its outcome.
-- - A strict confidentiality setting: the analysis summarises role answers instead of quoting figures.

alter table rooms add column override_rule text not null default 'owner' check (override_rule in ('owner', 'approver', 'authority'));
alter table rooms add column override_role_id text check (override_role_id is null or length(override_role_id) <= 10);
alter table rooms add column strict_confidential boolean not null default false;
alter table rooms add constraint rooms_authority_needs_role check (override_rule <> 'authority' or override_role_id is not null);

alter table objections add column option_id text check (option_id is null or length(option_id) <= 10);

-- Approvers can object while answers come in and after the recommended call is drafted.
drop policy "approvers object" on objections;
create policy "approvers object" on objections for insert
  with check (user_id = (select auth.uid())
              and exists (select 1 from memberships m where m.room_id = objections.room_id and m.user_id = (select auth.uid()) and m.rapid_role = 'approver')
              and exists (select 1 from rooms r where r.id = objections.room_id and r.status in ('open', 'deciding') and r.rapid));

-- Who may override follows the room's rule; the reason is always on the record.
create or replace function override_objection(oid uuid, why text) returns void
language plpgsql security definer set search_path = public as $$
declare
  o objections;
  rm rooms;
  me memberships;
begin
  select * into o from objections where id = oid;
  if not found then raise exception 'objection_not_found' using errcode = 'no_data_found'; end if;
  select * into rm from rooms where id = o.room_id;
  select * into me from memberships where room_id = o.room_id and user_id = auth.uid();
  if me.user_id is null then raise exception 'only_owner_decides' using errcode = 'insufficient_privilege'; end if;
  if rm.override_rule = 'approver' then
    raise exception 'only_approver_withdraws' using errcode = 'insufficient_privilege';
  elsif rm.override_rule = 'authority' then
    if me.role_id is distinct from rm.override_role_id then
      raise exception 'only_authority_overrides' using errcode = 'insufficient_privilege';
    end if;
  elsif me.role <> 'owner' then
    raise exception 'only_owner_decides' using errcode = 'insufficient_privilege';
  end if;
  if o.status <> 'open' then raise exception 'objection_not_open' using errcode = 'check_violation'; end if;
  if length(trim(coalesce(why, ''))) = 0 then raise exception 'need_reason' using errcode = 'check_violation'; end if;
  update objections set status = 'overridden', override_reason = trim(why), resolved_at = now() where id = oid;
end $$;

-- Settling the call waits for any open objection that applies to the final option.
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
  update rooms set status = 'decided', decide_error = null where id = rid;
end $$;

-- The report, now with the decision record (who objected is shown by role, not by name).
create or replace function room_report(rid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'room', jsonb_build_object('question', r.question, 'type', r.type, 'type_label', r.type_label, 'language', r.language,
                               'context', r.context, 'options', r.options, 'links', r.links, 'model', r.model, 'rapid', r.rapid,
                               'status', r.status, 'review_date', r.review_date, 'created_at', r.created_at,
                               'override_rule', r.override_rule,
                               'override_role', (select x->>'title' from jsonb_array_elements(r.roles) x where x->>'id' = r.override_role_id)),
    'owner_name', nullif(trim(p.name), ''),
    'members', (select count(*) from memberships m where m.room_id = r.id and m.role <> 'observer'),
    'answered', (select count(*) from inputs i where i.room_id = r.id),
    'analysis', (select jsonb_build_object('frame', a.frame, 'verdict', a.verdict, 'disagreement_map', a.disagreement_map,
                                           'confidence', a.confidence, 'owner_decision', a.owner_decision,
                                           'override_reason', a.override_reason, 'final_option', a.final_option,
                                           'decided_at', a.decided_at, 'created_at', a.created_at)
                 from analyses a where a.room_id = r.id order by a.created_at desc limit 1),
    'signoffs', (select coalesce(jsonb_object_agg(s.stance, s.n), '{}'::jsonb)
                 from (select stance, count(*) n from signoffs where room_id = r.id group by stance) s),
    'objections', (select coalesce(jsonb_agg(jsonb_build_object(
                      'by_role', coalesce(m.role_title, 'Approver'), 'reason', ob.reason, 'option_id', ob.option_id,
                      'status', ob.status, 'override_reason', ob.override_reason,
                      'created_at', ob.created_at, 'resolved_at', ob.resolved_at) order by ob.created_at), '[]'::jsonb)
                   from objections ob left join memberships m on m.room_id = ob.room_id and m.user_id = ob.user_id
                   where ob.room_id = r.id)
  )
  from rooms r join profiles p on p.id = r.owner_id
  where r.id = rid
$$;
revoke execute on function room_report(uuid) from public, anon, authenticated;
