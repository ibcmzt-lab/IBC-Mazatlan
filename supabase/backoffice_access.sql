-- Una Más internal back-office access controls.
-- Run after supplier_intake.sql. Team membership is deliberately granted manually
-- by an administrator after the person's email has been verified in Supabase Auth.

create table if not exists public.team_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null default 'staff' check (role in ('admin','staff')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.team_members enable row level security;
revoke all on public.team_members from anon, authenticated;
grant select on public.team_members to authenticated;
drop policy if exists "Team members can see their own access record" on public.team_members;
create policy "Team members can see their own access record"
on public.team_members for select to authenticated
using (user_id = (select auth.uid()));

grant select, update on public.supplier_inquiries to authenticated;
drop policy if exists "Approved team can review supplier inquiries" on public.supplier_inquiries;
create policy "Approved team can review supplier inquiries"
on public.supplier_inquiries for select to authenticated
using (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true));
drop policy if exists "Approved team can update supplier inquiries" on public.supplier_inquiries;
create policy "Approved team can update supplier inquiries"
on public.supplier_inquiries for update to authenticated
using (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true))
with check (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true));

drop policy if exists "Approved team can view supplier submission files" on storage.objects;
create policy "Approved team can view supplier submission files"
on storage.objects for select to authenticated
using (
  bucket_id = 'supplier-submissions'
  and exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true)
);

do $$
declare t text;
begin
  foreach t in array array['suppliers','supplier_contacts','products','product_offers','supplier_documents','release_calendar','supplier_update_history']
  loop
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('drop policy if exists "Approved team full access" on public.%I', t);
    execute format(
      'create policy "Approved team full access" on public.%I for all to authenticated using (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true)) with check (exists (select 1 from public.team_members tm where tm.user_id = (select auth.uid()) and tm.active = true))',
      t
    );
  end loop;
end $$;

-- To approve the first admin, replace the UUID with the verified auth.users.id:
-- insert into public.team_members (user_id, email, role, active)
-- values ('AUTH-USER-UUID', 'ibc.mzt@gmail.com', 'admin', true)
-- on conflict (user_id) do update set role='admin', active=true;
