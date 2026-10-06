-- Push device registration.
begin;
select plan(4);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));

select tests.login_as(tests.id('alice'));
select public.register_device('token-1');
select tests.logout();
select is((select user_id from public.devices where token = 'token-1'), tests.id('alice'), 'register_device stores the token');

-- The same device signs in as someone else.
select tests.login_as(tests.id('bob'));
select public.register_device('token-1');
select tests.logout();
select is((select user_id from public.devices where token = 'token-1'), tests.id('bob'), 'a token moves to the account that registered it last');

select tests.login_as(tests.id('alice'));
select public.unregister_device('token-1');
select tests.logout();
select ok(exists (select 1 from public.devices where token = 'token-1'), 'cannot unregister someone else''s token');

select tests.login_as(tests.id('bob'));
select public.unregister_device('token-1');
select tests.logout();
select ok(not exists (select 1 from public.devices where token = 'token-1'), 'unregister_device removes your own token');

select * from finish();
rollback;
