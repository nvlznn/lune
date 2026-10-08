-- Tonight: letters sent to you, opened once you've written; one day only; locked cards.
begin;
select plan(23);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('dave', tests.create_user('dave'));
select tests.remember('erin', tests.create_user('erin'));
select tests.remember('stranger', tests.create_user('stranger'));
select tests.befriend(tests.id('alice'), tests.id('bob'));
select tests.befriend(tests.id('alice'), tests.id('carol'));
select tests.befriend(tests.id('alice'), tests.id('dave'));
select tests.befriend(tests.id('bob'), tests.id('carol'));
select tests.befriend(tests.id('bob'), tests.id('erin'));

select tests.remember('b_page', tests.write(tests.id('bob'), array[tests.id('alice'), tests.id('carol')], 'Bob tonight'));
select tests.remember('c_page', tests.write(tests.id('carol'), array[tests.id('alice')], 'Carol tonight'));
-- Everything in one transaction shares now(); spread the letters out in time.
update public.entry_recipients set sent_at = now() + interval '1 minute' where entry_id = tests.id('c_page');
select tests.remember('d_page', tests.write(tests.id('dave'), '{}', 'Dave, just for me'));
select tests.remember('e_page', tests.write(tests.id('erin'), array[tests.id('bob')], 'Erin to Bob'));
select tests.write(tests.id('stranger'), array[tests.id('alice')], 'Not a friend');

-- Alice hasn't written tonight.
select is(tests.tonight(tests.id('alice')) ->> 'open', 'true', 'open at night');
select is(tests.letters(tests.id('alice')), '{}'::uuid[], 'before writing, letters stay locked');
select is(tests.locked(tests.id('alice')), array['carol', 'bob'],
  'but you see who wrote to you, newest first (not friends who kept it to themselves, not strangers)');
select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from public.entries where user_id = tests.id('bob')), 0, 'the row is locked too');
select tests.logout();

-- Writing a page only for yourself still unlocks them.
select tests.remember('a_page', tests.write(tests.id('alice'), '{}', 'Alice tonight'));
select is(tests.letters(tests.id('alice')), array[tests.id('c_page'), tests.id('b_page')], 'after writing, letters open, newest first');
select is(tests.locked(tests.id('alice')), '{}'::text[], 'nothing left locked');
select is(tests.tonight(tests.id('alice')) -> 'mine' ->> 'entry_id', tests.id('a_page')::text, 'your own page is there');
select is(tests.tonight(tests.id('alice')) -> 'letters' -> 0 -> 'recipients', 'null'::jsonb, 'recipients don''t see who else got it');

-- Row-level access matches.
select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from public.entries where user_id = tests.id('bob')), 1, 'the row is readable when unlocked');
select is((select count(*)::integer from public.entries where id = tests.id('d_page')), 0, 'pages friends kept to themselves never are');
select is((select count(*)::integer from public.entries where id = tests.id('e_page')), 0, 'nor pages sent to others');
select is((select count(*)::integer from public.entries where user_id = tests.id('stranger')), 0, 'nor strangers''');
select is((select count(*)::integer from public.entry_recipients where entry_id = tests.id('b_page')), 0,
  'recipient lists are for the writer only');
select tests.logout();
select tests.login_as(tests.id('bob'));
select is((select count(*)::integer from public.entry_recipients where entry_id = tests.id('b_page')), 2, 'the writer can read them');
select tests.logout();

-- Friends made after sending don't get it.
select tests.remember('frank', tests.create_user('frank'));
select tests.befriend(tests.id('bob'), tests.id('frank'));
select tests.write(tests.id('frank'));
select is(tests.letters(tests.id('frank')), '{}'::uuid[], 'a new friend doesn''t get pages sent before');

-- Yesterday's letters are gone.
select tests.remember('b_old', tests.page_on(tests.id('bob'), private.user_today(tests.id('bob')) - 1, array[tests.id('alice')]));
select tests.page_on(tests.id('alice'), private.user_today(tests.id('alice')) - 1);
select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from public.entries where id = tests.id('b_old')), 0, 'letters end with their day');
select tests.logout();

-- After writing closes, today's letters stay readable until 20:00.
select tests.remember('gina', tests.create_user('gina', false));
select tests.remember('hank', tests.create_user('hank', false));
select tests.befriend(tests.id('gina'), tests.id('hank'));
select tests.remember('h_page', tests.page_on(tests.id('hank'), private.user_today(tests.id('hank')), array[tests.id('gina')]));
select is(tests.locked(tests.id('gina')), array['hank'], 'a day you didn''t write stays locked');
select tests.page_on(tests.id('gina'), private.user_today(tests.id('gina')));
select is(tests.tonight(tests.id('gina')) ->> 'open', 'false', 'writing is closed during the day');
select is(tests.letters(tests.id('gina')), array[tests.id('h_page')], 'but letters can still be read');
select isnt(tests.tonight(tests.id('gina')) ->> 'opens_at', null, 'tells when writing opens');
select is((tests.tonight(tests.id('gina')) ->> 'ends_at')::timestamptz,
  ((private.user_today(tests.id('gina')) + 1) + time '20:00') at time zone private.time_zone_of(tests.id('gina')),
  'and when today''s letters end');

-- Unfriending and blocking take letters away.
select tests.login_as(tests.id('bob'));
select public.remove_friend(tests.id('alice'));
select tests.logout();
select ok(not (tests.id('b_page') = any (tests.letters(tests.id('alice')))), 'unfriending removes the letter');
select tests.login_as(tests.id('carol'));
select public.block_user(tests.id('alice'));
select tests.logout();
select is(tests.letters(tests.id('alice')), '{}'::uuid[], 'so does a block');

select * from finish();
rollback;
