-- The App Review account: always open, with friends whose letters follow its day.
begin;
select plan(11);

-- The reviewer lives where it's midday: closed for everyone else.
select tests.remember('reviewer', tests.create_user('reviewer', false));
select tests.remember('mia', tests.create_user('mia'));
select tests.remember('leo', tests.create_user('leo'));
select tests.remember('someone', tests.create_user('someone', false));

select public.setup_review_account(tests.id('reviewer'), 'App Review', 'lune.review', jsonb_build_array(
  jsonb_build_object('user_id', tests.id('mia'), 'name', 'Mia', 'username', 'mia.review', 'avatar_path', null,
                     'storage_path', tests.put_object(tests.id('mia')), 'text', 'Mia''s day.'),
  jsonb_build_object('user_id', tests.id('leo'), 'name', 'Leo', 'username', 'leo.review', 'avatar_path', null,
                     'storage_path', tests.put_object(tests.id('leo')), 'text', 'Leo''s day.')
));

select is(tests.tonight(tests.id('reviewer')) ->> 'open', 'true', 'the review account is open at midday');
select is(tests.tonight(tests.id('reviewer')) ->> 'closes_at', null, 'and never closes');
select is(tests.tonight(tests.id('someone')) ->> 'open', 'false', 'everyone else is still closed');
select is(
  array(select x from unnest(tests.locked(tests.id('reviewer'))) x order by x), array['Leo', 'Mia'],
  'its friends'' letters are waiting, locked');
select is((select username from public.profiles where id = tests.id('reviewer')), 'lune.review', 'the profile is set up');

select tests.remember('r_page', tests.write(tests.id('reviewer')));
select is(cardinality(tests.letters(tests.id('reviewer'))), 2, 'writing at any hour opens them');

-- A new day: the letters move to it.
update public.entries set day = day - 1 where user_id in (tests.id('mia'), tests.id('leo'));
select is(cardinality(tests.letters(tests.id('reviewer'))) + cardinality(tests.locked(tests.id('reviewer'))), 0,
  'yesterday''s letters are gone');
select private.refresh_review_letters();
select is(cardinality(tests.letters(tests.id('reviewer'))), 2, 'the refresh brings them to today');

-- Running setup again replaces the letters instead of adding more.
select set_config('tests.old_path', (select storage_path from public.entries where user_id = tests.id('mia')), false);
select public.setup_review_account(tests.id('reviewer'), 'App Review', 'lune.review', jsonb_build_array(
  jsonb_build_object('user_id', tests.id('mia'), 'name', 'Mia', 'username', 'mia.review', 'avatar_path', null,
                     'storage_path', tests.put_object(tests.id('mia')), 'text', 'Mia again.')
));
select is((select count(*)::integer from public.entries where user_id = tests.id('mia')), 1, 'setup can run again');
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.old_path')),
  'and the replaced photo is deleted');

select tests.login_as(tests.id('someone'));
select throws_ok($$ select public.setup_review_account(tests.id('someone'), 'x', 'x', '[]') $$, '42501', null,
  'users can''t make themselves review accounts');
select tests.logout();

select * from finish();
rollback;
