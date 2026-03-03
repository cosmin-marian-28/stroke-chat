-- Placed stickers table — floating stickers on chat canvas
create table if not exists public.placed_stickers (
  id uuid primary key default gen_random_uuid(),
  convo_id text not null references public.conversations(id) on delete cascade,
  sender_id text not null,
  url text not null,
  x double precision not null default 0,
  y double precision not null default 0,
  scale double precision not null default 1,
  created_at timestamptz default now()
);

alter table public.placed_stickers enable row level security;

create index idx_placed_stickers_convo on public.placed_stickers(convo_id);

create policy "Participants can read placed stickers"
  on public.placed_stickers for select to authenticated
  using (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );

create policy "Participants can insert placed stickers"
  on public.placed_stickers for insert to authenticated
  with check (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );

create policy "Participants can delete placed stickers"
  on public.placed_stickers for delete to authenticated
  using (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );
