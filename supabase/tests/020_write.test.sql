-- Writing pages: only at night, today or yesterday, once per day, text required.
begin;
select plan(18);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('carol', tests.create_user('carol', false));

-- Closed
select set_config('tests.carol_path', tests.put_object(tests.id('carol')), false);
select tests.login_as(tests.id('carol'));
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('carol')), current_setting('tests.carol_path'), 'Hi') $$,
  'P0001', 'closed', 'closed during the day');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('entries', tests.id('carol')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('carol')) $$,
  '42501', null, 'Storage rejects uploads during the day too');
select tests.logout();

-- Open: today
select tests.remember('a_today', tests.write(tests.id('alice'), 0, E'  Long day.\n\n\n\nGood dinner.  '));
select is((select day from public.entries where id = tests.id('a_today')), private.user_today(tests.id('alice')), 'today''s page');
select is((select text from public.entries where id = tests.id('a_today')), E'Long day.\n\nGood dinner.', 'text is tidied, line breaks kept');

select set_config('tests.path', tests.put_object(tests.id('alice')), false);
select tests.login_as(tests.id('alice'));
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')), current_setting('tests.path'), 'Again') $$,
  'P0001', 'already_written', 'one page per day');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')) - 2, current_setting('tests.path'), 'Old') $$,
  'P0001', 'invalid_day', 'only today or yesterday');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')) + 1, current_setting('tests.path'), 'Future') $$,
  'P0001', 'invalid_day', 'not tomorrow');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')) - 1, current_setting('tests.path'), '   ') $$,
  'P0001', 'text_required', 'text is required');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')) - 1, current_setting('tests.path'), repeat('a', 501)) $$,
  'P0001', 'text_too_long', 'text is at most 500 characters');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')) - 1,
       tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', 'No file') $$,
  'P0001', 'file_missing', 'the photo must be uploaded first');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')) - 1, current_setting('tests.carol_path'), 'Not mine') $$,
  'P0001', 'invalid_path', 'cannot use someone else''s file');
select throws_ok(
  $$ insert into public.entries (user_id, day, storage_path, text)
     values (tests.id('alice'), '2000-01-01', current_setting('tests.path'), 'Direct') $$,
  '42501', null, 'no direct inserts');
select tests.logout();

-- Backfill yesterday
select lives_ok($$ select tests.write(tests.id('alice'), 1, 'Yesterday, written late.') $$, 'yesterday can be written tonight');

-- Storage policies
select tests.remember('bob', tests.create_user('bob'));
select tests.login_as(tests.id('bob'));
select lives_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('entries', tests.id('bob')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('bob')) $$,
  'upload into your own folder while open');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('entries', tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('bob')) $$,
  '42501', null, 'not into someone else''s folder');
select tests.logout();
select tests.login_as(tests.id('alice'));
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('entries', tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('alice')) $$,
  '42501', null, 'no uploads once today and yesterday are both written');
select tests.logout();

-- Editing text
select tests.login_as(tests.id('alice'));
select is(public.edit_entry_text(tests.id('a_today'), 'Better words.') ->> 'text', 'Better words.', 'text can be edited at night');
select tests.logout();
select tests.set_open(tests.id('alice'), false);
select tests.login_as(tests.id('alice'));
select throws_ok($$ select public.edit_entry_text(tests.id('a_today'), 'Daytime edit') $$, 'P0001', 'closed', 'but not during the day');
select tests.logout();

select * from finish();
rollback;
