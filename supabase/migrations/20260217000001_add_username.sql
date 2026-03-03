-- Add unique username column to users table
alter table public.users add column if not exists username text;

-- Make username unique and not null (with a temp default for existing rows)
update public.users set username = id::text where username is null;
alter table public.users alter column username set not null;
alter table public.users add constraint users_username_unique unique (username);

-- Create index for fast username lookups
create index idx_users_username on public.users(username);

-- Allow any authenticated user to search users by username (for friend requests)
create policy "Users can search by username"
  on public.users for select to authenticated
  using (true);

-- Drop the old restrictive select policy
drop policy if exists "Users can read own profile" on public.users;
