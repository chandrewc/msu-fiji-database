import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
const html=readFileSync(new URL('../../index.html',import.meta.url),'utf8');
const helpers=html.slice(html.indexOf("const ANNOUNCEMENT_BUCKET="),html.indexOf('function renderManagedAnnouncements'));
const handler=html.slice(html.indexOf("$('announcementform').onsubmit="),html.indexOf("\n};",html.indexOf("$('announcementform').onsubmit="))+3);
function harness({uploadFailure=0,insertFailure=false}={}){
 const calls={uploads:[],removes:[],inserts:[],messages:[],revoked:[]};
 const elements={};
 const elem=(tag,text)=>({tag,text,children:[],classList:{add(){}},append(...children){this.children.push(...children)},replaceChildren(...children){this.children=children}});
 for(const id of ['announcementform','announcement-image-files','announcement-image-previews','announcement-upload-status','announcement-image-description'])elements[id]=elem('div');
 const submit={disabled:false},form=elements.announcementform;form.querySelector=()=>submit;form.elements={title:{value:'A chapter update'},body:{value:'The full text'}};form.reset=()=>{calls.reset=true};elements['announcement-image-description'].value='Chapter dinner';
 const storage={upload:async(path,file,options)=>{calls.uploads.push({path,file,options});return {error:calls.uploads.length===uploadFailure?Error('Upload failed'):null}},remove:async(paths)=>{calls.removes.push([...paths]);return {error:null}},createSignedUrl:async path=>({data:{signedUrl:'https://storage.example/'+path}})};
 const context=vm.createContext({console,Map,Date,Error,Object,Image:class{async decode(){}},URL:{createObjectURL:()=> 'blob:preview',revokeObjectURL:u=>calls.revoked.push(u)},crypto:{randomUUID:()=> '11111111-1111-4111-8111-'+String(calls.uploads.length).padStart(12,'0')},$:id=>elements[id],elem,db:{storage:{from:bucket=>{assert.equal(bucket,'brother-announcements');return storage}},from:table=>{assert.equal(table,'announcements');return {insert:row=>{calls.inserts.push(row);return {select:async()=>({data:insertFailure?null:[{id:'new'}],error:insertFailure?Error('Insert failed'):null})}}}}},current:{user_id:'owner'},canAdmin:()=>true,msg:m=>calls.messages.push(m),loadNews:async()=>{calls.reloaded=true}});
 vm.runInContext(helpers+'\n'+handler,context);
 return {calls,elements,form,context,run:code=>vm.runInContext(code,context),submit:()=>form.onsubmit({preventDefault(){},target:form})};
}
test('type, size and total count validation',()=>{
 const h=harness();for(const code of ["validateAnnouncementImages([{type:'image/svg+xml',size:100}])","validateAnnouncementImages([{type:'image/png',size:5242881}])","validateAnnouncementImages([{type:'image/png',size:0}])","validateAnnouncementImages(Array(7).fill({type:'image/png',size:100}))"]){assert.throws(()=>h.run(code));}
 h.run("validateAnnouncementImages([{type:'image/jpeg',size:5242880},{type:'image/webp',size:100}])");
});
test('publishes attachment paths and description after successful uploads',async()=>{
 const h=harness();h.run("announcementDraftImages=[{file:{type:'image/png',size:100},url:'blob:one'},{file:{type:'image/jpeg',size:100},url:'blob:two'}]");await h.submit();assert.equal(h.calls.uploads.length,2);assert.equal(h.calls.inserts[0].image_paths.length,2);assert.equal(h.calls.inserts[0].image_description,'Chapter dinner');assert.equal(h.calls.uploads[0].options.upsert,false);assert.equal(h.calls.reset,true);assert.equal(h.calls.reloaded,true);assert.equal(h.calls.revoked.length,2);assert.equal(h.run('announcementDraftImages.length'),0);
});
test('partial upload failure removes only uploaded files and retains draft',async()=>{
 const h=harness({uploadFailure:2});h.run("announcementDraftImages=[{file:{type:'image/png',size:100},url:'blob:one'},{file:{type:'image/jpeg',size:100},url:'blob:two'}]");await h.submit();assert.equal(h.calls.inserts.length,0);assert.equal(h.calls.removes[0].length,1);assert.equal(h.run('announcementDraftImages.length'),2);assert.equal(h.calls.reset,undefined);assert.equal(h.run('announcementImagesBusy'),false);
});
test('database failure cleans uploaded images without losing draft',async()=>{
 const h=harness({insertFailure:true});h.run("announcementDraftImages=[{file:{type:'image/webp',size:100},url:'blob:one'}]");await h.submit();assert.equal(h.calls.removes[0].length,1);assert.equal(h.run('announcementDraftImages.length'),1);assert.equal(h.calls.reset,undefined);
});
test('text-only announcements remain supported',async()=>{const h=harness();await h.submit();assert.equal(h.calls.uploads.length,0);assert.equal(h.calls.inserts[0].image_paths.length,0);assert.equal(h.calls.reset,true)});
test('gallery limits homepage to one image and archive includes every attachment',()=>{
 const h=harness();h.run("var item={title:'Dinner',image_paths:['one.png','two.png'],image_description:'Chapter dinner'};var compact=announcementGallery(item,true),full=announcementGallery(item)");assert.equal(h.run('compact.children.length'),1);assert.equal(h.run('full.children.length'),2);assert.equal(h.run('full.children[0].children[0].alt'),'Chapter dinner');
 assert.match(html,/announcementCard\(recent,n,true\)/);assert.match(html,/announcementCard\(al,n\)/);assert.match(html,/removeAnnouncementFiles\(issue.image_paths\)/);
});
test('all inline scripts parse',()=>{for(const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)){if(match[1].trim())new vm.SourceTextModule(match[1]);}});
