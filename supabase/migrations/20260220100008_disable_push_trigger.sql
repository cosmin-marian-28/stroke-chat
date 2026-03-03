-- Disable the pg_net trigger since push is now sent from the client
drop trigger if exists on_new_message_push on public.messages;
