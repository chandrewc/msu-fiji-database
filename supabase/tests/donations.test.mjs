import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import { parseDonation, checkoutParameters, isTestKey } from '../functions/_shared/donations.ts';

const id='310f2c02-6386-4d28-8b15-6af93763f855';
const memberId='c6006951-8894-46f1-a241-6b1552147315';
test('validates exact cents, limits, purpose and request IDs',()=>{
  assert.equal(parseDonation({amount:'25.01',purpose:' Alumni ',request_id:id}).cents,2501);
  assert.equal(parseDonation({amount:'100000',purpose:'',request_id:id}).cents,10000000);
  for(const amount of ['0','-1','1.001','1e3','NaN','100001','01',''])assert.throws(()=>parseDonation({amount,purpose:'',request_id:id}));
  assert.throws(()=>parseDonation({amount:'25',purpose:'x'.repeat(501),request_id:id}));
  assert.throws(()=>parseDonation({amount:'25',purpose:'',request_id:'arbitrary'}));
});
test('checkout is a one-time donation with no tax, invoice or saved-card charging',()=>{
  const params=checkoutParameters({id,amount_cents:2500},memberId);
  assert.equal(params.mode,'payment');assert.equal(params.submit_type,'donate');
  assert.equal(params.automatic_tax.enabled,false);
  assert.equal(params.line_items[0].price_data.unit_amount,2500);
  assert.equal(params.line_items[0].quantity,1);
  assert.equal(params.payment_method_types,undefined);
  assert.equal(params.subscription_data,undefined);
  assert.equal(params.invoice_creation,undefined);
  assert.ok(params.success_url.startsWith('https://brothers.msufiji.com/'));
  assert.equal(params.metadata.member_id,memberId);
  assert.equal(isTestKey('sk_live_example'),false);assert.equal(isTestKey('rk_test_example'),true);
});

async function loadHandler(file,overrides={}){
  let handler;const calls=[];
  const donation={id,member_id:memberId,amount_cents:2500,currency:'usd',livemode:false};
  class FakeStripe{
    constructor(){this.webhooks={constructEventAsync:async()=>{if(overrides.badSignature)throw Error('Bad signature');return overrides.event;}};this.checkout={sessions:{list:async()=>({data:[{id:'cs_test_fixture',metadata:{donation_id:id,member_id:memberId}}]})}};}
    static createSubtleCryptoProvider(){return {};}
  }
  const db={from:()=>({select(){return this;},eq(){return this;},maybeSingle:async()=>({data:donation,error:null})}),rpc:async(name,args)=>{calls.push({name,args});return {data:'processed',error:null};}};
  const context={Request,Response,Set,Error,Stripe:FakeStripe,createClient:()=>db,isTestKey,Deno:{env:{get:name=>({STRIPE_DONATIONS_TEST_KEY:'sk_test_fixture',STRIPE_DONATIONS_TEST_WEBHOOK_SECRET:'whsec_fixture',SUPABASE_URL:'https://example.test',SUPABASE_SERVICE_ROLE_KEY:'fixture'})[name]},serve:fn=>{handler=fn;}}};
  vm.createContext(context);
  const source=(await fs.readFile(new URL(file,import.meta.url),'utf8')).replace(/^import .*;\n/gm,'');
  vm.runInContext(source,context);
  return {handler,calls,donation};
}
const session=(payment_status='paid')=>({id:'cs_test_fixture',metadata:{donation_id:id,member_id:memberId},payment_status,payment_intent:'pi_test_fixture',amount_total:2500,currency:'usd',livemode:false});
const request=()=>new Request('https://example.test/webhook',{method:'POST',body:'signed-event',headers:{'stripe-signature':'fixture'}});
test('webhook rejects bad signatures without database writes',async()=>{
 const {handler,calls}=await loadHandler('../functions/stripe-donation-webhook/index.ts',{badSignature:true});assert.equal((await handler(request())).status,400);assert.equal(calls.length,0);
});
test('completed but unpaid sessions are not recorded as paid',async()=>{
 const {handler,calls}=await loadHandler('../functions/stripe-donation-webhook/index.ts',{event:{id:'evt_unpaid',type:'checkout.session.completed',livemode:false,data:{object:session('unpaid')}}});assert.equal((await handler(request())).status,200);assert.equal(calls.length,0);
});
test('signed delayed success records only a matching session',async()=>{
 const {handler,calls}=await loadHandler('../functions/stripe-donation-webhook/index.ts',{event:{id:'evt_paid',type:'checkout.session.async_payment_succeeded',livemode:false,data:{object:session()}}});assert.equal((await handler(request())).status,200);assert.equal(calls[0].args.p_status,'paid');assert.equal(calls[0].args.p_session_id,'cs_test_fixture');
});
test('webhook rejects mismatched totals and live events',async()=>{
 const object=session();object.amount_total=9999;
 const {handler,calls}=await loadHandler('../functions/stripe-donation-webhook/index.ts',{event:{id:'evt_bad',type:'checkout.session.completed',livemode:false,data:{object}}});assert.equal((await handler(request())).status,400);assert.equal(calls.length,0);
 const live=await loadHandler('../functions/stripe-donation-webhook/index.ts',{event:{livemode:true}});assert.equal((await live.handler(request())).status,400);
});
test('refund resolves its Checkout session even when it arrives before completion',async()=>{
 const {handler,calls}=await loadHandler('../functions/stripe-donation-webhook/index.ts',{event:{id:'evt_refund',type:'charge.refunded',livemode:false,data:{object:{payment_intent:'pi_test_fixture',amount:2500,amount_refunded:2500,currency:'usd',livemode:false}}}});assert.equal((await handler(request())).status,200);assert.equal(calls[0].args.p_session_id,'cs_test_fixture');assert.equal(calls[0].args.p_status,'refunded');
});
