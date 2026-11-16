begin;
-- Rolled-back fixtures: no emails or actual files are created.
do $$
declare publisher uuid:=gen_random_uuid();reader uuid:=gen_random_uuid();pending uuid:=gen_random_uuid();news_only uuid:=gen_random_uuid();person uuid;issue uuid:=gen_random_uuid();path text:=gen_random_uuid()::text||'.pdf';
begin
 foreach person in array array[publisher,reader,pending,news_only] loop
  insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data) values(person,person::text||'@example.invalid','{"provider":"email"}','{"requested_sm_year":"2030"}');
 end loop;
 update public.members set approved=true where user_id=any(array[publisher,reader,news_only]);
 insert into public.member_admin_permissions(user_id,permission) values(publisher,'newsletter'),(news_only,'news');
 assert exists(select 1 from storage.buckets where id='brother-newsletters' and not public and file_size_limit=20971520 and allowed_mime_types=array['application/pdf']),'Private PDF bucket configuration';
 perform set_config('request.jwt.claim.sub',reader::text,true);set local role authenticated;
 begin insert into storage.objects(bucket_id,name) values('brother-newsletters',path);raise exception 'Reader uploaded PDF';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',news_only::text,true);
 begin insert into storage.objects(bucket_id,name) values('brother-newsletters',path);raise exception 'News-only publisher uploaded PDF';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',publisher::text,true);
 insert into storage.objects(bucket_id,name) values('brother-newsletters',path);
 assert exists(select 1 from storage.objects where bucket_id='brother-newsletters' and name=path),'Publisher preview denied';
 begin insert into storage.objects(bucket_id,name) values('brother-newsletters','invalid.html');raise exception 'Invalid storage filename accepted';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',reader::text,true);
 assert not exists(select 1 from storage.objects where bucket_id='brother-newsletters' and name=path),'Unpublished PDF exposed';
 perform set_config('request.jwt.claim.sub',publisher::text,true);
 insert into public.newsletters(id,title,body,issue_date,pdf_path) values(issue,'PDF test','Summary',current_date,path);
 begin update public.newsletters set pdf_path='https://external.example/x.pdf' where id=issue;raise exception 'Invalid PDF path accepted';exception when check_violation then null;end;
 perform set_config('request.jwt.claim.sub',reader::text,true);
 assert exists(select 1 from storage.objects where bucket_id='brother-newsletters' and name=path),'Approved brother cannot read attached PDF';
 perform set_config('request.jwt.claim.sub',pending::text,true);
 assert not exists(select 1 from storage.objects where bucket_id='brother-newsletters' and name=path),'Pending account reads PDF';
 reset role;update public.members set approved=false,deactivated_at=now() where user_id=publisher;
 perform set_config('request.jwt.claim.sub',publisher::text,true);set local role authenticated;
 assert not exists(select 1 from storage.objects where bucket_id='brother-newsletters' and name=path),'Deactivated publisher reads PDF';
 reset role;set local role anon;
 assert not exists(select 1 from storage.objects where bucket_id='brother-newsletters' and name=path),'Anonymous user reads PDF';
 reset role;
end $$;
select 'Private bucket, publisher uploads, published-only member reading, path validation, pending/deactivated/anonymous restrictions passed; all fixtures rolled back.' as result;
rollback;
