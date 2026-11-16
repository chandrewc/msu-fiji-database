-- Private newsletter PDFs for approved Brother Network members.
alter table public.newsletters add column pdf_path text;
alter table public.newsletters add constraint newsletter_pdf_path_valid check(pdf_path is null or pdf_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$');
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('brother-newsletters','brother-newsletters',false,20971520,array['application/pdf']);
create policy newsletter_pdf_read on storage.objects for select to authenticated using(bucket_id='brother-newsletters' and ((select public.has_admin_permission('newsletter')) or ((select public.is_approved_member()) and exists(select 1 from public.newsletters n where n.pdf_path=name))));
create policy newsletter_pdf_insert on storage.objects for insert to authenticated with check(bucket_id='brother-newsletters' and (select public.has_admin_permission('newsletter')) and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$');
create policy newsletter_pdf_delete on storage.objects for delete to authenticated using(bucket_id='brother-newsletters' and (select public.has_admin_permission('newsletter')));
create policy "deactivated accounts have no newsletter PDF access" on storage.objects as restrictive for all to authenticated using(bucket_id<>'brother-newsletters' or not (select public.is_deactivated_member())) with check(bucket_id<>'brother-newsletters' or not (select public.is_deactivated_member()));
notify pgrst,'reload schema';
