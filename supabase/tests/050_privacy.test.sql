-- 讀取權限、封鎖、7 天清除、刪除帳號。
begin;
select plan(22);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('g', tests.create_group(tests.id('alice'), 'Noky'));
select tests.join(tests.id('bob'), tests.id('g'));
update public.group_members set joined_at = now() + interval '1 minute'
where group_id = tests.id('g') and user_id = tests.id('bob');

select tests.remember('a1', tests.upload(tests.id('alice'), tests.id('g'), '2026-10-06 21:14:00'));
select set_config('tests.a_path', (select storage_path from public.photos where id = tests.id('a1')), false);

-- 還沒配給：bob 讀不到
select tests.login_as(tests.id('bob'));
select is((select count(*)::integer from public.photos where id = tests.id('a1')), 0, '還沒配給的照片讀不到（資料列）');
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 0,
  '還沒配給的照片讀不到（檔案）');
select tests.logout();

select tests.upload(tests.id('bob'), tests.id('g'));
select tests.claim(tests.id('bob'), tests.id('g'));

select tests.login_as(tests.id('bob'));
select is((select count(*)::integer from public.photos where id = tests.id('a1')), 1, '配給之後讀得到（資料列）');
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 1,
  '配給之後讀得到（檔案）');
select is(public.group_state(tests.id('g')) -> 'received' -> 0 ->> 'taken_at', '2026-10-06T21:14:00',
  'group_state 帶出拍攝時間');
select tests.logout();

select tests.login_as(tests.id('alice'));
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 1,
  '照片主人讀得到自己的檔案');
select tests.logout();

-- 非成員
select tests.login_as(tests.id('carol'));
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 0,
  '直接猜檔案路徑 → 讀不到');
select is((select count(*)::integer from public.groups where id = tests.id('g')), 0, '非成員看不到群組');
select is((select count(*)::integer from public.group_members where group_id = tests.id('g')), 0, '非成員看不到成員');
select is((select count(*)::integer from public.profiles where id = tests.id('alice')), 0, '看不到沒有共同群組的人');
select tests.logout();

-- anon 什麼都不能做
select set_config('role', 'anon', true);
select throws_ok($$ select public.my_groups() $$, '42501', null, 'anon 不能呼叫 RPC');
select tests.logout();

-- 清除用的函式只給 service_role
select tests.login_as(tests.id('alice'));
select throws_ok($$ select public.cleanup_pending_paths() $$, '42501', null, '一般使用者不能呼叫清除函式');
select tests.logout();

-- 封鎖：已收到的照片隱藏、檔案讀不到
select tests.login_as(tests.id('alice'));
select public.block_user(tests.id('bob'));
select tests.logout();
select tests.login_as(tests.id('bob'));
select is(jsonb_array_length(public.group_state(tests.id('g')) -> 'received'), 0, '被封鎖後，已收到的照片從清單隱藏');
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 0,
  '被封鎖後讀不到對方的檔案');
select is((public.group_state(tests.id('g')) ->> 'credits')::integer, 0, '封鎖不退回資格');
select tests.logout();
delete from public.blocks;

-- 7 天清除
select tests.backdate(tests.id('a1'), interval '7 days 1 minute');
select private.expire_old_photos();
select isnt((select expired_at from public.photos where id = tests.id('a1')), null, '超過 7 天 → 標記過期');
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.a_path')),
  '過期照片的檔案排入刪除佇列');
select tests.login_as(tests.id('bob'));
select is((select count(*)::integer from storage.objects where name = current_setting('tests.a_path')), 0,
  '過期照片讀不到');
select is((public.group_state(tests.id('g')) ->> 'credits')::integer, 0, '照片過期不影響資格');
select tests.logout();

-- 孤兒檔
select set_config('tests.orphan', tests.put_object(tests.id('bob'), tests.id('g')), false);
update storage.objects set created_at = now() - interval '25 hours' where name = current_setting('tests.orphan');
select private.expire_old_photos();
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.orphan')),
  '上傳超過一天卻沒登記的檔案排入刪除佇列');

-- 刪除帳號
select tests.remember('a2', tests.upload(tests.id('alice'), tests.id('g')));
select set_config('tests.a2_path', (select storage_path from public.photos where id = tests.id('a2')), false);
select tests.login_as(tests.id('alice'));
select public.delete_account();
select tests.logout();
select ok(
  not exists (select 1 from auth.users where id = tests.id('alice'))
  and not exists (select 1 from public.profiles where id = tests.id('alice'))
  and not exists (select 1 from public.photos where user_id = tests.id('alice'))
  and not exists (select 1 from public.group_members where user_id = tests.id('alice')),
  '刪除帳號後資料全部消失');
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.a2_path')),
  '刪除帳號後檔案排入刪除佇列');

select * from finish();
rollback;
