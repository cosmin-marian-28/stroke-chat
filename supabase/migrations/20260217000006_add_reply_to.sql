-- Add reply_to column for message replies
alter table public.messages
add column if not exists reply_to uuid references public.messages(id) on delete set null;
