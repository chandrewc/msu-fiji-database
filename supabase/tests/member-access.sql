begin;
create function pg_temp.expect_access_failure(command text, expected text) returns void language plpgsql as $$
begin
 begin
  execute command;
 exception when others then
  if position(expected in sqlerrm)>0 then return; end if;
  raise;
 end;
 raise exception 'Expected failure did not occur: %',expected;
end $$;
do $$
declare
 super_id uuid:=gen_random_uuid(); admin_id uuid:=gen_random_uuid(); delegate_id uuid:=gen_random_uuid();
 target_id uuid:=gen_random_uuid(); ordinary_id uuid:=gen_random_uuid(); pending_id uuid:=gen_random_uuid();
 account_id uuid; news_id uuid:=gen_random_uuid(); saved_name text;
begin
 perform set_config('request.jwt.claim.sub','',true);
 foreach account_id in array array[super_id,admin_id,delegate_id,target_id,ordinary_id,pending_id] loop
  insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data)
  values(account_id,replace(account_id::text,'-','')||'@example.invalid','{"provider":"email"}',jsonb_build_object('requested_username','test_'||replace(account_id::text,'-',''),'full_name','Temporary access test'));
 end loop;
 update public.members set approved=true where user_id=any(array[super_id,admin_id,delegate_id,target_id,ordinary_id]);
 update public.members set role='super_admin' where user_id=super_id;
 update public.members set role='admin' where user_id=admin_id;
 insert into public.member_admin_permissions(user_id,permission,granted_by) values(delegate_id,'brothers',super_id),(target_id,'news',super_id);
 insert into public.site_permissions(user_id,role) values(target_id,'editor');
 insert into public.newsletter_email_preferences(user_id,enabled) values(target_id,true) on conflict do nothing;
 insert into public.announcements(id,title,body) values(news_id,'Temporary access test','Rolled back');
 select full_name into saved_name from public.members where user_id=target_id;
 assert not has_function_privilege('anon','public.admin_set_brother_access(uuid,boolean)','EXECUTE'),'Anonymous RPC execution';
 perform set_config('request.jwt.claim.sub',ordinary_id::text,true);
 set local role authenticated;
 perform pg_temp.expect_access_failure(format('select public.admin_set_brother_access(%L,false)',target_id),'Manage Brothers permission required');
 perform set_config('request.jwt.claim.sub',admin_id::text,true);
 perform pg_temp.expect_access_failure(format('select public.admin_set_brother_access(%L,false)',admin_id),'own account');
 perform pg_temp.expect_access_failure(format('select public.admin_set_brother_access(%L,false)',super_id),'Super Administrator account is protected');
 perform pg_temp.expect_access_failure(format('select public.admin_set_brother_access(%L,true)',pending_id),'previously approved');
 perform set_config('request.jwt.claim.sub',delegate_id::text,true);
 perform pg_temp.expect_access_failure(format('select public.admin_set_brother_access(%L,false)',admin_id),'Only the Super Administrator');
 assert exists(select 1 from public.members where user_id=target_id and approved),'Enabled target missing from directory';
 assert exists(select 1 from public.announcements where id=news_id),'Enabled member cannot read news';
 perform public.admin_set_brother_access(target_id,false);
 assert exists(select 1 from public.members where user_id=target_id and not approved and deactivated_at is not null),'Deactivation state missing';
 perform set_config('request.jwt.claim.sub',target_id::text,true);
 assert public.is_deactivated_member(),'Deactivation helper';
 assert not public.is_approved_member(),'Previously issued member identity still has access';
 assert not public.has_admin_permission('news'),'Delegated permissions remain effective';
 assert public.site_role() is null,'Website staff access remains effective';
 assert (select count(*) from public.members where user_id<>target_id)=0,'Deactivated account reads other members';
 assert (select count(*) from public.members where user_id=target_id)=1,'Account cannot read own access state';
 assert (select count(*) from public.announcements)=0,'Deactivated account reads chapter news';
 assert (select count(*) from public.newsletter_email_preferences)=0,'Deactivated account reads private preferences';
 assert (select count(*) from public.site_permissions)=0,'Deactivated account reads website permissions';
 perform pg_temp.expect_access_failure(format('select public.admin_set_brother_access(%L,true)',target_id),'Manage Brothers permission required');
 update public.members set approved=true,deactivated_at=null where user_id=target_id;
 assert exists(select 1 from public.members where user_id=target_id and not approved and deactivated_at is not null),'Self reactivation through direct update';
 perform set_config('request.jwt.claim.sub',admin_id::text,true);
 assert not exists(select 1 from public.members where user_id=target_id and approved),'Deactivated target still in approved directory';
 perform pg_temp.expect_access_failure(format('select public.review_brother_application(%L,true)',target_id),'Application not reviewable');
 assert exists(select 1 from public.admin_activity_log where actor_id=delegate_id and action='Deactivated brother'),'Deactivation not logged';
 perform public.admin_set_brother_access(target_id,true);
 assert exists(select 1 from public.members where user_id=target_id and approved and deactivated_at is null and full_name=saved_name and role='member'),'Reactivation did not preserve profile';
 assert exists(select 1 from public.member_admin_permissions where user_id=target_id and permission='news'),'Permissions lost on reactivation';
 assert exists(select 1 from public.admin_activity_log where actor_id=admin_id and action='Reactivated brother'),'Reactivation not logged';
 perform set_config('request.jwt.claim.sub',target_id::text,true);
 assert public.is_approved_member() and public.has_admin_permission('news'),'Reactivated access not restored';
 assert public.site_role()='editor','Website role not restored';
 assert exists(select 1 from public.announcements where id=news_id),'Reactivated member cannot read news';
 perform set_config('request.jwt.claim.sub',super_id::text,true);
 perform public.admin_set_brother_access(admin_id,false);
 perform public.admin_set_brother_access(admin_id,true);
 reset role;
 assert exists(select 1 from public.members where user_id=admin_id and approved and role='admin'),'Full Administrator role not preserved';
end $$;
select 'Member deactivation, reactivation, RLS, permissions, protected accounts and audit tests passed; fixtures rolled back.' as result;
rollback;
