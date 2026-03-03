-- Drawing sessions persistence table
create table if not exists public.drawing_sessions (
  convo_id text primary key references public.conversations(id) on delete cascade,
  pages_json jsonb not null default '[]'::jsonb,
  updated_at timestamptz default now()
);

alter table public.drawing_sessions enable row level security;

create policy "Participants can read drawing sessions"
  on public.drawing_sessions for select to authenticated
  using (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );

create policy "Participants can insert drawing sessions"
  on public.drawing_sessions for insert to authenticated
  with check (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );

create policy "Participants can update drawing sessions"
  on public.drawing_sessions for update to authenticated
  using (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );
