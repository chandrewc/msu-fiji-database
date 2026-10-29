import {createClient} from 'npm:@supabase/supabase-js@2.99.1';
import {emailFor,validateIssue} from './email.ts';
const allowed=new Set(['https://brothers.msufiji.com','https://chandrewc.github.io']);
Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('origin')||'';
 const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':allowed.has(origin)?origin:'https://brothers.msufiji.com','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin'};
 const reply=(data:any,status=200)=>new Response(JSON.stringify(data),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST'||(origin&&!allowed.has(origin)))return reply({error:'Request not allowed.'},405);
 try{
  const auth=req.headers.get('authorization')||'';
  if(!auth.startsWith('Bearer '))return reply({error:'Please sign in.'},401);
  const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const member=createClient(url,anon,{global:{headers:{Authorization:auth}},auth:{persistSession:false}});
  const {data:user,error:authError}=await member.auth.getUser();
  if(authError||!user.user)return reply({error:'Please sign in again.'},401);
  const {data:permitted,error:permError}=await member.rpc('has_admin_permission',{p_permission:'newsletter'});
  if(permError||!permitted)return reply({error:'Newsletter administrator permission required.'},403);
  const input=await req.json();
  const key=Deno.env.get('RESEND_NEWSLETTER_API_KEY');
  if(input.action==='status')return reply({ready:!!key});
  if(!key)return reply({error:'Newsletter email sending is not configured yet.'},503);
  const id=String(input.newsletter_id||'');
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id))return reply({error:'Invalid newsletter identifier.'},400);
  if(input.action==='publish'){
   let issue;try{issue=validateIssue(input.newsletter)}catch(e){return reply({error:e.message},400)}
   const {error}=await member.from('newsletters').insert({id,...issue});
   if(error){
    if(error.code!=='23505')return reply({error:'Newsletter could not be published.'},400);
    const {data:existing}=await member.from('newsletters').select('title,body,issue_date,pdf_url').eq('id',id).single();
    if(!existing||Object.keys(issue).some(k=>existing[k]!==issue[k]))return reply({error:'This publish request no longer matches. Reload and try again.'},409);
   }
  }else if(input.action!=='retry')return reply({error:'Unknown action.'},400);
  const admin=createClient(url,service,{auth:{persistSession:false}});
  // Each immutable batch has its own idempotency key. Concurrent requests claim different batches.
  const deadline=Date.now()+75000;
  for(let n=0;n<20 && Date.now()<deadline;n++){
   const {data:jobs,error:claimError}=await admin.rpc('claim_newsletter_email_batch',{p_newsletter_id:id});
   if(claimError)throw Error('Email queue is unavailable.');
   if(!jobs?.length)break;
   const job=jobs[0];
   try{
    const response=await fetch('https://api.resend.com/emails/batch',{
     method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json','Idempotency-Key':'newsletter-batch/'+job.id},
     body:JSON.stringify(job.recipients.map((r:any)=>emailFor(job,r.email))),signal:AbortSignal.timeout(20000)
    });
    const result=await response.json();
    if(!response.ok)throw Error('Email provider returned '+response.status+'. Retry pending emails after checking Resend.');
    if(!Array.isArray(result.data)||result.data.length!==job.recipients.length)throw Error('Email provider response needs review.');
    const {error:saveError}=await admin.from('newsletter_email_batches').update({status:'sent',sent_at:new Date().toISOString(),provider_ids:result.data,claimed_at:null}).eq('id',job.id).eq('status','sending');
    if(saveError)throw Error('Email acceptance could not be recorded.');
   }catch(e){
    await admin.from('newsletter_email_batches').update({status:'failed',last_error:String(e.message).slice(0,300),claimed_at:null}).eq('id',job.id).eq('status','sending');
    break;
   }
   await new Promise(resolve=>setTimeout(resolve,650));
  }
  const {data:statuses,error:statusError}=await member.rpc('newsletter_email_status');
  if(statusError)throw Error('Newsletter published, but email status is unavailable.');
  return reply({published:true,newsletter_id:id,status:(statuses||[]).find((s:any)=>s.newsletter_id===id)||{queued:0,sent:0,pending:0,failed:0,review:0}});
 }catch(e){return reply({error:String(e.message||'Request failed.').slice(0,300)},500)}
});
