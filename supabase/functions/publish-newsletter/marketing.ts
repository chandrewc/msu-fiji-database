import {emailFor} from './email.ts';
export class MarketingError extends Error {
 status:number;
 constructor(message:string,status=500){super(message);this.status=status}
}
export function marketingApi(key:string,request=fetch,wait=(ms:number)=>new Promise(r=>setTimeout(r,ms))){
 return async(path:string,method='GET',body?:any,allowMissing=false)=>{
  await wait(600);
  const response=await request('https://api.resend.com'+path,{method,headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},...(body!==undefined?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(15000)});
  if(allowMissing&&response.status===404)return null;
  const result=await response.json();
  if(!response.ok)throw new MarketingError('Resend '+method+' '+path.split('?')[0]+' returned '+response.status+': '+String(result.message||result.name||'Request rejected').slice(0,220),response.status);
  return result;
 };
}
export function broadcastPayload(job:any){
 const email=emailFor(job,'unused@example.com');
 return {name:('Sigma Mu newsletter '+job.id).slice(0,70),segment_id:job.segment_id,from:email.from,subject:email.subject,
  html:email.html.replace('</body>','<p style="text-align:center;font:12px Arial"><a href="{{{RESEND_UNSUBSCRIBE_URL}}}">Unsubscribe from marketing emails</a></p></body>'),
  text:email.text+'\n\nUnsubscribe: {{{RESEND_UNSUBSCRIBE_URL}}}',send:false};
}
// IDs are saved before any send. A lost create response can leave an unused draft, never an extra send.
export async function processMarketingBatch(job:any,api:any,save:any,deadline:number){
 if(job.transport!=='marketing')throw Error('Legacy transactional campaign requires manual review.');
 if(!job.segment_id){const segment=await api('/segments','POST',{name:'Sigma Mu '+job.id});if(!segment?.id)throw Error('No marketing segment returned.');await save({segment_id:segment.id});job.segment_id=segment.id;}
 for(let i=job.sync_cursor||0;i<job.recipients.length;i++){
  if(Date.now()>deadline-20000){await save({status:'pending',claimed_at:null});return false;}
  const email=job.recipients[i].email,encoded=encodeURIComponent(email);
  let contact=await api('/contacts/'+encoded,'GET',undefined,true);
  if(!contact)contact=await api('/contacts','POST',{email});
  // Never opt an existing contact back in, even if the website preference is enabled.
  if(!contact.unsubscribed)await api('/contacts/'+encoded+'/segments/'+job.segment_id,'POST');
  await save({sync_cursor:i+1});job.sync_cursor=i+1;
 }
 if(Date.now()>deadline-20000){await save({status:'pending',claimed_at:null});return false;}
 if(!job.broadcast_id){
  const draft=await api('/broadcasts','POST',broadcastPayload(job));
  if(!draft?.id)throw Error('No marketing broadcast returned.');
  await save({broadcast_id:draft.id});job.broadcast_id=draft.id;
 }
 const broadcast=await api('/broadcasts/'+job.broadcast_id);
 if(broadcast.status==='draft')await api('/broadcasts/'+job.broadcast_id+'/send','POST',{});
 else if(!['queued','sending','sent','scheduled'].includes(broadcast.status))throw Error('Broadcast status '+broadcast.status+' requires review in Resend.');
 await save({status:'sent',sent_at:new Date().toISOString(),claimed_at:null,provider_ids:{broadcast_id:job.broadcast_id}});
 return true;
}
