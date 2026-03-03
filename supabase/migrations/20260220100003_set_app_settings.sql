-- Ensure pg_net is enabled
create extension if not exists pg_net with schema extensions;

-- Rewrite trigger: try app.settings first, fall back to hardcoded URL + vault
create or replace function public.notify_new_message()
returns trigger
security definer
language plpgsql
as $$
declare
  _convo record;
  _recipient_id uuid;
  _sender_email text;
  _base_url text;
  _svc_key text;
begin
  -- Try app.settings first (works on most hosted Supabase projects)
  _base_url := coalesce(
    current_setting('app.settings.supabase_url', true),
    'https://dgwbbbkqripzscvtcnjf.supabase.co'
  );
  _svc_key := current_setting('app.settings.service_role_key', true);

  -- If no service key from settings, try vault
  if _svc_key is null then
    begin
      select decrypted_secret into _svc_key
        from vault.decrypted_secrets
        where name = 'service_role_key'
        limit 1;
    exception when others then
      null;
    end;
  end if;

  -- No key available — skip notification but let insert succeed
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
          url := _base_url || '/functions/v1/push',
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
        raise warning 'notify_new_message push failed: %', SQLERRM;
      end;
    end if;
  end loop;

  return NEW;
end;
$$;
