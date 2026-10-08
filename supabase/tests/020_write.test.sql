-- Writing pages: only tonight's, at night, once; sending is final; unsent pages can change any time.
begin;
select plan(38);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol', false));
select tests.remember('stranger', tests.create_user('stranger'));
select tests.befriend(tests.id('alice'), tests.id('bob'));

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

-- Checks before writing
select set_config('tests.path', tests.put_object(tests.id('alice')), false);
select tests.login_as(tests.id('alice'));
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')) - 1, current_setting('tests.path'), 'Old') $$,
  'P0001', 'invalid_day', 'only tonight''s page, no backfilling yesterday');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')) + 1, current_setting('tests.path'), 'Future') $$,
  'P0001', 'invalid_day', 'not tomorrow');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')), current_setting('tests.path'), '   ') $$,
  'P0001', 'text_required', 'text is required');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')), current_setting('tests.path'), repeat('a', 501)) $$,
  'P0001', 'text_too_long', 'text is at most 500 characters');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')),
       tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', 'No file') $$,
  'P0001', 'file_missing', 'the photo must be uploaded first');
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')), current_setting('tests.carol_path'), 'Not mine') $$,
  'P0001', 'invalid_path', 'cannot use someone else''s file');
select throws_ok(
  $$ insert into public.entries (user_id, day, storage_path, text)
     values (tests.id('alice'), '2000-01-01', current_setting('tests.path'), 'Direct') $$,
  '42501', null, 'no direct inserts');
select throws_ok(
  $$ insert into public.entry_recipients (entry_id, user_id) values (gen_random_uuid(), tests.id('bob')) $$,
  '42501', null, 'no direct sending');
select tests.logout();

-- A page only for yourself
select tests.remember('a_page', tests.write(tests.id('alice'), '{}', E'  Long day.\n\n\n\nGood dinner.  '));
select is((select day from public.entries where id = tests.id('a_page')), private.user_today(tests.id('alice')), 'tonight''s page');
select is((select text from public.entries where id = tests.id('a_page')), E'Long day.\n\nGood dinner.', 'text is tidied, line breaks kept');
select is((select sent_at from public.entries where id = tests.id('a_page')), null, 'not sent to anyone');

select tests.login_as(tests.id('alice'));
select throws_ok(
  $$ select public.write_entry(private.user_today(tests.id('alice')), current_setting('tests.path'), 'Again') $$,
  'P0001', 'already_written', 'one page per day');
select is(public.update_entry(tests.id('a_page'), 'Better words.') ->> 'text', 'Better words.', 'an unsent page''s text can change');
select isnt((select edited_at from public.entries where id = tests.id('a_page')), null, 'and it''s marked edited');
select set_config('tests.old_path', (select storage_path from public.entries where id = tests.id('a_page')), false);
select is(public.update_entry(tests.id('a_page'), 'New photo too.', current_setting('tests.path')) ->> 'storage_path',
  current_setting('tests.path'), 'so can its photo');
select tests.logout();
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.old_path')),
  'the replaced photo is queued for deletion');

-- Any time, not just at night
select tests.set_open(tests.id('alice'), false);
select tests.login_as(tests.id('alice'));
select lives_ok($$ select public.update_entry(tests.id('a_page'), 'Daytime edit') $$, 'unsent pages can be edited during the day');
select lives_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('entries', tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('alice')) $$,
  'and a new photo uploaded for them');
select public.delete_entry(tests.id('a_page'));
select tests.logout();
select ok(not exists (select 1 from public.entries where id = tests.id('a_page')), 'unsent pages can be deleted');
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.path')), 'with their photo');
select tests.set_open(tests.id('alice'), true);

-- Sending
select tests.remember('a_sent', tests.write(tests.id('alice'), array[tests.id('bob'), tests.id('stranger'), tests.id('alice')], 'For Bob'));
select is(array(select user_id from public.entry_recipients where entry_id = tests.id('a_sent')), array[tests.id('bob')],
  'sent to friends only; strangers and yourself are skipped');
select isnt((select sent_at from public.entries where id = tests.id('a_sent')), null, 'the page is now a letter');
select tests.login_as(tests.id('alice'));
select is(public.tonight() -> 'mine' -> 'recipients' -> 0 ->> 'name', 'bob', 'the writer sees who it went to');
select throws_ok($$ select public.update_entry(tests.id('a_sent'), 'Oops') $$, 'P0001', 'already_sent', 'a letter can''t be edited');
select throws_ok($$ select public.delete_entry(tests.id('a_sent')) $$, 'P0001', 'already_sent', 'or deleted');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('entries', tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('alice')) $$,
  '42501', null, 'no uploads once tonight''s page is sent and nothing else is unsent');
select tests.logout();

-- Recipients stay even if they leave; the letter stays locked.
select tests.login_as(tests.id('bob'));
select public.remove_friend(tests.id('alice'));
select tests.logout();
select tests.login_as(tests.id('alice'));
select throws_ok($$ select public.delete_entry(tests.id('a_sent')) $$, 'P0001', 'already_sent', 'still final after the recipient leaves');
select tests.logout();
select tests.befriend(tests.id('alice'), tests.id('bob'));

-- Sending later
select tests.remember('b_page', tests.write(tests.id('bob')));
select tests.login_as(tests.id('bob'));
select is(jsonb_array_length(public.add_recipients(tests.id('b_page'), array[tests.id('stranger')]) -> 'recipients'), 0,
  'adding only non-friends sends nothing');
select is((select sent_at from public.entries where id = tests.id('b_page')), null, 'and keeps the page unsent');
select is(public.add_recipients(tests.id('b_page'), array[tests.id('alice')]) -> 'recipients' -> 0 ->> 'name', 'alice',
  'a page kept to yourself can be sent later');
select throws_ok($$ select public.update_entry(tests.id('b_page'), 'Changed') $$, 'P0001', 'already_sent', 'and then it''s final');
select throws_ok($$ select public.add_recipients(tests.id('a_sent'), array[tests.id('bob')]) $$, 'P0001', 'entry_not_found',
  'only your own pages');
select tests.logout();

select tests.remember('b_old', tests.page_on(tests.id('bob'), private.user_today(tests.id('bob')) - 1));
select tests.login_as(tests.id('bob'));
select throws_ok($$ select public.add_recipients(tests.id('b_old'), array[tests.id('alice')]) $$, 'P0001', 'expired',
  'not after the page''s day has ended');
select lives_ok($$ select public.update_entry(tests.id('b_old'), 'Still mine to edit') $$, 'but an old unsent page can still be edited');
select tests.logout();

-- Storage policies
select tests.remember('dave', tests.create_user('dave'));
select tests.login_as(tests.id('dave'));
select lives_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('entries', tests.id('dave')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('dave')) $$,
  'upload into your own folder while you can write');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('entries', tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('dave')) $$,
  '42501', null, 'not into someone else''s folder');
select tests.logout();

select * from finish();
rollback;
