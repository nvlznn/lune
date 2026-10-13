-- The App Review account: always open, with friends whose letters are always dated yesterday (so they're always delivered).
begin;
select plan(12);

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
select is(cardinality(tests.letters(tests.id('reviewer'))), 2, 'its friends'' letters are waiting, readable at any hour');
select is((select username from public.profiles where id = tests.id('reviewer')), 'lune.review', 'the profile is set up');
select is((select array_agg(distinct day) from public.entries where user_id in (tests.id('mia'), tests.id('leo'))),
  array[private.user_today(tests.id('reviewer')) - 1], 'the letters are dated yesterday, as if written last night');

select tests.remember('r_page', tests.write(tests.id('reviewer')));
select is(tests.tonight(tests.id('reviewer')) -> 'mine' ->> 'entry_id', tests.id('r_page')::text, 'and it can write at any hour');

-- A new day: the letters move to the new "yesterday".
update public.entries set day = day - 1 where user_id in (tests.id('mia'), tests.id('leo'));
select is(cardinality(tests.letters(tests.id('reviewer'))), 0,
  'last night''s letters are gone once the day moves on');
select private.refresh_review_letters();
select is(cardinality(tests.letters(tests.id('reviewer'))), 2, 'the refresh brings them back');

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
