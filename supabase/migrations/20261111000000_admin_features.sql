-- Admin page, Features tab (2026-11-02): numbers for everything added since 1.4, as counts only.
-- Research rooms, the phone app and notifications, simulations, and the 1.5 features (notepad, assistants,
-- talk after the call, reopen requests, document library, organisation memory). Never anyone's answers or text.
create function admin_features() returns jsonb
language sql stable security definer set search_path = public as $$
select jsonb_build_object(
  'research', jsonb_build_object(
    'started', (select count(*) from research),
    'started_30d', (select count(*) from research where created_at > now() - interval '30 days'),
    'owners', (select count(distinct owner_id) from research),
    'invited', (select count(*) from research_invites where not revoked),
    'joined', (select count(*) from research_invites where joined_by is not null),
    'submitted', (select count(*) from research_people where role = 'member' and submitted_at is not null),
    'findings', (select count(*) from research_findings),
    'sourced', (select count(*) from research_findings where source_url is not null or source_label is not null),
    'pooled', (select count(*) from research where status in ('pooled', 'done')),
    'briefs', (select count(*) from research where status = 'done'),
    'to_room', (select count(*) from research where to_room_at is not null),
    'next_rounds', (select count(*) from research where parent_id is not null),
    'hidden', (select count(*) from research where visibility = 'hidden'),
    'cost_30d', (select coalesce(sum(cost), 0) from ai_usage where kind = 'research' and created_at > now() - interval '30 days')),
  'app', jsonb_build_object(
    'devices', (select count(*) from push_subscriptions),
    'people', (select count(distinct user_id) from push_subscriptions),
    'by_device', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc), '[]') from (
        select case when ua ~* 'iphone|ipad' then 'iphone' when ua ~* 'android' then 'android' else 'computer' end k, count(*) n
        from push_subscriptions group by 1) x),
    'used_7d', (select count(*) from push_subscriptions where last_used_at > now() - interval '7 days'),
    'sent_7d', (select count(*) from push_outbox where sent_at > now() - interval '7 days'),
    'sent_30d', (select count(*) from push_outbox where sent_at > now() - interval '30 days'),
    'waiting', (select count(*) from push_outbox where sent_at is null and created_at > now() - interval '1 day'),
    'by_event', (select coalesce(jsonb_agg(jsonb_build_object('k', event, 'n', n) order by n desc), '[]') from (
        select event, count(*) n from push_outbox where created_at > now() - interval '30 days' group by event) x),
    'kinds_off', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n) order by n desc), '[]') from (
        select unnest(off) k, count(*) n from push_prefs group by 1) x)),
  'simulations', jsonb_build_object(
    'drafted', (select count(*) from simulations),
    'run', (select count(*) from simulations where status = 'done'),
    'failed', (select count(*) from simulations where status = 'failed'),
    'added', (select count(*) from simulations where added_at is not null),
    'rooms', (select count(distinct room_id) from simulations),
    'seconds', (select round((percentile_cont(0.5) within group (order by extract(epoch from finished_at - started_at)))::numeric)
                from simulations where status = 'done' and started_at is not null and finished_at is not null),
    'cost_30d', (select coalesce(sum(cost), 0) from ai_usage where kind = 'simulate' and created_at > now() - interval '30 days')),
  'features', jsonb_build_object(
    'notes', (select count(*) from notes),
    'note_authors', (select count(distinct user_id) from notes),
    'notes_cost_30d', (select coalesce(sum(cost), 0) from ai_usage where kind = 'notes' and created_at > now() - interval '30 days'),
    'assistants', (select count(*) from assistants where expires_at is null or expires_at > now()),
    'assistant_actions_30d', (select count(*) from assistant_log where at > now() - interval '30 days'),
    'messages_30d', (select count(*) from room_messages where created_at > now() - interval '30 days'),
    'talk_rooms_30d', (select count(distinct room_id) from room_messages where created_at > now() - interval '30 days'),
    'reopen_open', (select count(*) from reopen_requests where status = 'open'),
    'reopened', (select count(*) from reopen_requests where status = 'reopened'),
    'reopen_declined', (select count(*) from reopen_requests where status = 'declined'),
    'documents', (select count(*) from org_documents),
    'document_orgs', (select count(distinct workspace_id) from org_documents),
    'calls_with_docs', (select count(*) from analyses where verdict ? 'docs_used' and jsonb_typeof(verdict->'docs_used') = 'array'),
    'memory_orgs', (select count(*) from workspaces where kind = 'organisation' and memory_on),
    'calls_with_memory', (select count(*) from analyses where jsonb_typeof(verdict->'memory_used') = 'object'))
)
$$;
revoke execute on function admin_features() from public, anon, authenticated;
grant execute on function admin_features() to service_role;

-- The owner marks a brief turned into a decision room (counted above). Only that field, only the owner.
create function research_to_room(rid uuid) returns void
language sql security definer set search_path = public as $$
  update research set to_room_at = coalesce(to_room_at, now()) where id = rid and owner_id = auth.uid()
$$;
revoke execute on function research_to_room(uuid) from public, anon;
