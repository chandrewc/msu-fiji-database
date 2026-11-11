begin;
do $$
declare
  first_id uuid := gen_random_uuid();
  second_id uuid := gen_random_uuid();
  social_id uuid := gen_random_uuid();
  legacy_id uuid := gen_random_uuid();
  legacy_social_id uuid := gen_random_uuid();
  accent_id uuid := gen_random_uuid();
  short_id uuid := gen_random_uuid();
  long_id uuid := gen_random_uuid();
  test_name text := 'Auto' || left(replace(gen_random_uuid()::text, '-', ''), 10) || ' Smith';
  base_name text;
  actual text;
begin
  base_name := private.generate_brother_username(test_name, first_id);
  assert base_name = lower(replace(test_name, ' ', '.')), 'First/last format';
  insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data) values
    (first_id,first_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('requested_sm_year','2030','full_name',test_name,'role','super_admin','approved',true)),
    (second_id,second_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('requested_sm_year','2030','full_name',test_name)),
    (social_id,social_id::text||'@example.invalid','{"provider":"google"}',jsonb_build_object('requested_sm_year','2030','full_name',test_name)),
    (legacy_id,legacy_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('requested_sm_year','2030','full_name','Legacy Invited Brother','requested_username','legacy_'||replace(legacy_id::text,'-',''))),
    (legacy_social_id,legacy_social_id::text||'@example.invalid','{"provider":"google"}',jsonb_build_object('requested_sm_year','2030','full_name','Legacy Google Brother')),
    (accent_id,accent_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('requested_sm_year','2030','full_name','José Middle O’Neal')),
    (short_id,short_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('requested_sm_year','2030','full_name','李明')),
    (long_id,long_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('requested_sm_year','2030','full_name',repeat('A',60)||' '||repeat('B',50)));
  assert exists(select 1 from public.members where user_id=first_id and username=base_name and role='member' and not approved and not rejected and registration_complete), 'Email registration security';
  assert exists(select 1 from public.members where user_id=second_id and username=base_name||'2'), 'Duplicate name suffix';
  assert exists(select 1 from public.members where user_id=legacy_id and username='legacy_'||replace(legacy_id::text,'-','')), 'Invitation compatibility';
  assert exists(select 1 from public.members where user_id=accent_id and username ~ '^jose.oneal[0-9]*$'), 'Accents/apostrophes/middle names';
  assert exists(select 1 from public.members where user_id=short_id and username ~ '^brother[0-9]*$'), 'Non-Latin fallback';
  assert exists(select 1 from public.members where user_id=long_id and length(username)<=40 and username ~ '^[a-z0-9._-]{3,40}$'), 'Long name';
  assert not has_function_privilege('authenticated','private.generate_brother_username(text,uuid)','EXECUTE'), 'Helper is public';
  assert not has_function_privilege('anon','public.complete_brother_registration(text,text,text,text,text,text)','EXECUTE'), 'Anonymous completion access';
  perform set_config('request.jwt.claim.sub', social_id::text, true);
  set local role authenticated;
  perform public.complete_brother_registration(test_name,null,'+16625550123','active','untrusted@example.invalid','2030');
  assert exists(select 1 from public.members where user_id=social_id and username=base_name||'3' and registration_complete and not approved and role='member' and email_contact=social_id::text||'@example.invalid'), 'Automatic Google completion';
  begin
    perform public.complete_brother_registration(test_name,null,'+16625550123','active',null,'2030');
    raise exception 'Repeat completion unexpectedly succeeded';
  exception when others then
    if sqlerrm not like 'Registration is not available%' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub',legacy_social_id::text,true);
  perform public.complete_brother_registration('Legacy Google Brother','legacy_google_'||left(replace(legacy_social_id::text,'-',''),16),'+16625550123','graduate',null,'2030');
  assert exists(select 1 from public.members where user_id=legacy_social_id and username='legacy_google_'||left(replace(legacy_social_id::text,'-',''),16)), 'Existing Google client compatibility';
  reset role;
end $$;
select 'Email, Google, duplicate names, normalization, length, legacy clients and permissions passed. All fixtures rolled back.' as result;
rollback;
