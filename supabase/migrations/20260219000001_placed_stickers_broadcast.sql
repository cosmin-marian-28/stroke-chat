-- Broadcast trigger for placed_stickers so receivers see new stickers in real-time
create or replace function public.broadcast_placed_sticker()
returns trigger
security definer
language plpgsql
as $$
begin
  perform realtime.broadcast_changes(
    'stickers:' || coalesce(NEW.convo_id, OLD.convo_id),
    TG_OP,
    TG_OP,
    TG_TABLE_NAME,
    TG_TABLE_SCHEMA,
    NEW,
    OLD
  );
  return coalesce(NEW, OLD);
end;
$$;

create trigger placed_stickers_broadcast
  after insert or delete on public.placed_stickers
  for each row execute function public.broadcast_placed_sticker();
