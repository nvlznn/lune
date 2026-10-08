-- Files, profiles, cleanup, account deletion.
begin;
select plan(12);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('stranger', tests.create_user('stranger'));
select tests.befriend(tests.id('alice'), tests.id('bob'));

select tests.remember('a1', tests.write(tests.id('alice')));
select set_config('tests.a_path', (select storage_path from public.entries where id = tests.id('a1')), false);

-- Files follow the same rule as pages.
select tests.login_as(tests.id('bob'));
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 0,
  'a friend can''t read the file before writing tonight');
select tests.logout();
select tests.write(tests.id('bob'));
select tests.login_as(tests.id('bob'));
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 1,
  'after writing, the friend can read it');
select tests.logout();
select tests.login_as(tests.id('stranger'));
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 0,
  'guessing a path gets nothing');
select is((select count(*)::integer from public.profiles where id = tests.id('alice')), 0, 'strangers can''t see your profile');
select tests.logout();
select tests.set_open(tests.id('alice'), false);
select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 1,
  'you can always read your own file, even during the day');
select tests.logout();

-- anon and cleanup
select set_config('role', 'anon', true);
select throws_ok($$ select public.tonight() $$, '42501', null, 'anon can''t call RPCs');
select tests.logout();
select tests.login_as(tests.id('alice'));
select throws_ok($$ select public.cleanup_pending_paths() $$, '42501', null, 'users can''t call cleanup functions');
select throws_ok($$ select public.push_targets_opening() $$, '42501', null, 'or push functions');
select tests.logout();

-- Orphan files
select set_config('tests.orphan', tests.put_object(tests.id('bob')), false);
update storage.objects set created_at = now() - interval '25 hours' where name = current_setting('tests.orphan');
select private.queue_orphan_files();
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.orphan')),
  'files uploaded a day ago that never became a page are queued for deletion');

-- Export is everything you wrote.
select tests.page_on(tests.id('alice'), private.user_today(tests.id('alice')) - 400);
select tests.login_as(tests.id('alice'));
select is(jsonb_array_length(public.export_entries()), 2, 'export includes pages older than 30 days');
select public.delete_account();
select tests.logout();

select ok(
  not exists (select 1 from auth.users where id = tests.id('alice'))
  and not exists (select 1 from public.entries where user_id = tests.id('alice'))
  and not exists (select 1 from public.friendships where tests.id('alice') in (user_a, user_b)),
  'deleting an account removes its pages and friendships');
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.a_path')),
  'and queues its photos for deletion');

select * from finish();
rollback;
