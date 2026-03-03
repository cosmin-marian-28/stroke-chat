-- Add duration_ms column for voice messages
alter table public.messages
add column if not exists duration_ms integer default 0;
