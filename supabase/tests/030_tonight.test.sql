-- Tonight (exchange diary): last night's letters arrive at 20:00 and can be read while the diary is open
-- (until 05:00), without writing first; pages written tonight arrive tomorrow; one night only.
begin;
select plan(20);

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

-- What everyone wrote last night (this is what arrives now).
select tests.remember('b_page', tests.page_on(tests.id('bob'), private.user_today(tests.id('bob')) - 1, array[tests.id('alice'), tests.id('carol')]));
select tests.remember('c_page', tests.page_on(tests.id('carol'), private.user_today(tests.id('carol')) - 1, array[tests.id('alice')]));
-- Everything in one transaction shares now(); spread the letters out in time.
update public.entry_recipients set sent_at = now() + interval '1 minute' where entry_id = tests.id('c_page');
select tests.remember('d_page', tests.page_on(tests.id('dave'), private.user_today(tests.id('dave')) - 1, '{}'));
select tests.remember('e_page', tests.page_on(tests.id('erin'), private.user_today(tests.id('erin')) - 1, array[tests.id('bob')]));
select tests.page_on(tests.id('stranger'), private.user_today(tests.id('stranger')) - 1, array[tests.id('alice')]);

-- Alice hasn't written tonight, and doesn't need to.
select is(tests.tonight(tests.id('alice')) ->> 'open', 'true', 'open at night');
select is(tests.letters(tests.id('alice')), array[tests.id('c_page'), tests.id('b_page')],
  'last night''s letters are there without writing first, newest first (not friends who kept it to themselves, not strangers)');
select ok(not (tests.tonight(tests.id('alice')) ? 'locked'), 'there are no locked letters');
select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from public.entries where user_id = tests.id('bob')), 1, 'the row is readable too');
select tests.logout();

-- A page a friend writes tonight isn't a letter yet: it arrives tomorrow at 20:00.
select tests.write(tests.id('bob'), array[tests.id('alice')], 'Bob tonight');
select is(tests.letters(tests.id('alice')), array[tests.id('c_page'), tests.id('b_page')], 'a page written tonight isn''t delivered until tomorrow');

select tests.remember('a_page', tests.write(tests.id('alice'), '{}', 'Alice tonight'));
select is(tests.tonight(tests.id('alice')) -> 'mine' ->> 'entry_id', tests.id('a_page')::text, 'your own page is there');
select is(tests.tonight(tests.id('alice')) -> 'letters' -> 0 -> 'recipients', 'null'::jsonb, 'recipients don''t see who else got it');

-- Row-level access matches.
select tests.login_as(tests.id('alice'));
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
select is(tests.letters(tests.id('frank')), '{}'::uuid[], 'a new friend doesn''t get pages sent before');

-- Letters last one night: two nights ago they're gone.
select tests.remember('b_old', tests.page_on(tests.id('bob'), private.user_today(tests.id('bob')) - 2, array[tests.id('alice')]));
select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from public.entries where id = tests.id('b_old')), 0, 'letters end with their night');
select tests.logout();

-- During the day the diary is closed and letters can't be read.
select tests.remember('gina', tests.create_user('gina', false));
select tests.remember('hank', tests.create_user('hank', false));
select tests.befriend(tests.id('gina'), tests.id('hank'));
select tests.page_on(tests.id('hank'), private.user_today(tests.id('hank')) - 1, array[tests.id('gina')]);
select is(tests.tonight(tests.id('gina')) ->> 'open', 'false', 'writing is closed during the day');
select is(tests.letters(tests.id('gina')), '{}'::uuid[], 'and letters can''t be read');
select isnt(tests.tonight(tests.id('gina')) ->> 'opens_at', null, 'tells when writing opens');
select is((tests.tonight(tests.id('gina')) ->> 'ends_at')::timestamptz,
  ((private.user_today(tests.id('gina')) + 1) + time '20:00') at time zone private.time_zone_of(tests.id('gina')),
  'and when the next day starts');

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
