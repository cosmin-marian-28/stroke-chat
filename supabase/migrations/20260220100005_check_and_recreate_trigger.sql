-- Drop and recreate the trigger to make sure it exists
drop trigger if exists on_new_message_push on public.messages;

create trigger on_new_message_push
  after insert on public.messages
  for each row execute function public.notify_new_message();
