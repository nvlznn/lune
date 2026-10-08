-- Usernames and friends: choosing a username, finding people, requests, accepting, limits, removing.
begin;
select plan(26);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('guesser', tests.create_user('guesser'));

-- Usernames follow Instagram's rules.
select tests.login_as(tests.id('alice'));
select is((public.set_username('  @Alice.Lune ')).username, 'alice.lune', 'stored lowercase, without @ or spaces');
select throws_ok($$ select public.set_username('.alice') $$, 'P0001', 'invalid_username', 'can''t start with a period');
select throws_ok($$ select public.set_username('alice.') $$, 'P0001', 'invalid_username', 'can''t end with a period');
select throws_ok($$ select public.set_username('al..ice') $$, 'P0001', 'invalid_username', 'no two periods in a row');
select throws_ok($$ select public.set_username('alice-lune') $$, 'P0001', 'invalid_username', 'only letters, numbers, periods and underscores');
select throws_ok($$ select public.set_username(repeat('a', 31)) $$, 'P0001', 'invalid_username', 'at most 30 characters');
select throws_ok($$ select public.set_username('admin') $$, 'P0001', 'username_taken', 'reserved names can''t be taken');
select ok(public.username_available('alice.lune'), 'your own username counts as available to you');
select tests.logout();

select tests.login_as(tests.id('bob'));
select ok(not public.username_available('Alice.Lune'), 'taken usernames aren''t available, whatever the case');
select throws_ok($$ select public.set_username('ALICE.LUNE') $$, 'P0001', 'username_taken', 'usernames are unique regardless of case');
select public.set_username('bob_b');
select tests.logout();

-- Finding and adding
select tests.login_as(tests.id('alice'));
select is(public.find_user('@BOB_B') ->> 'name', 'bob', 'find someone by exact username');
select is(public.find_user('bob_b') ->> 'relationship', 'none', 'not friends yet');
select is(public.find_user('bob'), null, 'partial names don''t match');
select is(public.add_friend('bob_b') ->> 'status', 'requested', 'adding sends a request');
select is(public.find_user('bob_b') ->> 'relationship', 'requested', 'and shows as requested');
select throws_ok($$ select public.add_friend('alice.lune') $$, 'P0001', 'own_username', 'not yourself');
select tests.logout();

select tests.login_as(tests.id('bob'));
select is(public.friend_requests() -> 0 ->> 'username', 'alice.lune', 'Bob sees the request, with the username');
select public.respond_friend_request(tests.id('alice'), true);
select is(public.friends() -> 0 ->> 'name', 'alice', 'accepting makes you friends');
select is(jsonb_array_length(public.friend_requests()), 0, 'and clears the request');
select tests.logout();

select tests.login_as(tests.id('alice'));
select is(public.add_friend('bob_b') ->> 'status', 'already_friends', 'already friends');
select tests.logout();

-- Both sides asking: instant friends.
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('dave', tests.create_user('dave'));
select set_config('tests.carol_username', (select username from public.profiles where id = tests.id('carol')), false);
select set_config('tests.dave_username', (select username from public.profiles where id = tests.id('dave')), false);
select tests.login_as(tests.id('carol'));
select public.add_friend(current_setting('tests.dave_username'));
select tests.logout();
select tests.login_as(tests.id('dave'));
select is(public.add_friend(current_setting('tests.carol_username')) ->> 'status', 'friends',
  'if they already asked you, adding them makes you friends');
select tests.logout();

-- Declining and removing
select tests.login_as(tests.id('guesser'));
select public.add_friend('alice.lune');
select tests.logout();
select tests.login_as(tests.id('alice'));
select public.respond_friend_request(tests.id('guesser'), false);
select ok(not private.are_friends(tests.id('alice'), tests.id('guesser')), 'declining doesn''t make friends');
select public.remove_friend(tests.id('bob'));
select ok(not private.are_friends(tests.id('alice'), tests.id('bob')), 'removing a friend');
select tests.logout();

-- Unknown usernames are rate limited.
select tests.login_as(tests.id('guesser'));
select is(public.add_friend('nobody_here') ->> 'status', 'not_found', 'unknown username');
select public.find_user('nobody_here') from generate_series(1, 29);
select throws_ok($$ select public.find_user('nobody_here') $$, 'P0001', 'too_many_attempts', '30 misses in an hour → pause');
select tests.logout();

-- 1,000 friends at most.
insert into auth.users (id, aud, role, email)
select gen_random_uuid(), 'authenticated', 'authenticated', 'many-' || i || '@test.local' from generate_series(1, 1000) as i;
insert into public.profiles (id, display_name, username)
select u.id, 'friend', 'many_' || split_part(split_part(u.email, '-', 2), '@', 1)
from auth.users u where u.email like 'many-%@test.local';
insert into public.friendships (user_a, user_b)
select least(tests.id('carol'), p.id), greatest(tests.id('carol'), p.id)
from public.profiles p where p.display_name = 'friend' limit 999;
-- Carol now has Dave + 999 = 1,000.
select tests.login_as(tests.id('carol'));
select throws_ok($$ select public.add_friend('alice.lune') $$, 'P0001', 'too_many_friends', 'no more than 1,000 friends');
select tests.logout();

select * from finish();
rollback;
