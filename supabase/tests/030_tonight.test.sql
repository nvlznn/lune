-- Tonight: send, then see; friends' pages only today and yesterday; views; closed state.
begin;
select plan(18);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('stranger', tests.create_user('stranger'));
select tests.befriend(tests.id('alice'), tests.id('bob'));
select tests.befriend(tests.id('alice'), tests.id('carol'));

select tests.remember('b_today', tests.write(tests.id('bob'), 0, 'Bob tonight'));
select tests.remember('c_today', tests.write(tests.id('carol'), 0, 'Carol tonight'));
-- Everything in one transaction shares now(); spread the pages out in time.
update public.entries set created_at = now() + interval '1 minute' where id = tests.id('c_today');
select tests.write(tests.id('stranger'), 0, 'Not a friend');

-- Alice hasn't written tonight.
select is(tests.tonight(tests.id('alice')) ->> 'open', 'true', 'open at night');
select is(tests.friend_pages(tests.id('alice')), '{}'::uuid[], 'before writing, friends'' pages stay locked');
select is(tests.tonight(tests.id('alice')) -> 'days' -> 0 -> 'writers', '["bob", "carol"]'::jsonb,
  'but you see which friends wrote (not strangers), earliest first');
select is((select count(*)::integer from public.entry_views where viewer_id = tests.id('alice')), 0, 'locked pages aren''t seen');

select tests.remember('a_today', tests.write(tests.id('alice'), 0, 'Alice tonight'));
select is(tests.friend_pages(tests.id('alice')), array[tests.id('c_today'), tests.id('b_today')],
  'after writing, friends'' pages unlock, newest first');
select is(tests.tonight(tests.id('alice')) -> 'days' -> 0 -> 'mine' ->> 'entry_id', tests.id('a_today')::text, 'your own page is there');
select is((select count(*)::integer from public.entry_views where viewer_id = tests.id('alice')), 2, 'opening records views');
select is(tests.tonight(tests.id('bob')) -> 'days' -> 0 -> 'mine' -> 'seen_by' -> 0 ->> 'name', 'alice', 'the writer sees who saw it');

-- Row-level access matches.
select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from public.entries where user_id = tests.id('bob')), 1, 'the row is readable when unlocked');
select is((select count(*)::integer from public.entries where user_id = tests.id('stranger')), 0, 'strangers'' pages never are');
select tests.logout();

-- Yesterday: backfill unlocks it.
select tests.remember('b_yday', tests.page_on(tests.id('bob'), private.user_today(tests.id('bob')) - 1));
select is(tests.friend_pages(tests.id('alice'), 1), '{}'::uuid[], 'yesterday stays locked while you haven''t written it');
select tests.write(tests.id('alice'), 1, 'Alice, late');
select is(tests.friend_pages(tests.id('alice'), 1), array[tests.id('b_yday')], 'writing yesterday unlocks friends'' yesterday');

-- Two days ago: gone, even if you wrote then.
select tests.remember('b_old', tests.page_on(tests.id('bob'), private.user_today(tests.id('bob')) - 2));
select tests.page_on(tests.id('alice'), private.user_today(tests.id('alice')) - 2);
select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from public.entries where id = tests.id('b_old')), 0, 'friends'' pages fade after yesterday');
select tests.logout();

-- Closed: no friends' pages, but who wrote and when it opens.
select tests.set_open(tests.id('alice'), false);
select is(tests.tonight(tests.id('alice')) ->> 'open', 'false', 'closed during the day');
select is(jsonb_array_length(tests.tonight(tests.id('alice')) -> 'days' -> 0 -> 'friends'), 0, 'no friends'' pages while closed');
select isnt(tests.tonight(tests.id('alice')) ->> 'opens_at', null, 'tells when it opens');
select ok(tests.tonight(tests.id('alice')) -> 'days' -> 0 -> 'mine' is not null, 'your own pages stay visible');
select tests.set_open(tests.id('alice'), true);

-- Blocking
select tests.login_as(tests.id('carol'));
select public.block_user(tests.id('alice'));
select tests.logout();
select ok(not (tests.id('c_today') = any (tests.friend_pages(tests.id('alice')))), 'a block removes the friendship and the pages');

select * from finish();
rollback;
