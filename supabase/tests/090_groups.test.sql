-- Groups: private lists of friends.
begin;
select plan(12);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('stranger', tests.create_user('stranger'));
select tests.befriend(tests.id('alice'), tests.id('bob'));
select tests.befriend(tests.id('alice'), tests.id('carol'));

select tests.login_as(tests.id('alice'));
select tests.remember('close', (public.save_group(null, '  Close   friends ', array[tests.id('bob'), tests.id('stranger')]) ->> 'id')::uuid);
select is(public.groups() -> 0 ->> 'name', 'Close friends', 'a group is created with a tidied name');
select is(public.groups() -> 0 -> 'member_ids', jsonb_build_array(tests.id('bob')), 'only friends become members');
select is(
  public.save_group(tests.id('close'), 'Closest', array[tests.id('carol')]) -> 'member_ids',
  jsonb_build_array(tests.id('carol')), 'saving again renames it and replaces the members');
select throws_ok($$ select public.save_group(null, '   ', '{}') $$, 'P0001', 'invalid_group_name', 'a name is required');
select throws_ok($$ select public.save_group(null, repeat('a', 31), '{}') $$, 'P0001', 'invalid_group_name', 'at most 30 characters');
select tests.logout();

-- Nobody else sees them.
select tests.login_as(tests.id('bob'));
select is(public.groups(), '[]'::jsonb, 'other people have their own groups');
select is((select count(*)::integer from public.friend_groups), 0, 'and can''t read yours');
select throws_ok($$ select public.save_group(tests.id('close'), 'Mine now', '{}') $$, 'P0001', 'group_not_found', 'or change them');
select throws_ok($$ select public.delete_group(tests.id('close')) $$, 'P0001', 'group_not_found', 'or delete them');
select tests.logout();

-- Ending a friendship removes them from your groups.
select tests.login_as(tests.id('carol'));
select public.remove_friend(tests.id('alice'));
select tests.logout();
select is((select count(*)::integer from public.friend_group_members where group_id = tests.id('close')), 0,
  'an ex-friend leaves your groups');

-- Limits and deleting
insert into public.friend_groups (owner_id, name) select tests.id('alice'), 'Group ' || n from generate_series(1, 99) n;
select tests.login_as(tests.id('alice'));
select throws_ok($$ select public.save_group(null, 'One too many', '{}') $$, 'P0001', 'too_many_groups', 'up to 100 groups');
select public.delete_group(tests.id('close'));
select ok(not exists (select 1 from public.friend_groups where id = tests.id('close')), 'a group can be deleted');
select tests.logout();

select * from finish();
rollback;
