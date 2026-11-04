import Stripe from 'npm:stripe@23.0.0';
import { createClient } from 'npm:@supabase/supabase-js@2.99.1';
import { parseDonation, donationConfig, liveAccountReady } from '../_shared/donations.ts';
const SITE='https://msufiji.com';
const ORIGINS=new Set([SITE,'https://www.msufiji.com','https://chandrewc.github.io']);
const FUNDS={persistence:'Persistence Fund',parents:'Parents Fund'};
Deno.serve(async req=>{
 const origin=req.headers.get('origin')||'';
 const headers={'Access-Control-Allow-Origin':ORIGINS.has(origin)?origin:SITE,'Access-Control-Allow-Headers':'apikey, authorization, x-client-info, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Cache-Control':'no-store','Vary':'Origin','Content-Type':'application/json'};
 const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({error:'Method not allowed.'},405);
 if(origin&&!ORIGINS.has(origin))return reply({error:'Origin not allowed.'},403);
 // Guests use the public site's key; it is not a secret or an abuse-control token.
 if(req.headers.get('apikey')!=='sb_publishable_57LLRCD8y-LWGQ4yVTL7bg__HF20OFF')return reply({error:'Invalid website API key.'},401);
 try{
  const raw=await req.text();if(raw.length>3000)return reply({error:'Request is too large.'},400);
  let input;try{input=JSON.parse(raw)}catch{return reply({error:'Invalid donation request.'},400)}
  const mode=Deno.env.get('STRIPE_PUBLIC_DONATIONS_MODE')||Deno.env.get('STRIPE_DONATIONS_MODE')||'test';
  const config=donationConfig(name=>Deno.env.get(name),mode);
  const stripe=config.ready?new Stripe(config.key,{apiVersion:'2026-09-30.endive',maxNetworkRetries:2}):null;
  let ready=false;try{ready=!!stripe&&await liveAccountReady(stripe,config)}catch{ready=false}
  if(input?.action==='status')return reply({ready,mode:config.mode});
  if(input?.expected_mode!==config.mode)return reply({error:'Payment mode changed. Refresh this page before continuing.'},409);
  if(!ready)return reply({error:'Online giving is being configured. Please check back soon.'},503);
  if(!Object.hasOwn(FUNDS,input?.fund))return reply({error:'Choose a chapter fund.'},400);
  let parsed;try{parsed=parseDonation(input)}catch(error){return reply({error:error.message},400)}
  const db=createClient(Deno.env.get('SUPABASE_URL'),Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
  const encoder=new TextEncoder();
  const hashKey=await crypto.subtle.importKey('raw',encoder.encode(config.key),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const address=(req.headers.get('x-forwarded-for')||'unknown').split(',')[0].trim();
  const digest=await crypto.subtle.sign('HMAC',hashKey,encoder.encode('public-giving:'+address));
  const fingerprint=Array.from(new Uint8Array(digest)).map(byte=>byte.toString(16).padStart(2,'0')).join('');
  const reserved=await db.rpc('reserve_public_donation',{p_id:parsed.requestId,p_fund:input.fund,p_amount_cents:parsed.cents,p_purpose:parsed.purpose,p_livemode:config.livemode,p_fingerprint:fingerprint});
  if(reserved.error){
   if(reserved.error.message?.includes('donation_rate_limit'))return reply({error:'Too many checkout attempts. Please try again later.'},429);
   if(reserved.error.message?.includes('donation_conflict'))return reply({error:'Start a new donation before continuing.'},409);
   throw Error('Could not reserve donation');
  }
  const donation=reserved.data?.[0];
  if(!donation||donation.member_id!==null||donation.fund!==input.fund||donation.amount_cents!==parsed.cents||donation.purpose!==parsed.purpose||donation.livemode!==config.livemode||donation.status!=='pending')return reply({error:'Start a new donation before continuing.'},409);
  const metadata={donation_id:donation.id,member_id:'public',fund:donation.fund};
  const session=donation.checkout_session_id?await stripe.checkout.sessions.retrieve(donation.checkout_session_id):await stripe.checkout.sessions.create({mode:'payment',submit_type:'donate',integration_identifier:'sigma_mu_public_giving_xprmtvqa',client_reference_id:donation.id,line_items:[{price_data:{currency:'usd',unit_amount:donation.amount_cents,product_data:{name:'Sigma Mu — '+FUNDS[donation.fund]}},quantity:1}],metadata,payment_intent_data:{metadata},success_url:SITE+'/giving.html?checkout_return=1',cancel_url:SITE+'/giving.html?cancelled=1'},{idempotencyKey:'public-donation-'+donation.id});
  if(session.livemode!==config.livemode||session.status!=='open'||session.client_reference_id!==donation.id||session.amount_total!==donation.amount_cents||session.currency!=='usd'||session.metadata?.donation_id!==donation.id||session.metadata?.fund!==donation.fund||session.metadata?.member_id!=='public'||!session.url?.startsWith('https://checkout.stripe.com/'))return reply({error:'Checkout verification failed. Start a new donation.'},409);
  const saved=await db.from('stripe_donations').update({checkout_session_id:session.id}).eq('id',donation.id).is('member_id',null);if(saved.error)throw Error('Could not save checkout');
  return reply({url:session.url,mode:config.mode});
 }catch{return reply({error:'Unable to open secure checkout. Please try again later.'},502)}
});
