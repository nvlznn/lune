-- Called by the app before signing out so this device stops receiving the account's notifications.
create function public.unregister_device(p_token text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.devices where token = p_token and user_id = auth.uid()
$$;

revoke execute on function public.unregister_device(text) from public, anon;
grant execute on function public.unregister_device(text) to authenticated;
