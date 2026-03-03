-- Revert to using app.settings (pre-configured on hosted Supabase)
-- with msg_type addition and exception handler
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
  select * into _convo from public.conversations where id = NEW.convo_id;
  if _convo is null then return NEW; end if;

  for _recipient_id in
    select unnest(_convo.participants)
  loop
    if _recipient_id::text != NEW.sender_id then
      begin
        select email into _sender_email from public.users where id::text = NEW.sender_id;

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
      exception when others then
        raise warning 'notify_new_message failed: %', SQLERRM;
      end;
    end if;
  end loop;

  return NEW;
end;
$$;
