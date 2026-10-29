export const NETWORK='https://brothers.msufiji.com';
export function escapeHtml(value: string): string {
 return value.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
}
export function validateIssue(value: any) {
 if(!value || typeof value!=='object')throw Error('Enter newsletter details.');
 const title=String(value.title||'').trim(), body=String(value.body||'').trim();
 const date=String(value.issue_date||''), pdf=value.pdf_url?String(value.pdf_url).trim():null;
 if(!title||title.length>200||/[\r\n]/.test(title))throw Error('Enter a title of 200 characters or fewer.');
 if(body.length>50000)throw Error('Newsletter text is too long.');
 if(!/^\d{4}-\d{2}-\d{2}$/.test(date)||!Number.isFinite(Date.parse(date))||new Date(date).toISOString().slice(0,10)!==date)throw Error('Enter a valid issue date.');
 if(pdf){let u;try{u=new URL(pdf)}catch{throw Error('Use an HTTPS PDF URL.')}if(u.protocol!=='https:'||u.username||u.password||pdf.length>2000)throw Error('Use an HTTPS PDF URL.');}
 return {title,body,issue_date:date,pdf_url:pdf};
}
export function emailFor(batch: any, email: string) {
 const title=escapeHtml(batch.title),body=escapeHtml(batch.body).replace(/\n/g,'<br>');
 const pdf=batch.pdf_url && String(batch.pdf_url).startsWith('https://')?String(batch.pdf_url):null;
 const link=NETWORK+'/#newsletters';
 return {
  from:'Sigma Mu Chapter <notifications@msufiji.com>',to:[email],
  subject:'Sigma Mu Newsletter: '+String(batch.title).replace(/[\r\n]/g,' ').slice(0,200),
  text:batch.title+'\n'+batch.issue_date+'\n\n'+batch.body+(pdf?'\n\nRead the PDF: '+pdf:'')+'\n\nView newsletters: '+link+'\n\nYou received this as an approved Sigma Mu brother. Manage newsletter emails: '+link,
  html:'<!doctype html><html><body style="margin:0;background:#f4f2f7;font-family:Arial,sans-serif;color:#25212c"><div style="max-width:600px;margin:24px auto;padding:28px;background:white;border-top:5px solid #50326c"><p style="color:#50326c;font-size:13px;letter-spacing:2px">PHI GAMMA DELTA · SIGMA MU</p><h1 style="font-size:26px;line-height:1.25">'+title+'</h1><p style="color:#746b7d">'+escapeHtml(String(batch.issue_date))+'</p><div style="font-size:16px;line-height:1.65;overflow-wrap:anywhere">'+body+'</div>'+(pdf?'<p><a style="color:#50326c" href="'+escapeHtml(pdf)+'">Read the full newsletter PDF</a></p>':'')+'<p style="margin:28px 0"><a href="'+link+'" style="display:inline-block;background:#50326c;color:white;padding:13px 18px;border-radius:6px;text-decoration:none">View Chapter Newsletters</a></p><p style="border-top:1px solid #e9e4ed;padding-top:20px;font-size:12px;line-height:1.5;color:#746b7d">You received this as an approved Sigma Mu brother.<br><a href="'+link+'">Manage newsletter emails</a> in the Brother Network.</p></div></body></html>'
 };
}
