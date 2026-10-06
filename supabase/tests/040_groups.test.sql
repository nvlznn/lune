-- 群組：建立、加入、上限、離開、擁有者轉移。
begin;
select plan(19);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('g', tests.create_group(tests.id('alice'), '  Noky  '));

select matches((select invite_code from public.groups where id = tests.id('g')), '^[A-HJ-NP-Z2-9]{6}$',
  '邀請碼 6 碼、不含 0/O/1/I');
select is((select name from public.groups where id = tests.id('g')), 'Noky', '群組名稱去頭尾空白');
select is((select owner_id from public.groups where id = tests.id('g')), tests.id('alice'), '建立者是擁有者');
select ok(exists (select 1 from public.group_members where group_id = tests.id('g') and user_id = tests.id('alice')),
  '建立者自動成為成員');

-- 加入：小寫、含空白也可以；冪等
select set_config('tests.code', (select invite_code from public.groups where id = tests.id('g')), false);
select tests.login_as(tests.id('bob'));
select is((select id from public.join_group(lower(' ' || current_setting('tests.code') || ' '))), tests.id('g'),
  '邀請碼不分大小寫、忽略空白');
select is((select id from public.join_group(current_setting('tests.code'))), tests.id('g'), '重複加入回傳同一群組');
select tests.logout();
select is((select count(*)::integer from public.group_members where group_id = tests.id('g')), 2, '重複加入不會多一筆');

-- 錯的邀請碼
select tests.remember('guesser', tests.create_user('guesser'));
select tests.login_as(tests.id('guesser'));
select is((select count(*)::integer from public.join_group('ZZZZZZ')), 0, '找不到邀請碼 → 空結果');
select public.join_group('ZZZZZZ') from generate_series(1, 9);
select throws_ok($$ select public.join_group('ZZZZZZ') $$, 'P0001', 'too_many_attempts',
  '一小時內猜錯 10 次 → 暫停');
select tests.logout();

-- 沒有 profile 的帳號
insert into auth.users (id, aud, role, email) values ('00000000-0000-0000-0000-00000000beef', 'authenticated', 'authenticated', 'np@test.local');
select tests.login_as('00000000-0000-0000-0000-00000000beef');
select throws_ok($$ select public.create_group('x') $$, 'P0001', 'profile_required', '還沒設定顯示名稱 → 拒絕');
select tests.logout();

-- 每人最多 10 個群組
select tests.remember('dave', tests.create_user('dave'));
select tests.create_group(tests.id('dave'), 'g' || i) from generate_series(1, 10) as i;
select tests.login_as(tests.id('dave'));
select throws_ok($$ select public.create_group('第 11 個') $$, 'P0001', 'too_many_groups', '建立第 11 個群組 → 拒絕');
select throws_ok($$ select public.join_group(current_setting('tests.code')) $$, 'P0001', 'too_many_groups',
  '加入第 11 個群組 → 拒絕');
select tests.logout();

-- 每群最多 20 人（alice、bob + 18 人）
select tests.join(tests.create_user('m' || i), tests.id('g')) from generate_series(1, 18) as i;
select is((select count(*)::integer from public.group_members where group_id = tests.id('g')), 20, '剛好 20 人');
select tests.remember('late', tests.create_user('late'));
select tests.login_as(tests.id('late'));
select throws_ok($$ select public.join_group(current_setting('tests.code')) $$, 'P0001', 'group_full', '第 21 人 → 拒絕');
select tests.logout();

-- 離開：照片被刪、別人因此退回資格、擁有者轉移
select tests.remember('h', tests.create_group(tests.id('alice'), '離開測試'));
select tests.join(tests.id('bob'), tests.id('h'));
select tests.join(tests.id('carol'), tests.id('h'));
-- 同一個 transaction 裡 now() 相同，手動拉開加入順序。
update public.group_members set joined_at = now() + interval '1 minute'
where group_id = tests.id('h') and user_id = tests.id('carol');
select tests.remember('a_photo', tests.upload(tests.id('alice'), tests.id('h')));
select set_config('tests.a_path', (select storage_path from public.photos where id = tests.id('a_photo')), false);
select tests.upload(tests.id('bob'), tests.id('h'));
select tests.claim(tests.id('bob'), tests.id('h'));

select tests.login_as(tests.id('alice'));
select public.leave_group(tests.id('h'));
select tests.logout();

select ok(not exists (select 1 from public.photos where id = tests.id('a_photo')), '離開後該成員在此群組的照片被刪除');
select ok(exists (select 1 from private.storage_deletions where path = current_setting('tests.a_path')),
  '照片檔案排入刪除佇列');
select is(private.credits(tests.id('bob'), tests.id('h')), 1, '收過離開者照片的人退回一次資格');
select is((select owner_id from public.groups where id = tests.id('h')), tests.id('bob'),
  '擁有者離開 → 最早加入的成員接手');

select tests.login_as(tests.id('bob'));
select public.leave_group(tests.id('h'));
select tests.logout();
select tests.login_as(tests.id('carol'));
select public.leave_group(tests.id('h'));
select tests.logout();
select ok(not exists (select 1 from public.groups where id = tests.id('h')), '最後一人離開 → 群組刪除');

select * from finish();
rollback;
