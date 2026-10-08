-- Avatars: upload into your own folder, set, replace (old one deleted), shown to friends, deleted with the account.
begin;
select plan(9);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.befriend(tests.id('alice'), tests.id('bob'));

-- Uploading
select tests.login_as(tests.id('alice'));
select lives_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('avatars', tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('alice')) $$,
  'upload an avatar into your own folder');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('avatars', tests.id('bob')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('alice')) $$,
  '42501', null, 'not into someone else''s');
select tests.logout();

-- Setting
select set_config('tests.first', tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', false);
insert into storage.objects (bucket_id, name, owner) values ('avatars', current_setting('tests.first'), tests.id('alice'));
select tests.login_as(tests.id('alice'));
select is((public.set_avatar(current_setting('tests.first'))).avatar_path, current_setting('tests.first'), 'set your avatar');
select throws_ok(
  $$ select public.set_avatar(tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg') $$,
  'P0001', 'file_missing', 'the file must be uploaded first');
select tests.logout();

select tests.login_as(tests.id('bob'));
select is(public.friends() -> 0 ->> 'avatar_path', current_setting('tests.first'), 'friends get the avatar path');
select is((select count(*)::integer from storage.objects where name = current_setting('tests.first')), 1, 'and can read the file');
select tests.logout();

-- Replacing
select set_config('tests.second', tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', false);
insert into storage.objects (bucket_id, name, owner) values ('avatars', current_setting('tests.second'), tests.id('alice'));
select tests.login_as(tests.id('alice'));
select public.set_avatar(current_setting('tests.second'));
select tests.logout();
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.first') and bucket_id = 'avatars'),
  'the replaced avatar is queued for deletion');

-- Removing and deleting the account
select tests.login_as(tests.id('alice'));
select is((public.remove_avatar()).avatar_path, null, 'remove your avatar (back to initials)');
select public.set_avatar(current_setting('tests.second'));
select public.delete_account();
select tests.logout();
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.second')),
  'deleting the account queues the avatar for deletion');

select * from finish();
rollback;
