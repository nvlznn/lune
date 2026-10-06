-- 接收：一傳一收、72 小時照片池、被收最少的優先。
begin;
select plan(18);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('dave', tests.create_user('dave'));
select tests.remember('g', tests.create_group(tests.id('alice'), 'Noky'));
select tests.remember('other', tests.create_group(tests.id('dave'), '別的群組'));
select tests.join(tests.id('bob'), tests.id('g'));
select tests.join(tests.id('carol'), tests.id('g'));
select tests.join(tests.id('alice'), tests.id('other'));

-- 沒有資格
select tests.login_as(tests.id('alice'));
select throws_ok(
  $$ select public.claim_photo(tests.id('g')) $$,
  'P0001', 'no_credits', '沒上傳過（credits = 0）→ 拒絕');
select tests.logout();

-- 別的群組有照片，但 alice 在 g 的池子是空的
select tests.upload(tests.id('dave'), tests.id('other'));
select tests.remember('a1', tests.upload(tests.id('alice'), tests.id('g')));
select is(tests.claim(tests.id('alice'), tests.id('g')) ->> 'status', 'waiting',
  '池子只有自己的照片（別的群組不算）→ waiting');

-- 有人上傳之後
select tests.remember('b1', tests.upload(tests.id('bob'), tests.id('g')));
select set_config('tests.result', tests.claim(tests.id('alice'), tests.id('g'))::text, false);
select is(current_setting('tests.result')::jsonb ->> 'status', 'delivered', '之後有人上傳 → 收到');
select is((current_setting('tests.result')::jsonb -> 'photo' ->> 'photo_id')::uuid, tests.id('b1'), '收到的是 bob 的照片');
select is(current_setting('tests.result')::jsonb -> 'photo' ->> 'sender_name', 'bob', '回傳寄件人名稱');

-- 一傳一收
select tests.login_as(tests.id('alice'));
select throws_ok(
  $$ select public.claim_photo(tests.id('g')) $$,
  'P0001', 'no_credits', '上傳 1 張只能收 1 張');
select tests.logout();

-- 同一張可以被多人各收一次；被收最少的優先
-- 現在 a1 被收 0 次、b1 被收 1 次 → carol 應該拿到 a1
select tests.upload(tests.id('carol'), tests.id('g'));
select is((tests.claim(tests.id('carol'), tests.id('g')) -> 'photo' ->> 'photo_id')::uuid, tests.id('a1'),
  '優先抽被收過次數最少的');
-- bob 拿到 a1 或 carol 的（都被收 0～1 次）；不會是自己的
select isnt((tests.claim(tests.id('bob'), tests.id('g')) -> 'photo' ->> 'photo_id')::uuid, tests.id('b1'),
  '不會抽到自己的照片');

-- 同一人不能收同一張兩次
select throws_ok(
  $$ insert into public.deliveries (receiver_id, group_id, photo_id)
     values (tests.id('alice'), tests.id('g'), tests.id('b1')) $$,
  '23505', null, 'unique(receiver_id, photo_id)');

-- alice 再傳兩天 → 多兩次資格；池子裡 b1 已收過、carol 的還沒
select tests.backdate(tests.id('a1'), interval '2 days');
select tests.remember('a2', tests.upload(tests.id('alice'), tests.id('g')));
select tests.backdate(tests.id('a2'), interval '1 day');
select tests.upload(tests.id('alice'), tests.id('g'));
select is((tests.claim(tests.id('alice'), tests.id('g')) -> 'photo' ->> 'sender_id')::uuid,
  tests.id('carol'), '已收過的不會再抽到，改抽還沒收過的');
select is(tests.claim(tests.id('alice'), tests.id('g')) ->> 'status', 'waiting',
  '有資格但全部都收過 → waiting');

-- 72 小時
select tests.remember('d2', tests.create_user('erin'));
select tests.join(tests.id('d2'), tests.id('g'));
select tests.remember('e_old', tests.upload(tests.id('d2'), tests.id('g')));
select tests.backdate(tests.id('e_old'), interval '72 hours 1 minute');
select is(tests.claim(tests.id('alice'), tests.id('g')) ->> 'status', 'waiting',
  '剛好超過 72 小時的照片不會被抽到');
select tests.backdate(tests.id('e_old'), interval '71 hours 59 minutes');
select is((tests.claim(tests.id('alice'), tests.id('g')) -> 'photo' ->> 'photo_id')::uuid, tests.id('e_old'),
  '72 小時內的照片會被抽到');

-- 前天沒人丟、昨天有人丟 → 今天收到昨天的
select tests.remember('frank', tests.create_user('frank'));
select tests.remember('h', tests.create_group(tests.id('frank'), '昨天'));
select tests.remember('gina', tests.create_user('gina'));
select tests.join(tests.id('gina'), tests.id('h'));
select tests.remember('f_yday', tests.upload(tests.id('frank'), tests.id('h')));
select tests.backdate(tests.id('f_yday'), interval '30 hours');
select tests.upload(tests.id('gina'), tests.id('h'));
select is((tests.claim(tests.id('gina'), tests.id('h')) -> 'photo' ->> 'photo_id')::uuid, tests.id('f_yday'),
  '不要求對方同一天傳：今天收到昨天的照片');

-- 封鎖
select tests.remember('hank', tests.create_user('hank'));
select tests.join(tests.id('hank'), tests.id('h'));
select tests.remember('h_photo', tests.upload(tests.id('hank'), tests.id('h')));
select tests.backdate(tests.id('h_photo'), interval '1 day');
select tests.upload(tests.id('hank'), tests.id('h'));
select tests.login_as(tests.id('frank'));
select public.block_user(tests.id('hank'));
select tests.logout();
-- hank 有 2 次資格，池子裡有 frank（封鎖）、gina 的照片
select is((tests.claim(tests.id('hank'), tests.id('h')) -> 'photo' ->> 'sender_id')::uuid,
  tests.id('gina'), '被封鎖者的照片不會被抽到（封鎖是雙向的）');
select is(tests.claim(tests.id('hank'), tests.id('h')) ->> 'status', 'waiting',
  '剩下的只有封鎖對象的照片 → waiting');

-- 已經收到的照片固定：claim 不會改動既有的 deliveries
select is(
  (select count(*)::integer from public.deliveries where receiver_id = tests.id('alice') and group_id = tests.id('g')),
  3, 'alice 收到的照片數 = 3 次上傳、3 次成功 claim');

-- 3 次上傳、3 次收片 → credits 0
select tests.login_as(tests.id('alice'));
select is((public.group_state(tests.id('g')) ->> 'credits')::integer, 0, 'group_state 的 credits 正確');
select tests.logout();

select * from finish();
rollback;
