-- Registration fixtures never send email and are rolled back.
begin;
do $$
declare
 active_id uuid:=gen_random_uuid(); grad_id uuid:=gen_random_uuid();
 social_id uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid(); bad_id uuid;
 invalid_year text; saved_username text;
begin
 foreach invalid_year in array array['','30','2030.5','1899','2201','Fall 2030'] loop
  bad_id:=gen_random_uuid();
  begin
   insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data)
   values(bad_id,bad_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('full_name','Missing Year','requested_sm_year',invalid_year));
   raise exception 'Invalid year accepted';
  exception when others then
   if sqlerrm <> 'Enter your four-digit Sigma Mu year' then raise; end if;
  end;
  assert not exists(select 1 from auth.users where id=bad_id),'Rejected signup persisted';
 end loop;
 insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data) values
 (active_id,active_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('full_name','Active Year Test','requested_member_type','active','requested_sm_year','2030')),
 (grad_id,grad_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('full_name','Graduate Year Test','requested_member_type','graduate','requested_sm_year','1999')),
 (admin_id,admin_id::text||'@example.invalid','{"provider":"email"}',jsonb_build_object('full_name','Admin Year Test','requested_sm_year','2000')),
 (social_id,social_id::text||'@example.invalid','{"provider":"google"}',jsonb_build_object('full_name','Google Year Test'));
 assert exists(select 1 from public.members where user_id=active_id and member_type='active' and pledge_class='2030' and not approved),'Active year not saved';
 assert exists(select 1 from public.members where user_id=grad_id and member_type='graduate' and pledge_class='1999' and not approved),'Graduate year not saved';
 assert exists(select 1 from public.members where user_id=social_id and not registration_complete),'Google must complete profile';
 update public.members set approved=true,role='admin' where user_id=admin_id;
 perform set_config('request.jwt.claim.sub',social_id::text,true);
 set local role authenticated;
 foreach invalid_year in array array[null::text,'','30','2201'] loop
  begin
   perform public.complete_brother_registration('Google Year Test',null,'+16625550123','graduate',null,invalid_year);
   raise exception 'Invalid completion year accepted';
  exception when others then
   if sqlerrm <> 'Enter your four-digit Sigma Mu year' then raise; end if;
  end;
 end loop;
 perform public.complete_brother_registration('Google Year Test',null,'+16625550123','graduate',null,'2026');
 assert exists(select 1 from public.members where user_id=social_id and pledge_class='2026' and registration_complete and not approved and role='member'),'Google year completion failed';
 reset role;
 select username into saved_username from public.members where user_id=active_id;
 update public.members set registration_complete=false,pledge_class=null where user_id=active_id;
 perform set_config('request.jwt.claim.sub',active_id::text,true);
 set local role authenticated;
 perform public.complete_brother_registration('Active Year Test',null,'+16625550123','active',null,'2030');
 assert exists(select 1 from public.members where user_id=active_id and username=saved_username and pledge_class='2030'),'Existing pending username/year not preserved';
 reset role;
 update public.members set pledge_class=null where user_id=grad_id;
 perform set_config('request.jwt.claim.sub',admin_id::text,true);
 set local role authenticated;
 begin
  perform public.review_brother_application(grad_id,true);
  raise exception 'Approved without Sigma Mu year';
 exception when others then
  if sqlerrm not like 'Brother must complete registration%' then raise; end if;
 end;
 perform public.review_brother_application(active_id,true);
 assert exists(select 1 from public.members where user_id=active_id and approved and pledge_class='2030'),'Approved profile lost year';
 reset role;
 assert not has_function_privilege('anon','public.complete_brother_registration(text,text,text,text,text,text)','EXECUTE'),'Anonymous completion allowed';
end $$;
select 'Required Sigma Mu year tests passed: email, Google, Active, Graduate, validation, approval and existing pending accounts; all fixtures rolled back.' as result;
rollback;
