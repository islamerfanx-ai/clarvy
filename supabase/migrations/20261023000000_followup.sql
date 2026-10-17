-- Follow-up plan, report choice and daily limits for the new AI helpers (decided 2026-10-17).

-- ---------- Daily limits: question check, world brief, the helper ----------
alter table usage_counts drop constraint usage_counts_kind_check;
alter table usage_counts add constraint usage_counts_kind_check
  check (kind in ('triage', 'criteria', 'decide', 'roles', 'question', 'brief', 'helper'));

-- ---------- Which reports the owner gives the team ----------
-- team: one report for everyone; personal: each member sees their own answers next to the call; both.
alter table rooms add column report_mode text not null default 'both' check (report_mode in ('team', 'personal', 'both'));

-- ---------- The follow-up plan ----------
-- Everyone in the room sees the plan. The owner writes it; whoever an item is assigned to can update
-- its status and note.
create table plan_items (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references rooms (id) on delete cascade,
  kind        text not null default 'action' check (kind in ('action', 'check', 'review')),
  title       text not null check (length(trim(title)) between 1 and 200),
  note        text not null default '' check (length(note) <= 500),
  assignee    uuid references profiles (id) on delete set null,
  owner_label text check (owner_label is null or length(owner_label) <= 80),
  due_date    date,
  status      text not null default 'todo' check (status in ('todo', 'doing', 'done', 'blocked')),
  position    integer not null default 0,
  created_by  uuid not null references profiles (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index plan_items_room_idx on plan_items (room_id, due_date);
create index plan_items_assignee_idx on plan_items (assignee);
create index plan_items_created_by_idx on plan_items (created_by);
alter table plan_items enable row level security;

create policy "members see the plan" on plan_items for select using (room_role(room_id) is not null);
create policy "owner adds plan items" on plan_items for insert
  with check (room_role(room_id) = 'owner' and created_by = (select auth.uid())
              and (assignee is null or exists (select 1 from memberships m where m.room_id = plan_items.room_id and m.user_id = plan_items.assignee)));
create policy "owner or assignee updates" on plan_items for update
  using (room_role(room_id) = 'owner' or assignee = (select auth.uid()))
  with check (room_role(room_id) = 'owner' or assignee = (select auth.uid()));
create policy "owner removes plan items" on plan_items for delete using (room_role(room_id) = 'owner');

-- An assignee may move their own item along (status, note), nothing else; the owner may change anything.
create function guard_plan_item() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if auth.uid() is null or room_role(new.room_id) = 'owner' then return new; end if;
  if new.room_id <> old.room_id or new.kind <> old.kind or new.title <> old.title
     or new.assignee is distinct from old.assignee or new.owner_label is distinct from old.owner_label
     or new.due_date is distinct from old.due_date or new.position <> old.position or new.created_by <> old.created_by then
    raise exception 'only_owner_edits_plan' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger plan_items_guard before update on plan_items for each row execute function guard_plan_item();
revoke execute on function guard_plan_item() from public, anon, authenticated;

-- ---------- The report carries the plan ----------
create or replace function room_report(rid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'room', jsonb_build_object('question', r.question, 'type', r.type, 'type_label', r.type_label, 'language', r.language,
                               'context', r.context, 'options', r.options, 'links', r.links, 'model', r.model, 'rapid', r.rapid,
                               'status', r.status, 'review_date', r.review_date, 'created_at', r.created_at,
                               'override_rule', r.override_rule, 'report_mode', r.report_mode,
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
                   where ob.room_id = r.id),
    -- The plan by role or label, never by private detail.
    'plan', (select coalesce(jsonb_agg(jsonb_build_object(
                'kind', pi.kind, 'title', pi.title, 'owner', coalesce(pi.owner_label, mm.role_title, pp.name),
                'due_date', pi.due_date, 'status', pi.status) order by pi.due_date nulls last, pi.position), '[]'::jsonb)
             from plan_items pi
             left join memberships mm on mm.room_id = pi.room_id and mm.user_id = pi.assignee
             left join profiles pp on pp.id = pi.assignee
             where pi.room_id = r.id)
  )
  from rooms r join profiles p on p.id = r.owner_id
  where r.id = rid
$$;
revoke execute on function room_report(uuid) from public, anon, authenticated;
