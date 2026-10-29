import {createClient} from 'npm:@supabase/supabase-js@2.99.1';
import {validateIssue} from './email.ts';
import {marketingApi,processMarketingBatch} from './marketing.ts';
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
  // Temporary website-only publishing: block every send, retry and test path.
  return reply({error:'Automatic newsletter emails are temporarily paused. Publish on the website only.',paused:true},503);
  const input=await req.json();
  const key=Deno.env.get('RESEND_MARKETING_API_KEY');
  if(input.action==='status')return reply({ready:!!key});
  if(!key)return reply({error:'Newsletter email sending is not configured yet.'},503);
  if(input.action==='test'){
   const result=await marketingApi(key)('/broadcasts?limit=1');
   return Array.isArray(result.data)?reply({ready:true,marketing_ready:true}):reply({error:'Marketing access could not be verified.'},502);
  }
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
  const api=marketingApi(key);
  const deadline=Date.now()+75000;
  for(let n=0;n<20 && Date.now()<deadline-20000;n++){
   const {data:jobs,error:claimError}=await admin.rpc('claim_newsletter_email_batch',{p_newsletter_id:id});
   if(claimError)throw Error('Marketing queue is unavailable.');
   if(!jobs?.length)break;
   const job=jobs[0];
   const save=async(changes:any)=>{
    const {data,error}=await admin.from('newsletter_email_batches').update(changes).eq('id',job.id).eq('status','sending').select('id');
    if(error||!data?.length)throw Error('Could not save marketing campaign progress.');
   };
   try{if(!await processMarketingBatch(job,api,save,deadline))break;}
   catch(e){await save({status:'failed',last_error:String(e.message).slice(0,300),claimed_at:null});break;}
  }
  const {data:statuses,error:statusError}=await member.rpc('newsletter_email_status');
  if(statusError)throw Error('Newsletter published, but email status is unavailable.');
  return reply({published:true,newsletter_id:id,status:(statuses||[]).find((s:any)=>s.newsletter_id===id)||{queued:0,sent:0,pending:0,failed:0,review:0}});
 }catch(e){return reply({error:String(e.message||'Request failed.').slice(0,300)},500)}
});
