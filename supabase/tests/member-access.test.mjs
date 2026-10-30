import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const html=await readFile(new URL('../../index.html',import.meta.url),'utf8');
const source=html.slice(html.indexOf('async function loadManaged(){'),html.indexOf("$('manage-member').onchange="));
function setup({role='admin',allowed=true,inactive=false,confirmed=true,error=null}={}){
 const elements=new Map();
 const $=id=>{if(!elements.has(id))elements.set(id,{value:'',hidden:false,disabled:false,textContent:'',options:[],replaceChildren(...v){this.options=v},add(v){this.options.push(v)}});return elements.get(id)};
 $('manage-access-filter').value='enabled';$('manage-member').value='target';
 const target={user_id:'target',full_name:'Test Brother',role:'member',approved:!inactive,deactivated_at:inactive?'2026-10-30':null};
 const queries=[],rpcCalls=[],messages=[],refreshes=[];
 const chain={select(){return this},eq(...args){queries.push(['eq',...args]);return this},not(...args){queries.push(['not',...args]);return this},or(...args){queries.push(['or',...args]);return this},async order(){return {data:[target],error:null}}};
 const context={$,managedBrothers:[target],current:{user_id:'actor',role},canAdmin:()=>allowed,isAdmin:role==='admin'||role==='super_admin',db:{from:()=>chain,rpc:async(name,args)=>{rpcCalls.push({name,args});return {error}}},Option:class{constructor(text,value){this.text=text;this.value=value}},confirm:()=>confirmed,msg:m=>messages.push(m),refreshDirectory:async()=>refreshes.push('directory'),loadPermissionMembers:async()=>refreshes.push('permissions')};
 vm.createContext(context);vm.runInContext(source,context);
 return {context,$,target,queries,rpcCalls,messages,refreshes};
}
test('page script compiles and exposes reversible access controls',()=>{
 const script=html.match(/<script type="module">([\s\S]*?)<\/script>/)[1].replace(/^import .*;$/m,'');new vm.Script(script);
 assert.match(html,/id="manage-access-filter"/);assert.match(html,/id="manage-access-toggle"/);
 assert.ok(html.indexOf('if(me.deactivated_at)')<html.indexOf('if(me.registration_complete===false'));
 assert.match(html,/registration_complete',true\)\.is\('deactivated_at',null\)/);
});
test('protect self, Super Administrator and full admins from ordinary administrators',()=>{
 const h=setup();assert.equal(h.context.canChangeBrotherAccess(h.target),true);
 for(const b of [{...h.target,user_id:'actor'},{...h.target,role:'super_admin'},{...h.target,role:'admin'}])assert.equal(h.context.canChangeBrotherAccess(b),false);
 const superAdmin=setup({role:'super_admin'});assert.equal(superAdmin.context.canChangeBrotherAccess({...h.target,role:'admin'}),true);
 assert.equal(setup({allowed:false}).context.canChangeBrotherAccess(h.target),false);
});
test('cancelled confirmation never changes access',async()=>{const h=setup({confirmed:false});await h.$('manage-access-toggle').onclick();assert.equal(h.rpcCalls.length,0)});
test('deactivation calls only guarded RPC and refreshes directory',async()=>{const h=setup();await h.$('manage-access-toggle').onclick();assert.equal(h.rpcCalls[0].name,'admin_set_brother_access');assert.equal(h.rpcCalls[0].args.p_user_id,'target');assert.equal(h.rpcCalls[0].args.p_enabled,false);assert.ok(h.refreshes.includes('directory'));assert.match(h.messages[0],/deactivated/)});
test('reactivation restores existing account through same RPC',async()=>{const h=setup({inactive:true});h.context.showBrotherAccess(h.target);assert.equal(h.$('manage-access-toggle').textContent,'Reactivate brother');await h.$('manage-access-toggle').onclick();assert.equal(h.rpcCalls[0].args.p_enabled,true);assert.match(h.messages[0],/reactivated/)});
test('failure stays visible and permits retry',async()=>{const h=setup({error:{message:'Access denied'}});await h.$('manage-access-toggle').onclick();assert.match(h.$('manage-access-message').textContent,/Access denied/);assert.equal(h.$('manage-access-toggle').disabled,false);assert.equal(h.refreshes.length,0)});
test('account filters include deactivated accounts for restoration',async()=>{for(const [filter,method] of [['enabled','eq'],['deactivated','not'],['all','or']]){const h=setup();h.$('manage-access-filter').value=filter;await h.context.loadManaged();assert.equal(h.queries[0][0],method);assert.equal(h.$('manage-access').hidden,true)}});
