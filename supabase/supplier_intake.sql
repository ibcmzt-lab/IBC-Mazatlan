-- Una Más supplier intake backend
-- Applied to Supabase project kueckuienhnqmkgtgqpi on 2026-10-22.
-- Public users may submit an inquiry and upload files, but cannot read inquiries or uploaded documents.
create table if not exists public.supplier_inquiries (
  id uuid primary key default gen_random_uuid(),
  company_name text not null check (char_length(trim(company_name)) between 2 and 160),
  contact_name text not null check (char_length(trim(contact_name)) between 2 and 120),
  email text not null check (char_length(trim(email)) between 5 and 254),
  whatsapp text,
  supplier_type text not null default 'brewery'
    check (supplier_type in ('brewery','beverage_producer','distributor','equipment','other')),
  website text,
  country text not null default 'Mexico',
  regions_served text,
  product_summary text not null check (char_length(trim(product_summary)) between 5 and 5000),
  pricing_notes text,
  file_paths text[] not null default '{}',
  status text not null default 'new' check (status in ('new','reviewing','contacted','converted','closed')),
  created_at timestamptz not null default now()
);

alter table public.supplier_inquiries enable row level security;
revoke all on public.supplier_inquiries from anon, authenticated;
grant insert on public.supplier_inquiries to anon;
grant insert on public.supplier_inquiries to authenticated;

drop policy if exists "Public can submit supplier inquiries" on public.supplier_inquiries;
create policy "Public can submit supplier inquiries"
on public.supplier_inquiries for insert to anon
with check (
  char_length(trim(company_name)) between 2 and 160
  and char_length(trim(contact_name)) between 2 and 120
  and char_length(trim(email)) between 5 and 254
  and char_length(trim(product_summary)) between 5 and 5000
  and cardinality(file_paths) <= 5
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'supplier-submissions', 'supplier-submissions', false, 15728640,
  array[
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/msword',
    'text/csv', 'text/plain', 'image/jpeg', 'image/png', 'image/webp'
  ]
)
on conflict (id) do update
set public = false, file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public can upload supplier submission files" on storage.objects;
create policy "Public can upload supplier submission files"
on storage.objects for insert to anon
with check (
  bucket_id = 'supplier-submissions'
  and (storage.foldername(name))[1] = 'incoming'
  and lower(storage.extension(name)) in ('pdf','xlsx','xls','docx','doc','csv','txt','jpg','jpeg','png','webp')
);

-- Deliberately no anonymous SELECT, UPDATE, or DELETE policy.
-- Internal review dashboard and staff-only access policies are the next backend phase.
