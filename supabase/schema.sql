-- UMANG Products analytics schema (run once in Supabase: SQL Editor -> New query -> paste -> Run)
-- Privacy: analytics never store names, phone numbers or street addresses of customers.

create table if not exists public.events (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  visitor_id text, session_id text,
  type text not null,            -- page_view, product_view, add_to_bag, checkout_start, order
  page text, product_id text, qty int, meta jsonb, referrer text, device text
);
create index if not exists events_created_idx on public.events (created_at);
create index if not exists events_type_idx on public.events (type, created_at);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  ref text unique, items jsonb, subtotal int,
  city text, state text, pin text, payment text,
  status text not null default 'requested'
);
create index if not exists orders_created_idx on public.orders (created_at);

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text, text text not null, product text,
  approved boolean not null default false
);

create table if not exists public.supporters (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text, email text, phone text, how text
);

alter table public.events enable row level security;
alter table public.orders enable row level security;
alter table public.reviews enable row level security;
alter table public.supporters enable row level security;

-- Visitors may only ADD rows. Nobody can read them from the website.
create policy "visitors add events" on public.events for insert to anon with check (true);
create policy "visitors add orders" on public.orders for insert to anon with check (true);
create policy "visitors add reviews" on public.reviews for insert to anon with check (approved = false);
create policy "visitors add supporters" on public.supporters for insert to anon with check (true);
create policy "public reads approved reviews" on public.reviews for select to anon using (approved);

-- Full report as JSON for the last p_days days (used by the weekly email).
create or replace function public.report_json(p_days int default 7)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s timestamptz := now() - make_interval(days => p_days);
  ps timestamptz := now() - make_interval(days => p_days * 2);
  r jsonb;
begin
  select jsonb_build_object(
    'days', p_days,
    'visitors', (select count(distinct visitor_id) from events where created_at >= s),
    'visitors_prev', (select count(distinct visitor_id) from events where created_at >= ps and created_at < s),
    'sessions', (select count(distinct session_id) from events where created_at >= s),
    'page_views', (select count(*) from events where type = 'page_view' and created_at >= s),
    'orders', (select count(*) from orders where created_at >= s),
    'orders_prev', (select count(*) from orders where created_at >= ps and created_at < s),
    'order_value', (select coalesce(sum(subtotal), 0) from orders where created_at >= s),
    'supporters', (select count(*) from supporters where created_at >= s),
    'supporters_total', (select count(*) from supporters),
    'reviewers', (select count(*) from reviews where created_at >= s),
    'reviews_approved', (select count(*) from reviews where approved),
    'top_pages', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select page, count(*) as views, count(distinct visitor_id) as visitors
        from events where type = 'page_view' and created_at >= s
        group by page order by views desc limit 8) t),
    'top_viewed', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select product_id, max(meta->>'n') as name, count(*) as views
        from events where type = 'product_view' and created_at >= s and product_id is not null
        group by product_id order by views desc limit 8) t),
    'top_added', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select product_id, max(meta->>'n') as name, sum(coalesce(qty, 1)) as qty
        from events where type = 'add_to_bag' and created_at >= s and product_id is not null
        group by product_id order by qty desc limit 8) t),
    'top_ordered', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select i->>'id' as id, max(i->>'name') as name,
               sum((i->>'qty')::int) as qty,
               sum((i->>'qty')::int * coalesce((i->>'price')::int, 0)) as value
        from orders o, jsonb_array_elements(o.items) i
        where o.created_at >= s
        group by i->>'id' order by qty desc limit 10) t),
    'funnel', jsonb_build_object(
        'visitors', (select count(distinct visitor_id) from events where created_at >= s),
        'viewed_product', (select count(distinct visitor_id) from events where type = 'product_view' and created_at >= s),
        'added', (select count(distinct visitor_id) from events where type = 'add_to_bag' and created_at >= s),
        'checkout', (select count(distinct visitor_id) from events where type = 'checkout_start' and created_at >= s),
        'ordered', (select count(distinct visitor_id) from events where type = 'order' and created_at >= s)),
    'cities', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select city, state, count(*) as orders from orders where created_at >= s
        group by city, state order by orders desc limit 8) t),
    'sources', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select coalesce(nullif(regexp_replace(coalesce(referrer, ''), '^https?://([^/]+).*$', '\1'), ''), 'Direct') as src,
               count(distinct visitor_id) as visitors
        from events where type = 'page_view' and created_at >= s
        group by 1 order by visitors desc limit 8) t),
    'devices', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select device, count(distinct visitor_id) as visitors from events
        where created_at >= s group by device order by visitors desc) t),
    'daily', (select coalesce(jsonb_agg(to_jsonb(d) order by d.day), '[]'::jsonb) from (
        select g::date as day,
               (select count(distinct visitor_id) from events e where e.created_at::date = g::date) as visitors,
               (select count(*) from orders o where o.created_at::date = g::date) as orders
        from generate_series(s::date, now()::date, interval '1 day') g) d)
  ) into r;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Two admin portals, enforced on the server (not just hidden in the page)
