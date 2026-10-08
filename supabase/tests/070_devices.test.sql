-- Push device registration and time zones.
begin;
select plan(6);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));

select tests.login_as(tests.id('alice'));
select public.register_device('token-1');
select tests.logout();
select is((select user_id from public.devices where token = 'token-1'), tests.id('alice'), 'register_device stores the token');

select tests.login_as(tests.id('bob'));
select public.register_device('token-1');
select tests.logout();
select is((select user_id from public.devices where token = 'token-1'), tests.id('bob'), 'a token moves to the account that registered it last');

select tests.login_as(tests.id('alice'));
select public.unregister_device('token-1');
select tests.logout();
select ok(exists (select 1 from public.devices where token = 'token-1'), 'can''t unregister someone else''s token');

select tests.login_as(tests.id('bob'));
select public.unregister_device('token-1');
select public.set_time_zone('Asia/Taipei');
select throws_ok($$ select public.set_time_zone('Mars/Olympus') $$, 'P0001', 'invalid_time_zone', 'unknown time zones are rejected');
select tests.logout();
select ok(not exists (select 1 from public.devices where token = 'token-1'), 'unregister_device removes your own token');
select is((select time_zone from public.profiles where id = tests.id('bob')), 'Asia/Taipei', 'set_time_zone stores the zone');

select * from finish();
rollback;
