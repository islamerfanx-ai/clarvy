-- Revenue (decided 2026-10-23): the operator records subscriptions and invoices by hand on the admin page;
-- Stripe will write to the same tables later (source = 'stripe', external_id). All amounts are US dollars.
-- Server only: nobody reads or writes these from the browser. The numbers come from admin_revenue().

-- A customer is a personal account (user_id), an organisation (workspace_id), or only a name (an offline client).
-- Changing plan = end the old subscription and start a new one the same day; the movements show it as expansion.
create table revenue_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references profiles (id) on delete set null,
  workspace_id  uuid references workspaces (id) on delete set null,
  customer_name text not null check (length(trim(customer_name)) between 1 and 160),
  plan          text not null check (plan in ('small', 'team', 'organisation', 'other')),
  amount        numeric(12, 2) not null check (amount >= 0),          -- per period
  period        text not null default 'month' check (period in ('month', 'year')),
  started_on    date not null default current_date,
  renews_on     date,
  ended_on      date,                                                 -- first day without it
  end_reason    text check (length(end_reason) <= 300),
  notes         text check (length(notes) <= 500),
  source        text not null default 'manual' check (source in ('manual', 'stripe')),
  external_id   text unique check (length(external_id) <= 120),
  created_by    uuid references profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  check (ended_on is null or ended_on >= started_on)
);
create index revenue_subscriptions_user_idx on revenue_subscriptions (user_id);
create index revenue_subscriptions_workspace_idx on revenue_subscriptions (workspace_id);

create table revenue_invoices (
  id              uuid primary key default gen_random_uuid(),
  subscription_id uuid references revenue_subscriptions (id) on delete set null,
  user_id         uuid references profiles (id) on delete set null,
  workspace_id    uuid references workspaces (id) on delete set null,
  customer_name   text not null check (length(trim(customer_name)) between 1 and 160),
  kind            text not null check (kind in ('subscription', 'facilitated', 'extra_rooms', 'setup', 'other')),
  number          text unique check (length(number) <= 40),
  amount          numeric(12, 2) not null check (amount > 0),
  issued_on       date not null default current_date,
  due_on          date not null default current_date + 14,
  paid_on         date,
  void            boolean not null default false,
  notes           text check (length(notes) <= 500),
  source          text not null default 'manual' check (source in ('manual', 'stripe')),
  external_id     text unique check (length(external_id) <= 120),
  created_by      uuid references profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  check (due_on >= issued_on),
  check (paid_on is null or not void)
);
create index revenue_invoices_subscription_idx on revenue_invoices (subscription_id);
create index revenue_invoices_user_idx on revenue_invoices (user_id);
create index revenue_invoices_workspace_idx on revenue_invoices (workspace_id);

alter table revenue_subscriptions enable row level security;
alter table revenue_invoices enable row level security;
revoke all on revenue_subscriptions, revenue_invoices from anon, authenticated;

create function admin_revenue() returns jsonb
language sql stable security definer set search_path = public as $$
with
subs as (select s.*, coalesce(s.workspace_id::text, s.user_id::text, 'n:' || lower(trim(s.customer_name))) as ck,
                s.amount / case when s.period = 'year' then 12 else 1 end as mrr
         from revenue_subscriptions s),
inv as (select i.*, coalesce(i.workspace_id::text, i.user_id::text, 'n:' || lower(trim(i.customer_name))) as ck
        from revenue_invoices i where not i.void),
-- Month ends for the last 12 months (this month: today).
pts as (select m::date as m, least((m + interval '1 month' - interval '1 day')::date, current_date) as d, (m - interval '1 day')::date as pd
        from generate_series(date_trunc('month', current_date) - interval '11 months', date_trunc('month', current_date), interval '1 month') m),
keys as (select distinct ck from subs),
cust_m as (select p.m, k.ck,
             coalesce((select sum(mrr) from subs s where s.ck = k.ck and s.started_on <= p.d and (s.ended_on is null or s.ended_on > p.d)), 0) as cur,
             coalesce((select sum(mrr) from subs s where s.ck = k.ck and s.started_on <= p.pd and (s.ended_on is null or s.ended_on > p.pd)), 0) as prev
           from pts p cross join keys k),
