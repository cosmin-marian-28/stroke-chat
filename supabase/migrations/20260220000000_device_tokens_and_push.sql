-- Device tokens table for FCM push notifications
create table if not exists public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null,
  platform text not null default 'ios',
  updated_at timestamptz default now(),
  unique(user_id, token)
);

alter table public.device_tokens enable row level security;

create index idx_device_tokens_user on public.device_tokens(user_id);

create policy "Users can read own tokens"
  on public.device_tokens for select to authenticated
  using (auth.uid() = user_id);

create policy "Users can insert own tokens"
  on public.device_tokens for insert to authenticated
  with check (auth.uid() = user_id);

create policy "Users can update own tokens"
  on public.device_tokens for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Users can delete own tokens"
  on public.device_tokens for delete to authenticated
  using (auth.uid() = user_id);

-- Function to send push notification via Edge Function on new message
create or replace function public.notify_new_message()
returns trigger
security definer
language plpgsql
as $$
declare
  _convo record;
  _recipient_id uuid;
  _sender_email text;
begin
  -- Get conversation participants
  select * into _convo from public.conversations where id = NEW.convo_id;
  if _convo is null then return NEW; end if;

  -- Find the recipient (the participant who is NOT the sender)
  for _recipient_id in
    select unnest(_convo.participants)
  loop
    if _recipient_id::text != NEW.sender_id then
      -- Get sender email for display
      select email into _sender_email from public.users where id::text = NEW.sender_id;

      -- Call edge function via pg_net
      perform net.http_post(
        url := current_setting('app.settings.supabase_url', true) || '/functions/v1/push',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
        ),
        body := jsonb_build_object(
          'recipient_id', _recipient_id,
          'sender_email', coalesce(_sender_email, 'Someone'),
          'msg_type', coalesce(NEW.type, 'text')
        )
      );
    end if;
  end loop;

  return NEW;
end;
$$;

create trigger on_new_message_push
  after insert on public.messages
  for each row execute function public.notify_new_message();
