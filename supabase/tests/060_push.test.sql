-- Push targets: friend requests and the nightly opening push (letters arrive at 20:00, so that's the only letter push).
begin;
select plan(8);

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

-- Sending a page notifies nobody: nothing can be read until 20:00 the next evening.
select hasnt_trigger('public', 'entry_recipients', 'entry_recipients_after_insert', 'sending a page sends no push');

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
-- Letters that arrive tonight were written last night: Alice's counts, Dave's doesn't (not Carol's friend),
-- and one written tonight isn't delivered yet.
select tests.page_on(tests.id('alice'), private.user_today(tests.id('carol')) - 1, array[tests.id('carol')]);
select tests.page_on(tests.id('dave'), private.user_today(tests.id('carol')) - 1, array[tests.id('carol')]);
select is((select writers from public.push_targets_opening() where token = 'carol-phone'), array['alice'],
  'it names friends who wrote to you last night');

delete from private.window_pushes;
delete from public.entries where user_id = tests.id('alice');
select tests.page_on(tests.id('alice'), private.user_today(tests.id('carol')), array[tests.id('carol')]);
select is((select writers from public.push_targets_opening() where token = 'carol-phone'), '{}'::text[],
  'not a page written tonight: it arrives tomorrow');

select tests.login_as(tests.id('alice'));
select throws_ok($$ select public.push_targets_request(gen_random_uuid(), gen_random_uuid()) $$, '42501', null, 'users can''t call push functions');
select tests.logout();

select public.remove_device_tokens(array['bob-ipad']);
select ok(not exists (select 1 from public.devices where token = 'bob-ipad'), 'invalid tokens are removed');

select * from finish();
rollback;
