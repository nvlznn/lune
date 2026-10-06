-- 換日：Asia/Taipei 04:00。
begin;
select plan(5);

select is(public.swapee_day('2026-10-07 04:01:00+08'), date '2026-10-07', '04:01 算當天');
select is(public.swapee_day('2026-10-07 03:59:00+08'), date '2026-10-06', '03:59 算前一天');
select is(public.swapee_day('2026-10-07 04:00:00+08'), date '2026-10-07', '04:00 整開始新的一天');
select is(public.swapee_day('2026-10-06 23:50:00+08'), public.swapee_day('2026-10-07 00:10:00+08'),
  '23:50 與 00:10 是同一天');
select is(public.swapee_day('2026-10-06 20:30:00+00'), date '2026-10-07',
  '用 UTC 表示的時間也以台北時間換日（UTC 20:30 = 台北 04:30）');

select * from finish();
rollback;
