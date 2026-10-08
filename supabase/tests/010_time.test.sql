-- Days roll over at 04:00 local time; the diary is open 20:00–04:00.
begin;
select plan(10);

select is(private.day_at('Asia/Taipei', '2026-10-07 04:01:00+08'), date '2026-10-07', '04:01 is the new day');
select is(private.day_at('Asia/Taipei', '2026-10-07 03:59:00+08'), date '2026-10-06', '03:59 still belongs to the previous day');
select is(private.day_at('America/New_York', '2026-10-07 01:00:00+00'), date '2026-10-06',
  'each person''s own time zone decides the day (01:00 UTC is 21:00 in New York)');

select ok(private.is_open_at('Asia/Taipei', '2026-10-07 20:00:00+08'), 'opens at 20:00');
select ok(private.is_open_at('Asia/Taipei', '2026-10-07 23:59:00+08'), 'open before midnight');
select ok(private.is_open_at('Asia/Taipei', '2026-10-08 03:59:00+08'), 'still open at 03:59');
select ok(not private.is_open_at('Asia/Taipei', '2026-10-08 04:00:00+08'), 'closes at 04:00');
select ok(not private.is_open_at('Asia/Taipei', '2026-10-07 19:59:00+08'), 'closed at 19:59');
select is(private.day_at('Asia/Taipei', '2026-10-08 02:00:00+08'), private.day_at('Asia/Taipei', '2026-10-07 21:00:00+08'),
  'the whole night window is one day');

select is(extract(hour from now() at time zone tests.tz_for_hour(22))::integer, 22, 'test helper: a zone where it''s 22:00 now');

select * from finish();
rollback;