--   role 'yojak' : sees everything (traffic, funnel, orders, reviews, supporters, emails)
--   role 'umang' : sees orders, reviews and a short sales summary only. No traffic, no supporter emails.
-- Change the two emails below BEFORE running if needed. Use lowercase.
-- ---------------------------------------------------------------------------
create table if not exists public.admins (
  email text primary key,
  role text not null check (role in ('yojak', 'umang'))
);
alter table public.admins enable row level security;   -- no policies: not readable from the website
insert into public.admins (email, role) values
  ('commsteam@yojak.org', 'yojak'),
  ('umangmahilaudyog@gmail.com', 'umang')
on conflict (email) do update set role = excluded.role;

create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.admins where email = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

-- Admins can read and update orders and reviews; only YOJAK can read supporters. Nobody can read events directly.
create policy "admins read orders" on public.orders for select to authenticated using (public.my_role() in ('yojak', 'umang'));
create policy "admins update orders" on public.orders for update to authenticated
  using (public.my_role() in ('yojak', 'umang')) with check (public.my_role() in ('yojak', 'umang'));
create policy "admins read reviews" on public.reviews for select to authenticated using (public.my_role() in ('yojak', 'umang'));
create policy "admins update reviews" on public.reviews for update to authenticated
  using (public.my_role() in ('yojak', 'umang')) with check (public.my_role() in ('yojak', 'umang'));
create policy "yojak reads supporters" on public.supporters for select to authenticated using (public.my_role() = 'yojak');

-- Full report: YOJAK only.
create or replace function public.admin_report(p_days int default 7)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.my_role(), '') <> 'yojak' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return public.report_json(p_days);
end $$;

-- Short report for the UMANG team (no traffic data).
create or replace function public.umang_report(p_days int default 7)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s timestamptz := now() - make_interval(days => p_days);
  ps timestamptz := now() - make_interval(days => p_days * 2);
begin
  if coalesce(public.my_role(), '') not in ('yojak', 'umang') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'days', p_days,
    'orders', (select count(*) from orders where created_at >= s),
    'orders_prev', (select count(*) from orders where created_at >= ps and created_at < s),
    'order_value', (select coalesce(sum(subtotal), 0) from orders where created_at >= s),
    'supporters', (select count(*) from supporters where created_at >= s),
    'reviewers', (select count(*) from reviews where created_at >= s),
    'reviews_pending', (select count(*) from reviews where not approved),
    'top_ordered', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select i->>'id' as id, max(i->>'name') as name, sum((i->>'qty')::int) as qty,
               sum((i->>'qty')::int * coalesce((i->>'price')::int, 0)) as value
        from orders o, jsonb_array_elements(o.items) i
        where o.created_at >= s group by i->>'id' order by qty desc limit 10) t),
    'cities', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select city, state, count(*) as orders from orders where created_at >= s
        group by city, state order by orders desc limit 8) t),
    'daily', (select coalesce(jsonb_agg(to_jsonb(d) order by d.day), '[]'::jsonb) from (
        select g::date as day, (select count(*) from orders o where o.created_at::date = g::date) as orders
        from generate_series(s::date, now()::date, interval '1 day') g) d)
  );
end $$;

revoke all on function public.report_json(int) from public, anon, authenticated;
grant execute on function public.report_json(int) to service_role;
revoke all on function public.admin_report(int) from public, anon;
grant execute on function public.admin_report(int) to authenticated;
revoke all on function public.umang_report(int) from public, anon;
grant execute on function public.umang_report(int) to authenticated;
revoke all on function public.my_role() from public, anon;
grant execute on function public.my_role() to authenticated;
