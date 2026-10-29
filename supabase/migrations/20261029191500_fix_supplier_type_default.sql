-- The existing supplier_type check allows 'brewery' but the old default was 'producer'.
-- Align the default with the permitted values so new supplier records can be created.
alter table public.suppliers alter column supplier_type set default 'brewery';
