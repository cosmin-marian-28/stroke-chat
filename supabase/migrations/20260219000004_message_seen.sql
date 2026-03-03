-- Add seen_at column to messages for Instagram-style read receipts.
-- seen_at is set when the receiver opens the conversation and sees the message.
alter table public.messages
  add column if not exists seen_at timestamptz default null;

-- Allow participants to update seen_at on messages (only for marking as seen)
create policy "Participants can update seen_at"
  on public.messages for update to authenticated
  using (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  )
  with check (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );

-- Index for efficient "unseen messages" queries
create index if not exists idx_messages_seen
  on public.messages(convo_id, sender_id, seen_at)
  where seen_at is null;
