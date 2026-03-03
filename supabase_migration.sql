-- ============================================================
-- StrokeChat: Firebase → Supabase migration
-- Run this in Supabase SQL Editor (Dashboard → SQL Editor)
-- ============================================================

-- 1. Users table (profiles)
create table if not exists public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  created_at timestamptz default now()
);

alter table public.users enable row level security;

create policy "Users can read own profile"
  on public.users for select to authenticated
  using ((select auth.uid()) = id);

create policy "Users can insert own profile"
  on public.users for insert to authenticated
  with check ((select auth.uid()) = id);

create policy "Users can update own profile"
  on public.users for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- 2. Friends table
create table if not exists public.friends (
  user_id uuid not null references public.users(id) on delete cascade,
  friend_id uuid not null references public.users(id) on delete cascade,
  email text not null,
  nickname text default '',
  added_at timestamptz default now(),
  primary key (user_id, friend_id)
);

alter table public.friends enable row level security;

create index idx_friends_user_id on public.friends(user_id);
create index idx_friends_friend_id on public.friends(friend_id);

create policy "Users can read own friends"
  on public.friends for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users can insert own friends"
  on public.friends for insert to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users can update own friends"
  on public.friends for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users can delete own friends"
  on public.friends for delete to authenticated
  using ((select auth.uid()) = user_id);

-- 3. Friend requests table
create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  to_uid uuid not null references public.users(id) on delete cascade,
  from_uid uuid not null references public.users(id) on delete cascade,
  from_email text not null,
  status text not null default 'pending',
  created_at timestamptz default now()
);

alter table public.friend_requests enable row level security;

create index idx_friend_requests_to on public.friend_requests(to_uid, status);
create index idx_friend_requests_from on public.friend_requests(from_uid);

create policy "Users can read requests sent to them"
  on public.friend_requests for select to authenticated
  using ((select auth.uid()) = to_uid);

create policy "Users can insert requests"
  on public.friend_requests for insert to authenticated
  with check ((select auth.uid()) = from_uid);

create policy "Users can update requests sent to them"
  on public.friend_requests for update to authenticated
  using ((select auth.uid()) = to_uid)
  with check ((select auth.uid()) = to_uid);

create policy "Users can delete requests sent to them"
  on public.friend_requests for delete to authenticated
  using ((select auth.uid()) = to_uid);

-- 4. Conversations table
create table if not exists public.conversations (
  id text primary key,
  participants uuid[] not null,
  session_version int default 0,
  chat_bg text default 'black',
  created_at timestamptz default now()
);

alter table public.conversations enable row level security;

create policy "Participants can read conversation"
  on public.conversations for select to authenticated
  using ((select auth.uid()) = any(participants));

create policy "Participants can insert conversation"
  on public.conversations for insert to authenticated
  with check ((select auth.uid()) = any(participants));

create policy "Participants can update conversation"
  on public.conversations for update to authenticated
  using ((select auth.uid()) = any(participants))
  with check ((select auth.uid()) = any(participants));

create policy "Participants can delete conversation"
  on public.conversations for delete to authenticated
  using ((select auth.uid()) = any(participants));

-- 5. Messages table
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  convo_id text not null references public.conversations(id) on delete cascade,
  sender_id text not null,
  session_id text,
  blob text default '',
  v int default 0,
  type text,
  gif_url text,
  created_at timestamptz default now()
);

alter table public.messages enable row level security;

create index idx_messages_convo on public.messages(convo_id, created_at desc);

create policy "Participants can read messages"
  on public.messages for select to authenticated
  using (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );

create policy "Participants can insert messages"
  on public.messages for insert to authenticated
  with check (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );

create policy "Participants can delete messages"
  on public.messages for delete to authenticated
  using (
    exists (
      select 1 from public.conversations
      where id = convo_id
      and (select auth.uid()) = any(participants)
    )
  );

-- 6. Realtime: enable broadcast triggers for messages and conversations
-- Messages broadcast trigger
create or replace function public.broadcast_new_message()
returns trigger
security definer
language plpgsql
as $$
begin
  perform realtime.broadcast_changes(
    'convo:' || NEW.convo_id,
    TG_OP,
    TG_OP,
    TG_TABLE_NAME,
    TG_TABLE_SCHEMA,
    NEW,
    OLD
  );
  return NEW;
end;
$$;

create trigger messages_broadcast
  after insert on public.messages
  for each row execute function public.broadcast_new_message();

-- Conversation updates broadcast trigger
create or replace function public.broadcast_convo_update()
returns trigger
security definer
language plpgsql
as $$
begin
  perform realtime.broadcast_changes(
    'convo_meta:' || NEW.id,
    TG_OP,
    TG_OP,
    TG_TABLE_NAME,
    TG_TABLE_SCHEMA,
    NEW,
    OLD
  );
  return NEW;
end;
$$;

create trigger convo_broadcast
  after update on public.conversations
  for each row execute function public.broadcast_convo_update();

-- Friend requests broadcast trigger
create or replace function public.broadcast_friend_request()
returns trigger
security definer
language plpgsql
as $$
begin
  perform realtime.broadcast_changes(
    'requests:' || NEW.to_uid::text,
    TG_OP,
    TG_OP,
    TG_TABLE_NAME,
    TG_TABLE_SCHEMA,
    NEW,
    OLD
  );
  return NEW;
end;
$$;

create trigger friend_request_broadcast
  after insert on public.friend_requests
  for each row execute function public.broadcast_friend_request();

-- Friends list broadcast trigger
create or replace function public.broadcast_friend_change()
returns trigger
security definer
language plpgsql
as $$
begin
  perform realtime.broadcast_changes(
    'friends:' || COALESCE(NEW.user_id, OLD.user_id)::text,
    TG_OP,
    TG_OP,
    TG_TABLE_NAME,
    TG_TABLE_SCHEMA,
    NEW,
    OLD
  );
  return COALESCE(NEW, OLD);
end;
$$;

create trigger friends_broadcast
  after insert or delete on public.friends
  for each row execute function public.broadcast_friend_change();

-- RLS on realtime.messages for private channels
create policy "Authenticated users can receive broadcasts"
  on realtime.messages for select to authenticated
  using (true);

create policy "Authenticated users can send broadcasts"
  on realtime.messages for insert to authenticated
  with check (true);
