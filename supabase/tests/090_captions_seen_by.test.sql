-- Captions and "seen by".
begin;
select plan(9);

select tests.remember('alice', tests.create_user('alice'));
select tests.remember('bob', tests.create_user('bob'));
select tests.remember('carol', tests.create_user('carol'));
select tests.remember('g', tests.create_group(tests.id('alice'), 'captions'));
select tests.join(tests.id('bob'), tests.id('g'));
select tests.join(tests.id('carol'), tests.id('g'));

-- Alice sends with a caption.
select set_config('tests.path', tests.put_object(tests.id('alice'), tests.id('g')), false);
select tests.login_as(tests.id('alice'));
select throws_ok(
  format($$ select public.upload_photo(%L, %L, null, %L) $$, tests.id('g'), current_setting('tests.path'), repeat('a', 141)),
  'P0001', 'caption_too_long', 'captions longer than 140 characters are rejected');
select public.upload_photo(tests.id('g'), current_setting('tests.path'), null, E'  Lunch  \r\n\n\n\n  at   the beach \n ');
select tests.logout();
select is((select caption from public.photos where storage_path = current_setting('tests.path')), E'Lunch\n\nat the beach',
  'line breaks are kept (at most one blank line), spaces tidied, ends trimmed');

-- Bob sends with a blank caption.
select set_config('tests.bob_path', tests.put_object(tests.id('bob'), tests.id('g')), false);
select tests.login_as(tests.id('bob'));
select public.upload_photo(tests.id('g'), current_setting('tests.bob_path'), null, '   ');
select tests.logout();
select is((select caption from public.photos where storage_path = current_setting('tests.bob_path')), null,
  'a blank caption is stored as none');

select tests.login_as(tests.id('alice'));
select is(public.group_state(tests.id('g')) -> 'today_photo' ->> 'caption', E'Lunch\n\nat the beach', 'the sender sees their caption');
select is(jsonb_array_length(public.group_state(tests.id('g')) -> 'today_photo' -> 'seen_by'), 0, 'nobody has seen it yet');
select tests.logout();

-- Bob receives it.
select tests.claim(tests.id('bob'), tests.id('g'));
select tests.login_as(tests.id('bob'));
select is(public.group_state(tests.id('g')) -> 'received' -> 0 ->> 'caption', E'Lunch\n\nat the beach', 'the receiver sees the caption');
select tests.logout();

select tests.login_as(tests.id('alice'));
select is(public.group_state(tests.id('g')) -> 'today_photo' -> 'seen_by' -> 0 ->> 'name', 'bob', 'the sender sees who received it');
select isnt(public.group_state(tests.id('g')) -> 'today_photo' -> 'seen_by' -> 0 ->> 'seen_at', null, '…and when');
-- Blocking hides them.
select public.block_user(tests.id('bob'));
select is(jsonb_array_length(public.group_state(tests.id('g')) -> 'today_photo' -> 'seen_by'), 0, 'blocked people are not listed');
select tests.logout();

select * from finish();
rollback;
