-- Hardening before growth (decided 2026-10-16, product-foundation section 0).
-- 1. Daily usage counts for the AI routes, written only by the server.
-- 2. Internal functions locked to internal use.
-- 3. Fixed search_path on the remaining functions.
-- 4. Policies read auth.uid() once per query instead of once per row.
-- 5. Indexes for foreign keys that had none.
-- 6. Trip tables (moved to the future consumer product) closed to the API.

-- ---------- 1. Usage counts ----------
create table if not exists public.usage_counts (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null default current_date,
  kind text not null check (kind in ('triage','criteria','decide')),
  n int not null default 0,
  primary key (user_id, day, kind)
);
alter table public.usage_counts enable row level security;   -- no policies: only the service role touches it
revoke all on public.usage_counts from anon, authenticated;

-- Counts one use and says whether it is still within today's limit. Server only.
create or replace function public.use_quota(uid uuid, what text, max_per_day int)
returns boolean language plpgsql security definer set search_path = public as $$
declare used int;
begin
  insert into usage_counts (user_id, day, kind, n) values (uid, current_date, what, 1)
  on conflict (user_id, day, kind) do update set n = usage_counts.n + 1
  returning n into used;
  return used <= max_per_day;
end $$;
revoke execute on function public.use_quota(uuid, text, int) from public, anon, authenticated;
grant execute on function public.use_quota(uuid, text, int) to service_role;

-- ---------- 2. Internal functions ----------
-- Trigger functions never need to be called through the API (triggers run them regardless).
revoke execute on function public.add_room_owner() from public, anon, authenticated;
revoke execute on function public.add_workspace_owner() from public, anon, authenticated;
revoke execute on function public.guard_membership_update() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.validate_input() from public, anon, authenticated;
revoke execute on function public.validate_room() from public, anon, authenticated;
revoke execute on function public.touch_updated_at() from public, anon, authenticated;
-- Helpers used inside policies and room functions: signed-in people only.
revoke execute on function public.room_role(uuid) from public, anon;
revoke execute on function public.shares_room_with(uuid) from public, anon;
revoke execute on function public.is_workspace_member(uuid) from public, anon;
grant execute on function public.room_role(uuid), public.shares_room_with(uuid), public.is_workspace_member(uuid) to authenticated;
-- The old trip vote count goes with the trip tables.
revoke execute on function public.trip_vote_counts(uuid) from public, anon, authenticated;
-- invite_preview and report_by_token stay open on purpose: invite and share links work before sign-in.

-- ---------- 3. search_path ----------
alter function public.room_id_from_path(text) set search_path = public;
alter function public.touch_updated_at() set search_path = public;
alter function public.is_anon() set search_path = public;

-- ---------- 4. auth.uid() once per query ----------
do $$
declare p record; q text; c text; stmt text;
begin
  for p in
    select schemaname, tablename, policyname, qual, with_check from pg_policies
    where schemaname = 'public'
      and (coalesce(qual,'') ~ 'auth\.(uid|jwt)\(\)' or coalesce(with_check,'') ~ 'auth\.(uid|jwt)\(\)')
  loop
    q := p.qual; c := p.with_check;
    -- skip policies that already use the select form
    if coalesce(q,'') ~* 'select auth\.(uid|jwt)\(\)' or coalesce(c,'') ~* 'select auth\.(uid|jwt)\(\)' then continue; end if;
    stmt := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
    if q is not null then stmt := stmt || ' using (' || regexp_replace(q, 'auth\.(uid|jwt)\(\)', '(select auth.\1())', 'g') || ')'; end if;
    if c is not null then stmt := stmt || ' with check (' || regexp_replace(c, 'auth\.(uid|jwt)\(\)', '(select auth.\1())', 'g') || ')'; end if;
    execute stmt;
  end loop;
end $$;

-- ---------- 5. Foreign-key indexes ----------
create index if not exists attachments_uploaded_by_idx on public.attachments (uploaded_by);
create index if not exists invites_created_by_idx on public.invites (created_by);
create index if not exists objections_user_id_idx on public.objections (user_id);
create index if not exists outcome_comments_user_id_idx on public.outcome_comments (user_id);
create index if not exists outcomes_logged_by_idx on public.outcomes (logged_by);
create index if not exists report_shares_created_by_idx on public.report_shares (created_by);
create index if not exists trip_votes_option_id_idx on public.trip_votes (option_id);
create index if not exists workspaces_owner_id_idx on public.workspaces (owner_id);

-- ---------- 6. Trip tables closed ----------
revoke all on public.trip_briefs, public.trip_member_briefs, public.trip_options, public.trip_votes from anon, authenticated;
