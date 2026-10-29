import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {stripTypeScriptTypes} from 'node:module';
import vm from 'node:vm';
const root=new URL('../functions/publish-newsletter/',import.meta.url);
const helpers=stripTypeScriptTypes(await readFile(new URL('email.ts',root),'utf8'));
const {emailFor,validateIssue}=await import('data:text/javascript;base64,'+Buffer.from(helpers).toString('base64'));
const source=stripTypeScriptTypes((await readFile(new URL('index.ts',root),'utf8')).split('\n').filter(l=>!l.startsWith('import ')).join('\n'));
const sample={title:'Chapter Update',body:'Hello brothers!',issue_date:'2026-10-28',pdf_url:'https://example.com/news.pdf'};
test('validates newsletter details and blocks unsafe PDF links/header injection',()=>{
 assert.equal(validateIssue(sample).title,sample.title);
 for(const bad of [{...sample,pdf_url:'javascript:alert(1)'},{...sample,title:'Bad\r\nBcc: victim'},{...sample,issue_date:'2026-02-30'}])assert.throws(()=>validateIssue(bad));
});
test('renders safe separate-recipient emails with plain text and preference links',()=>{
 const email=emailFor({...sample,title:'<script>bad</script>',body:'<img src=x onerror=bad>\nHello'},'brother@example.com');
 assert.deepEqual(email.to,['brother@example.com']);
 assert.ok(!email.html.includes('<script>'));assert.ok(email.html.includes('&lt;img'));
 assert.ok(email.text.includes('Manage newsletter emails: https://brothers.msufiji.com/#newsletters'));
 assert.ok(!('bcc' in email));
});
function handler({permitted=true,key='secret',auth=true,job=null,providerOk=true}={}){
 let serve,fetches=[],updates=[],inserts=[];
 const client={auth:{getUser:async()=>({data:{user:auth?{id:'admin'}:null},error:null})},rpc:async(name)=>{
  if(name==='has_admin_permission')return {data:permitted};
  if(name==='claim_newsletter_email_batch'){const found=job;job=null;return {data:found?[found]:[]}};
  return {data:[]};
 },from:()=>({insert:async data=>{inserts.push(data);return {error:null}},update:data=>{updates.push(data);const q={eq:()=>q,then:r=>r({error:null})};return q}})};
 vm.runInNewContext(source,{Deno:{env:{get:n=>n==='RESEND_NEWSLETTER_API_KEY'?key:'stub'},serve:f=>serve=f},createClient:()=>client,emailFor,validateIssue,Request,Response,AbortSignal,URL,Date,setTimeout:f=>{f()},fetch:async(url,options)=>{fetches.push({url,options});return new Response(JSON.stringify(providerOk?{data:[{id:'email-test'}]}:{message:'failure'}),{status:providerOk?200:429})}});
 return {run:serve,fetches,updates,inserts};
}
const body={action:'publish',newsletter_id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',newsletter:sample};
const request=(payload=body,headers={Authorization:'Bearer test'})=>new Request('https://example.test',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(payload)});
test('rejects anonymous callers and unauthorized members before publishing',async()=>{
 for(const config of [{auth:false},{permitted:false}]){const h=handler(config);assert.ok((await h.run(request())).status>=400);assert.equal(h.inserts.length,0);assert.equal(h.fetches.length,0)}
});
test('unconfigured sending cannot publish an issue with a false success message',async()=>{
 const h=handler({key:''});assert.equal((await h.run(request())).status,503);assert.equal(h.inserts.length,0);
});
test('successful send uses batch idempotency and records provider acceptance',async()=>{
 const h=handler({job:{...sample,id:'batch-test',recipients:[{email:'recipient@example.com'}]}});
 assert.equal((await h.run(request())).status,200);assert.equal(h.fetches.length,1);
 assert.equal(h.fetches[0].options.headers['Idempotency-Key'],'newsletter-batch/batch-test');
 assert.equal(h.updates[0].status,'sent');assert.equal(JSON.parse(h.fetches[0].options.body)[0].to.length,1);
});
test('provider failure preserves an explicit retryable batch',async()=>{
 const h=handler({job:{...sample,id:'batch-test',recipients:[{email:'recipient@example.com'}]},providerOk:false});
 await h.run(request());assert.equal(h.updates[0].status,'failed');assert.equal(h.fetches.length,1);
});

test('connection check uses only Resend test inbox and never publishes',async()=>{
 const h=handler();const response=await h.run(request({action:'test'}));
 assert.equal(response.status,200);assert.equal(h.inserts.length,0);
 assert.deepEqual(JSON.parse(h.fetches[0].options.body)[0].to,['delivered@resend.dev']);
});
