-- Fix friend_request broadcast: fire on INSERT and DELETE, notify both parties
create or replace function public.broadcast_friend_request()
returns trigger
security definer
language plpgsql
as $$
declare
  row record;
begin
  row := coalesce(NEW, OLD);
  -- Notify the receiver
  perform realtime.broadcast_changes(
    'requests:' || row.to_uid::text,
    TG_OP, TG_OP, TG_TABLE_NAME, TG_TABLE_SCHEMA, NEW, OLD
  );
  -- Notify the sender too
  perform realtime.broadcast_changes(
    'requests:' || row.from_uid::text,
    TG_OP, TG_OP, TG_TABLE_NAME, TG_TABLE_SCHEMA, NEW, OLD
  );
  return row;
end;
$$;

-- Drop old trigger and recreate with INSERT + DELETE
drop trigger if exists friend_request_broadcast on public.friend_requests;
create trigger friend_request_broadcast
  after insert or delete on public.friend_requests
  for each row execute function public.broadcast_friend_request();