moves as (select m, sum(cur) as mrr,
            coalesce(sum(cur) filter (where prev = 0 and cur > 0), 0) as new,
            coalesce(sum(cur - prev) filter (where prev > 0 and cur > prev), 0) as expansion,
            coalesce(sum(prev - cur) filter (where cur > 0 and cur < prev), 0) as contraction,
            coalesce(sum(prev) filter (where prev > 0 and cur = 0), 0) as churned,
            count(*) filter (where cur > 0) as customers,
            count(*) filter (where prev > 0 and cur = 0) as lost,
            count(*) filter (where prev > 0) as start_customers,
            sum(prev) as start_mrr
          from cust_m group by m),
recent3 as (select * from moves where m > (date_trunc('month', current_date) - interval '3 months')::date),
active as (select * from subs where started_on <= current_date and (ended_on is null or ended_on > current_date)),
cust as (select ck, max(customer_name) as name, (array_agg(plan order by mrr desc))[1] as plan, sum(mrr) as mrr,
                min(started_on) as since, min(renews_on) as renews_on,
                (array_agg(user_id) filter (where user_id is not null))[1] as user_id,
                (array_agg(workspace_id) filter (where workspace_id is not null))[1] as workspace_id
         from active group by ck),
cust_x as (
  select c.*, coalesce(pu.country, pa.country) as country, coalesce(pu.sector, pa.sector) as sector,
    coalesce((select sum(amount) from inv where inv.ck = c.ck and inv.paid_on is not null), 0) as paid_total,
    coalesce(case when c.workspace_id is not null
      then (select sum(u.cost) from ai_usage u join rooms r on r.id = u.room_id where r.workspace_id = c.workspace_id and u.created_at > now() - interval '30 days')
      else (select sum(u.cost) from ai_usage u where u.user_id = c.user_id and u.created_at > now() - interval '30 days') end, 0) as ai_30d
  from cust c
  left join profiles pu on pu.id = c.user_id
  left join lateral (select p.country, p.sector from workspace_members wm join profiles p on p.id = wm.user_id
                     where wm.workspace_id = c.workspace_id and wm.role = 'admin' order by wm.joined_at limit 1) pa on true),
paying_people as (select user_id from cust where user_id is not null
                  union select wm.user_id from cust c join workspace_members wm on wm.workspace_id = c.workspace_id),
accounts as (select u.id from auth.users u where not coalesce(u.is_anonymous, false)),
now_m as (select * from moves where m = date_trunc('month', current_date)::date),
last_m as (select * from moves where m = (date_trunc('month', current_date) - interval '1 month')::date),
rates as (select
    sum(lost)::numeric / nullif(sum(start_customers), 0) as logo_churn,
    sum(churned) / nullif(sum(start_mrr), 0) as revenue_churn,
    (sum(start_mrr) + sum(expansion) - sum(contraction) - sum(churned)) / nullif(sum(start_mrr), 0) as nrr
  from recent3)
