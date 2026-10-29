create or replace function public.queue_newsletter_email() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.newsletter_email_batches(newsletter_id,title,body,issue_date,pdf_url,recipients)
 select new.id,new.title,coalesce(new.body,''),new.issue_date,new.pdf_url,jsonb_agg(jsonb_build_object('email',email) order by email)
 from (
  select email,(row_number() over(order by email)-1)/100 as batch from (
   select distinct lower(trim(coalesce(nullif(trim(m.email_contact),''),u.email))) as email
   from public.members m join auth.users u on u.id=m.user_id
   left join public.newsletter_email_preferences p on p.user_id=m.user_id
   where m.approved and not m.rejected and m.member_type='graduate' and coalesce(p.enabled,true)
  ) addresses where email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
 ) numbered group by batch;
 return new;
end $$;
