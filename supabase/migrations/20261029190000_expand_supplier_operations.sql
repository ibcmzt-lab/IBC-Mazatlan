-- IBC supplier operations expansion
-- Preserves the existing public site and current supplier-intake workflow.

begin;

alter table public.products
  add column if not exists package_format text,
  add column if not exists wholesale_cost numeric(12,2);

alter table public.products drop constraint if exists products_wholesale_cost_nonnegative;
alter table public.products add constraint products_wholesale_cost_nonnegative
  check (wholesale_cost is null or wholesale_cost >= 0);

alter table public.suppliers drop constraint if exists suppliers_status_check;
update public.suppliers
set status = case
  when lower(status) = 'active' then 'Active'
  when lower(status) in ('inactive', 'do_not_contact', 'archived') then 'Archived'
  else 'Pending Review'
end;
alter table public.suppliers alter column status set default 'Pending Review';
alter table public.suppliers add constraint suppliers_status_check
  check (status in ('Pending Review', 'Active', 'Archived'));

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  po_number text not null unique,
  order_date date not null default current_date,
  expected_delivery_date date,
  received_date date,
  status text not null default 'draft'
    check (status in ('draft','submitted','confirmed','in_transit','partially_received','received','cancelled')),
  currency char(3) not null default 'MXN',
  merchandise_subtotal numeric(14,2) not null default 0 check (merchandise_subtotal >= 0),
  freight_cost numeric(14,2) not null default 0 check (freight_cost >= 0),
  insurance_cost numeric(14,2) not null default 0 check (insurance_cost >= 0),
  customs_cost numeric(14,2) not null default 0 check (customs_cost >= 0),
  other_landed_cost numeric(14,2) not null default 0 check (other_landed_cost >= 0),
  total_landed_cost numeric(14,2) generated always as
    (merchandise_subtotal + freight_cost + insurance_cost + customs_cost + other_landed_cost) stored,
  freight_provider text,
  tracking_number text,
  tracking_url text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_description text not null,
  package_format text,
  quantity numeric(12,3) not null check (quantity > 0),
  unit_cost numeric(14,4) not null check (unit_cost >= 0),
  line_total numeric(14,2) generated always as (round(quantity * unit_cost, 2)) stored,
  created_at timestamptz not null default now()
);

create index if not exists purchase_orders_supplier_id_idx on public.purchase_orders(supplier_id);
create index if not exists purchase_orders_order_date_idx on public.purchase_orders(order_date desc);
create index if not exists purchase_orders_status_idx on public.purchase_orders(status);
create index if not exists purchase_order_items_order_id_idx on public.purchase_order_items(purchase_order_id);

create or replace function public.recalculate_purchase_order_subtotal()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  target_id uuid;
begin
  target_id := coalesce(new.purchase_order_id, old.purchase_order_id);
  update public.purchase_orders po
  set merchandise_subtotal = coalesce((
    select sum(poi.line_total)
    from public.purchase_order_items poi
    where poi.purchase_order_id = target_id
  ), 0),
  updated_at = now()
  where po.id = target_id;

  if tg_op = 'UPDATE' and old.purchase_order_id is distinct from new.purchase_order_id then
    update public.purchase_orders po
    set merchandise_subtotal = coalesce((
      select sum(poi.line_total)
      from public.purchase_order_items poi
      where poi.purchase_order_id = old.purchase_order_id
    ), 0),
    updated_at = now()
    where po.id = old.purchase_order_id;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists purchase_order_items_recalculate_subtotal on public.purchase_order_items;
create trigger purchase_order_items_recalculate_subtotal
after insert or update or delete on public.purchase_order_items
for each row execute function public.recalculate_purchase_order_subtotal();

alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
revoke all on public.purchase_orders from anon, authenticated;
revoke all on public.purchase_order_items from anon, authenticated;
grant select, insert, update, delete on public.purchase_orders to authenticated;
grant select, insert, update, delete on public.purchase_order_items to authenticated;

drop policy if exists "Approved team full access" on public.purchase_orders;
create policy "Approved team full access" on public.purchase_orders
for all to authenticated
using (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true))
with check (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true));

drop policy if exists "Approved team full access" on public.purchase_order_items;
create policy "Approved team full access" on public.purchase_order_items
for all to authenticated
using (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true))
with check (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true));

update storage.buckets
set public = false,
    file_size_limit = 26214400,
    allowed_mime_types = array[
      'application/pdf',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'image/jpeg',
      'image/png'
    ]
where id in ('supplier-submissions', 'ibc-supplier-catalogs');

drop policy if exists "Public can upload supplier submission files" on storage.objects;
create policy "Public can upload supplier submission files"
on storage.objects for insert to anon
with check (
  bucket_id = 'supplier-submissions'
  and (storage.foldername(name))[1] = 'incoming'
  and lower(storage.extension(name)) in ('pdf','xlsx','jpg','jpeg','png')
);

drop policy if exists "Approved team can manage supplier catalogs" on storage.objects;
create policy "Approved team can manage supplier catalogs"
on storage.objects for all to authenticated
using (
  bucket_id in ('supplier-submissions','ibc-supplier-catalogs')
  and exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true)
)
with check (
  bucket_id in ('supplier-submissions','ibc-supplier-catalogs')
  and exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true)
);

commit;