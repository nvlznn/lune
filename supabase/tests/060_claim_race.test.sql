-- 同時呼叫兩次 claim_photo 不會超收（advisory lock）。
-- 需要兩條真的連線，所以資料必須 commit；這個檔案不包 transaction，結尾自己清掉。

create extension if not exists dblink with schema extensions;

-- 上次中途失敗留下的資料
set storage.allow_delete_query = 'true';
delete from storage.objects where owner in (select id from auth.users where email like 'race-%@test.local');
delete from auth.users where email like 'race-%@test.local';

select tests.remember('race_alice', tests.create_user('race-alice'));
select tests.remember('race_bob', tests.create_user('race-bob'));
select tests.remember('race_carol', tests.create_user('race-carol'));
select tests.remember('race_g', tests.create_group(tests.id('race_alice'), 'race'));
select tests.join(tests.id('race_bob'), tests.id('race_g'));
select tests.join(tests.id('race_carol'), tests.id('race_g'));
-- alice 一次資格，池子裡有兩張可收
select tests.upload(tests.id('race_alice'), tests.id('race_g'));
select tests.upload(tests.id('race_bob'), tests.id('race_g'));
select tests.upload(tests.id('race_carol'), tests.id('race_g'));

select set_config('tests.claim_sql',
  format('select tests.claim(%L, %L)::text', tests.id('race_alice'), tests.id('race_g')), false);
-- Supabase 的 postgres 不是 superuser，dblink 必須真的用密碼登入：
-- 連到這條連線所用的 docker 網路位址（127.0.0.1 是 trust，不算），帳密為本機 supabase start 的預設值。
select set_config('tests.dsn', format('host=%s port=5432 dbname=%s user=postgres password=postgres',
  host(inet_server_addr()), current_database()), false);
select dblink_connect('race1', current_setting('tests.dsn'));
select dblink_connect('race2', current_setting('tests.dsn'));

begin;
select plan(4);

-- 第一條連線 claim 完先不 commit，鎖還握著
select dblink_exec('race1', 'begin');
select is(
  (select r::jsonb ->> 'status' from dblink('race1', current_setting('tests.claim_sql')) as t(r text)),
  'delivered', '第一個 claim 收到照片');

-- 第二條連線同時 claim，應該卡在鎖上
select dblink_send_query('race2', current_setting('tests.claim_sql'));
select pg_sleep(0.5);
select is(dblink_is_busy('race2'), 1, '第二個 claim 在等第一個釋放鎖');

select dblink_exec('race1', 'commit');
select count(*) from dblink_get_result('race2', false) as t(r text);
select matches(dblink_error_message('race2'), 'no_credits', '第一個 commit 後，第二個 claim 因沒有資格被拒絕');

select is(
  (select count(*)::integer from public.deliveries where receiver_id = tests.id('race_alice')),
  1, '只收到一張，沒有超收');

select * from finish();
rollback;

select dblink_disconnect('race1');
select dblink_disconnect('race2');

-- 清掉 commit 進去的資料
delete from storage.objects where name like tests.id('race_g')::text || '/%';
delete from private.storage_deletions where path like tests.id('race_g')::text || '/%';
delete from auth.users where email like 'race-%@test.local';