select jsonb_build_object(
  'generated_at', now(),
  'now', jsonb_build_object(
    'mrr', round(coalesce((select sum(mrr) from cust), 0), 2),
    'arr', round(coalesce((select sum(mrr) from cust), 0) * 12, 2),
    'mrr_last_month', round(coalesce((select mrr from last_m), 0), 2),
    'customers', (select count(*) from cust),
    'arpa', round((select avg(mrr) from cust), 2),
    'paying_people', (select count(*) from paying_people),
    'free_accounts', (select count(*) from accounts a where a.id not in (select user_id from paying_people)),
    'cash_month', round(coalesce((select sum(amount) from inv where paid_on >= date_trunc('month', current_date)), 0), 2),
    'cash_12m', round(coalesce((select sum(amount) from inv where paid_on > current_date - 365), 0), 2),
    'ai_30d', round(coalesce((select sum(cost) from ai_usage where created_at > now() - interval '30 days'), 0), 2),
    'logo_churn', round(100 * (select logo_churn from rates), 1),
    'revenue_churn', round(100 * (select revenue_churn from rates), 1),
    'nrr', round(100 * (select nrr from rates), 1),
    'ltv', round((select avg(mrr) from cust) / nullif((select revenue_churn from rates), 0), 0)),

  'months', (select coalesce(jsonb_agg(jsonb_build_object(
      'month', p.m, 'mrr', round(coalesce(mv.mrr, 0), 2), 'new', round(coalesce(mv.new, 0), 2), 'expansion', round(coalesce(mv.expansion, 0), 2),
      'contraction', round(coalesce(mv.contraction, 0), 2), 'churned', round(coalesce(mv.churned, 0), 2),
      'customers', coalesce(mv.customers, 0), 'lost', coalesce(mv.lost, 0),
      'cash', round(coalesce((select sum(amount) from inv where paid_on >= p.m and paid_on < p.m + interval '1 month'), 0), 2),
      'invoiced', round(coalesce((select sum(amount) from inv where issued_on >= p.m and issued_on < p.m + interval '1 month'), 0), 2),
      'one_off', round(coalesce((select sum(amount) from inv where kind <> 'subscription' and paid_on >= p.m and paid_on < p.m + interval '1 month'), 0), 2),
      'ai_cost', round(coalesce((select sum(cost) from ai_usage where created_at >= p.m and created_at < p.m + interval '1 month'), 0), 2)
    ) order by p.m), '[]'::jsonb) from pts p left join moves mv on mv.m = p.m),

  'plans', (select coalesce(jsonb_agg(jsonb_build_object('plan', plan, 'customers', n, 'mrr', round(mrr, 2), 'ai_30d', round(ai, 2)) order by mrr desc), '[]'::jsonb)
            from (select plan, count(*) n, sum(mrr) mrr, sum(ai_30d) ai from cust_x group by plan) x),
  'one_off', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'amount', round(a, 2), 'n', n) order by a desc), '[]'::jsonb)
              from (select kind, sum(amount) a, count(*) n from inv where paid_on > current_date - 365 group by kind) x),
  'countries', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'mrr', round(mrr, 2), 'n', n) order by mrr desc), '[]'::jsonb)
                from (select coalesce(country, '?') k, sum(mrr) mrr, count(*) n from cust_x group by 1) x),
  'sectors', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'mrr', round(mrr, 2), 'n', n) order by mrr desc), '[]'::jsonb)
              from (select coalesce(sector, '?') k, sum(mrr) mrr, count(*) n from cust_x group by 1) x),
  'customers', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'plan', plan, 'mrr', round(mrr, 2), 'since', since, 'renews_on', renews_on,
                  'country', country, 'sector', sector, 'paid_total', round(paid_total, 2), 'ai_30d', round(ai_30d, 2), 'org', workspace_id is not null) order by mrr desc), '[]'::jsonb)
                from cust_x),

  'open_invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'number', number, 'customer', customer_name, 'kind', kind, 'amount', amount,
                      'issued_on', issued_on, 'due_on', due_on, 'days_overdue', greatest(current_date - due_on, 0)) order by due_on), '[]'::jsonb)
                    from inv where paid_on is null),
  'unpaid', round(coalesce((select sum(amount) from inv where paid_on is null), 0), 2),
  'overdue', round(coalesce((select sum(amount) from inv where paid_on is null and due_on < current_date), 0), 2),
  'paid_recent', (select coalesce(jsonb_agg(jsonb_build_object('number', number, 'customer', customer_name, 'kind', kind, 'amount', amount, 'paid_on', paid_on,
                    'days_to_pay', paid_on - issued_on) order by paid_on desc), '[]'::jsonb)
                  from (select * from inv where paid_on is not null order by paid_on desc limit 20) x),
  'days_to_pay', (select round(avg(paid_on - issued_on), 1) from inv where paid_on > current_date - 180),
  'renewals', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'customer', customer_name, 'plan', plan, 'amount', amount, 'period', period, 'renews_on', renews_on) order by renews_on), '[]'::jsonb)
               from active where renews_on between current_date and current_date + 30),
  'churned', (select coalesce(jsonb_agg(jsonb_build_object('customer', customer_name, 'plan', plan, 'mrr', round(mrr, 2), 'ended_on', ended_on, 'reason', end_reason,
                'months', (ended_on - started_on) / 30) order by ended_on desc), '[]'::jsonb)
              from subs s where s.ended_on between current_date - 180 and current_date
                and not exists (select 1 from active a where a.ck = s.ck)),
  'subscriptions', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'customer', customer_name, 'plan', plan, 'amount', amount, 'period', period,
                      'started_on', started_on, 'renews_on', renews_on, 'source', source) order by customer_name), '[]'::jsonb)
                    from active)
)
$$;
revoke execute on function admin_revenue() from public, anon, authenticated;
grant execute on function admin_revenue() to service_role;
