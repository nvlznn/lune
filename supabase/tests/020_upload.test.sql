-- 上傳：一個群組一個換日週期一張，伺服器決定 day。
begin;
select plan(17);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('g1', tests.create_group(tests.id('alice'), '家人'));
select tests.remember('g2', tests.create_group(tests.id('alice'), '同學'));
select tests.join(tests.id('bob'), tests.id('g1'));

-- 第一次上傳
select tests.remember('a1', tests.upload(tests.id('alice'), tests.id('g1'), '2026-10-06 21:14:00'));
select is(
  (select day from public.photos where id = tests.id('a1')), public.swapee_day(),
  'day 由伺服器以 04:00 換日算出');
select is(
  (select taken_at from public.photos where id = tests.id('a1')), timestamp '2026-10-06 21:14:00',
  '拍攝時間照原樣保存');

-- 同一群組第二次
select set_config('tests.path', tests.put_object(tests.id('alice'), tests.id('g1')), false);
select tests.login_as(tests.id('alice'));
select throws_ok(
  $$ select public.upload_photo(tests.id('g1'), current_setting('tests.path')) $$,
  'P0001', 'already_uploaded_today', '同一群組同一天第二次上傳被拒絕');
select tests.logout();

-- 另一個群組
select lives_ok(
  $$ select tests.upload(tests.id('alice'), tests.id('g2')) $$,
  '同一天在另一個群組上傳 → 允許');

-- 換日後
select tests.backdate(tests.id('a1'), interval '1 day');
select lives_ok(
  $$ select tests.upload(tests.id('alice'), tests.id('g1')) $$,
  '前一個換日週期傳過，今天可以再傳');

-- 非成員
select set_config('tests.carol_path', tests.put_object(tests.id('carol'), tests.id('g1')), false);
select tests.login_as(tests.id('carol'));
select throws_ok(
  $$ select public.upload_photo(tests.id('g1'), current_setting('tests.carol_path')) $$,
  'P0001', 'not_member', '非成員上傳被拒絕');
select throws_ok(
  $$ select public.claim_photo(tests.id('g1')) $$,
  'P0001', 'not_member', '非成員 claim 被拒絕');
select tests.logout();

-- 客戶端不能指定 day，也不能直接寫 photos
select tests.login_as(tests.id('bob'));
select throws_ok(
  $$ insert into public.photos (group_id, user_id, day, storage_path)
     values (tests.id('g1'), tests.id('bob'), date '2000-01-01', 'x') $$,
  '42501', null, '直接寫入 photos（自己指定 day）被 RLS 拒絕');
select throws_ok(
  $$ select public.upload_photo(tests.id('g1'),
       tests.id('g1')::text || '/' || tests.id('bob')::text || '/' || gen_random_uuid()::text || '.jpg') $$,
  'P0001', 'file_missing', '檔案沒傳上去就登記 → 拒絕');
select throws_ok(
  $$ select public.upload_photo(tests.id('g1'), current_setting('tests.path')) $$,
  'P0001', 'invalid_path', '登記別人資料夾裡的檔案 → 拒絕');
select tests.logout();

select is(
  (select taken_at from public.photos where group_id = tests.id('g2') and user_id = tests.id('alice')),
  null, '讀不到拍攝時間時存 null');

-- Storage 上傳 policy
select tests.login_as(tests.id('bob'));
select lives_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('photos', tests.id('g1')::text || '/' || tests.id('bob')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('bob')) $$,
  '成員可以把檔案傳到自己的資料夾');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('photos', tests.id('g1')::text || '/' || tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('bob')) $$,
  '42501', null, '不能傳到別人的資料夾');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('photos', tests.id('g1')::text || '/' || tests.id('bob')::text || '/evil.jpg', tests.id('bob')) $$,
  '42501', null, '檔名不是 UUID → 拒絕');
select tests.logout();

select tests.login_as(tests.id('alice'));
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('photos', tests.id('g1')::text || '/' || tests.id('alice')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('alice')) $$,
  '42501', null, '今天已經傳過的群組不能再傳檔案');
select tests.logout();

select tests.login_as(tests.id('carol'));
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('photos', tests.id('g1')::text || '/' || tests.id('carol')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('carol')) $$,
  '42501', null, '非成員不能傳檔案到群組');
select tests.logout();

-- 未登記的檔案最多 3 個
select tests.put_object(tests.id('bob'), tests.id('g1'));
select tests.put_object(tests.id('bob'), tests.id('g1'));
select tests.login_as(tests.id('bob'));
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, owner)
     values ('photos', tests.id('g1')::text || '/' || tests.id('bob')::text || '/' || gen_random_uuid()::text || '.jpg', tests.id('bob')) $$,
  '42501', null, '未登記的檔案超過 3 個 → 拒絕');
select tests.logout();

select * from finish();
rollback;
