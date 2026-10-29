import { createClient } from "npm:@supabase/supabase-js@2";
const allowedOrigins=new Set(["https://brothers.msufiji.com","https://chandrewc.github.io"]);
Deno.serve(async(req)=>{
 const origin=req.headers.get("Origin")||"";
 const cors={"Access-Control-Allow-Origin":allowedOrigins.has(origin)?origin:"https://brothers.msufiji.com","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin"};
 const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
 if(req.method==="OPTIONS")return new Response(null,{headers:cors});
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 try{
 const url=Deno.env.get("SUPABASE_URL")!,publicKey=Deno.env.get("SUPABASE_ANON_KEY")!,serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const bearer=req.headers.get("Authorization")||"";
 if(!bearer.startsWith("Bearer "))return reply({error:"Sign in required"},401);
 const userClient=createClient(url,publicKey,{global:{headers:{Authorization:bearer}}});
 const {data:{user},error:authError}=await userClient.auth.getUser();
 if(authError||!user)return reply({error:"Invalid session"},401);
 const admin=createClient(url,serviceKey);
 const {data:caller,error:memberError}=await admin.from("members").select("role,approved").eq("user_id",user.id).single();
 if(memberError||caller?.role!=="admin"||caller.approved!==true)return reply({error:"Administrator access required"},403);
 const input=await req.json();
 const email=String(input.email||"").trim().toLowerCase();
 const name=String(input.full_name||"").trim();
 const username=String(input.username||"").trim().toLowerCase();
 const phone=String(input.phone_contact||"").trim();
 const memberType=input.member_type==="active"?"active":"graduate";
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||name.length<2||name.length>120||!/^[a-z0-9_]{3,32}$/.test(username)||phone.replace(/\D/g,"").length<10||phone.length>30||!/^[+0-9 ()-]+$/.test(phone))return reply({error:"Enter a valid name, username, email and phone number"},400);
 const {data:invited,error:inviteError}=await admin.auth.admin.inviteUserByEmail(email,{redirectTo:"https://brothers.msufiji.com/",data:{full_name:name,requested_username:username,requested_member_type:memberType,phone_contact:phone}});
 if(inviteError)return reply({error:inviteError.message},400);
 if(!invited.user)return reply({error:"No user returned from invitation"},500);
 const {error:updateError}=await admin.from("members").update({approved:true,rejected:false}).eq("user_id",invited.user.id);
 if(updateError)return reply({error:"Invitation sent, but automatic approval failed: "+updateError.message},500);
 return reply({success:true,message:"Invitation sent. Brother is approved and can set a password from the email."});
 }catch(e){return reply({error:e instanceof Error?e.message:"Unexpected error"},500)}
});