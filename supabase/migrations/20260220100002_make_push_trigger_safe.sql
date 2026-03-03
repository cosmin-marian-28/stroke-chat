-- Make the push notification trigger fault-tolerant so it never blocks message inserts
create or replace function public.notify_new_message()
returns trigger
security definer
language plpgsql
as $$
declare
  _convo record;
  _recipient_id uuid;
  _sender_email text;
  _supa_url text;
  _svc_key text;
begin
  -- Get settings; bail silently if not configured
  _supa_url := current_setting('app.settings.supabase_url', true);
  _svc_key  := current_setting('app.settings.service_role_key', true);
  if _supa_url is null or _svc_key is null then
    return NEW;
  end if;

  select * into _convo from public.conversations where id = NEW.convo_id;
  if _convo is null then return NEW; end if;

  for _recipient_id in
    select unnest(_convo.participants)
  loop
    if _recipient_id::text != NEW.sender_id then
      begin
        select email into _sender_email from public.users where id::text = NEW.sender_id;

        perform net.http_post(
          url := _supa_url || '/functions/v1/push',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || _svc_key
          ),
          body := jsonb_build_object(
            'recipient_id', _recipient_id,
            'sender_email', coalesce(_sender_email, 'Someone'),
            'msg_type', coalesce(NEW.type, 'text')
          )
        );
      exception when others then
        -- Never block the insert — just log and move on
        raise warning 'notify_new_message failed: %', SQLERRM;
      end;
    end if;
  end loop;

  return NEW;
end;
$$;
