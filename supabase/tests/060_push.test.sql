-- Push targets: recipients of a letter, friend requests, and the nightly opening push.
begin;
select plan(9);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol', false));
select tests.remember('dave', tests.create_user('dave'));
select tests.befriend(tests.id('alice'), tests.id('bob'));
select tests.befriend(tests.id('alice'), tests.id('carol'));
select tests.befriend(tests.id('alice'), tests.id('dave'));
insert into public.devices (token, user_id) values
  ('alice-phone', tests.id('alice')), ('bob-phone', tests.id('bob')), ('bob-ipad', tests.id('bob')),
  ('carol-phone', tests.id('carol')), ('dave-phone', tests.id('dave'));
select tests.login_as(tests.id('dave'));
select public.block_user(tests.id('alice'));
select tests.logout();

select tests.remember('a1', tests.write(tests.id('alice'), array[tests.id('bob'), tests.id('carol'), tests.id('dave')]));
select is(array(select token from public.push_targets_letter(tests.id('a1'), array[tests.id('bob'), tests.id('carol'), tests.id('dave')]) order by token),
  array['bob-ipad', 'bob-phone'],
  'a letter notifies its recipients on every device — not someone whose day hasn''t started, not across a block');
select is((select distinct writer_name from public.push_targets_letter(tests.id('a1'), array[tests.id('bob')])), 'alice',
  'with the writer''s name');
select tests.remember('frank', tests.create_user('frank'));
select tests.befriend(tests.id('alice'), tests.id('frank'));
insert into public.devices (token, user_id) values ('frank-phone', tests.id('frank'));
select tests.login_as(tests.id('alice'));
select public.add_recipients(tests.id('a1'), array[tests.id('frank')]);
select tests.logout();
select is(array(select token from public.push_targets_letter(tests.id('a1'), array[tests.id('frank')])), array['frank-phone'],
  'adding a recipient later notifies only them');

-- Friend requests
select tests.remember('erin', tests.create_user('erin'));
select set_config('tests.alice_username', (select username from public.profiles where id = tests.id('alice')), false);
select tests.login_as(tests.id('erin'));
select public.add_friend(current_setting('tests.alice_username'));
select tests.logout();
select is(array(select token || ' / ' || requester_name from public.push_targets_request(tests.id('erin'), tests.id('alice'))),
  array['alice-phone / erin'], 'a friend request notifies the person asked');

-- Opening push: only in the first two hours of the window, once per night.
update public.profiles set time_zone = tests.tz_for_hour(20) where id in (tests.id('bob'), tests.id('carol'));
update public.profiles set time_zone = tests.tz_for_hour(1) where id = tests.id('alice');
select is(array(select token from public.push_targets_opening() order by token), array['bob-ipad', 'bob-phone', 'carol-phone'],
  'everyone whose diary just opened (20:00–22:00), not someone deep into the night');
select is(array(select token from public.push_targets_opening()), '{}'::text[], 'only once per night');

delete from private.window_pushes;
-- Carol's day now matches the night Alice wrote to her (22:00 and 20:00 zones share a date); Dave isn't her friend.
select tests.page_on(tests.id('dave'), private.user_today(tests.id('carol')), array[tests.id('carol')]);
select is((select writers from public.push_targets_opening() where token = 'carol-phone'), array['alice'],
  'it names friends who already wrote to you tonight');

select tests.login_as(tests.id('alice'));
select throws_ok($$ select public.push_targets_letter(gen_random_uuid(), '{}') $$, '42501', null, 'users can''t call push functions');
select tests.logout();

select public.remove_device_tokens(array['bob-ipad']);
select ok(not exists (select 1 from public.devices where token = 'bob-ipad'), 'invalid tokens are removed');

select * from finish();
rollback;
