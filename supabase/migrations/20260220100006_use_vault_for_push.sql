-- Use vault for service_role_key and hardcoded project URL
create or replace function public.notify_new_message()
returns trigger
security definer
language plpgsql
as $$
declare
  _convo record;
  _recipient_id uuid;
  _sender_email text;
  _svc_key text;
begin
  -- Read service role key from vault
  begin
    select decrypted_secret into _svc_key
      from vault.decrypted_secrets
      where name = 'service_role_key'
      limit 1;
  exception when others then
    return NEW;
  end;

  if _svc_key is null then
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
          url := 'https://dgwbbbkqripzscvtcnjf.supabase.co/functions/v1/push',
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
        raise warning 'notify_new_message failed: %', SQLERRM;
      end;
    end if;
  end loop;

  return NEW;
end;
$$;
