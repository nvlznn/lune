-- Push: only notify members who are waiting, at most once per group per day, never the uploader.
begin;
select plan(10);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('dave', tests.create_user('dave'));
select tests.remember('g', tests.create_group(tests.id('alice'), 'push'));
select tests.join(tests.id('bob'), tests.id('g'));
select tests.join(tests.id('carol'), tests.id('g'));
select tests.join(tests.id('dave'), tests.id('g'));
insert into public.devices (token, user_id) values
  ('alice-phone', tests.id('alice')), ('bob-phone', tests.id('bob')),
  ('carol-phone', tests.id('carol')), ('dave-phone', tests.id('dave'));

-- Alice uploads first and claims: the pool is empty, so she's waiting.
select tests.remember('a1', tests.upload(tests.id('alice'), tests.id('g')));
-- Everything in this transaction shares now(), so spread the uploads out in time.
update public.photos set created_at = now() - interval '40 minutes' where id = tests.id('a1');
select tests.claim(tests.id('alice'), tests.id('g'));
select is((select count(*)::integer from public.push_targets(tests.id('a1'))), 0,
  'the uploader is never notified, and nobody else is waiting yet');

-- Bob uploads: Alice was waiting → notified. Carol and Dave have no credits → not notified.
select tests.remember('b1', tests.upload(tests.id('bob'), tests.id('g')));
update public.photos set created_at = now() - interval '30 minutes' where id = tests.id('b1');
select is(array(select token from public.push_targets(tests.id('b1'))), array['alice-phone'],
  'only the member who was waiting is notified');

-- Alice hasn't opened the app, so she's still waiting; a second upload today doesn't notify her again.
select tests.remember('c1', tests.upload(tests.id('carol'), tests.id('g')));
update public.photos set created_at = now() - interval '20 minutes' where id = tests.id('c1');
select ok(not exists (select 1 from public.push_targets(tests.id('c1')) where token = 'alice-phone'),
  'at most one notification per member per group per day');

-- Carol has a credit, but Alice's and Bob's photos are in her pool: she isn't waiting.
select ok(not exists (select 1 from public.push_targets(tests.id('c1')) where token = 'carol-phone'),
  'a member with claimable photos is not notified');

-- Dave uploads. Alice was already notified today; Bob and Carol still have photos to claim.
select tests.remember('d1', tests.upload(tests.id('dave'), tests.id('g')));
select is(array(select token from public.push_targets(tests.id('d1'))), array[]::text[],
  'nobody is notified when no one is newly waiting');

-- Erin is waiting in another group, and has blocked Frank.
select tests.remember('erin', tests.create_user('erin'));
select tests.remember('frank', tests.create_user('frank'));
select tests.remember('h', tests.create_group(tests.id('erin'), 'blocked'));
select tests.join(tests.id('frank'), tests.id('h'));
insert into public.devices (token, user_id) values ('erin-phone', tests.id('erin'));
select tests.remember('e1', tests.upload(tests.id('erin'), tests.id('h')));
update public.photos set created_at = now() - interval '10 minutes' where id = tests.id('e1');
select tests.claim(tests.id('erin'), tests.id('h'));
select tests.login_as(tests.id('erin'));
select public.block_user(tests.id('frank'));
select tests.logout();
select tests.remember('f1', tests.upload(tests.id('frank'), tests.id('h')));
select is((select count(*)::integer from public.push_targets(tests.id('f1'))), 0,
  'no notification for a photo from someone blocked');

-- The notify call is asynchronous: by the time it runs, others may have uploaded or claimed.
select tests.remember('gina', tests.create_user('gina'));
select tests.remember('hal', tests.create_user('hal'));
select tests.remember('k', tests.create_group(tests.id('gina'), 'late'));
select tests.join(tests.id('hal'), tests.id('k'));
insert into public.devices (token, user_id) values ('gina-phone', tests.id('gina')), ('hal-phone', tests.id('hal'));
select tests.remember('g1', tests.upload(tests.id('gina'), tests.id('k')));
update public.photos set created_at = now() - interval '1 minute' where id = tests.id('g1');
select tests.upload(tests.id('hal'), tests.id('k'));
select ok(not exists (select 1 from public.push_targets(tests.id('g1')) where token = 'hal-phone'),
  'someone who uploaded after the photo arrived is not notified about it');
select tests.claim(tests.id('gina'), tests.id('k'));
select tests.remember('k_hal', (select id from public.photos where group_id = tests.id('k') and user_id = tests.id('hal')));
select ok(not exists (select 1 from public.push_targets(tests.id('k_hal')) where token = 'gina-phone'),
  'someone who already received the photo is not notified about it');

-- Invalid tokens are removed.
select public.remove_device_tokens(array['bob-phone']);
select ok(not exists (select 1 from public.devices where token = 'bob-phone'), 'invalid tokens are removed');

select tests.login_as(tests.id('alice'));
select throws_ok($$ select public.push_targets(gen_random_uuid()) $$, '42501', null, 'users cannot call push_targets');
select tests.logout();

select * from finish();
rollback;
