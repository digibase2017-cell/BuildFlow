import {randomUUID} from 'node:crypto';

// Real Auth JWTs exercise PostgREST grants, RLS and SECURITY DEFINER RPC guards.
export async function testLeadDetailApi({db,owner,company,admin,foreign,identity,http,check}) {
  const sale=await identity('lead-care-sale');
  const viewer=await identity('lead-care-viewer');
  const marketing=await identity('lead-care-marketing');
  for(const [user,department] of [[sale,'Sales'],[viewer,'Sales'],[marketing,'Marketing']]){
    await db.query(`INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department)
      SELECT $1,$2,$3,id,$4,$5,$6 FROM public.roles WHERE company_id=$2 AND code='sales'`,
      [user.id,company,user.subject,`Detail ${department}`,`${user.id}@example.test`,department]);
  }
  const lead=randomUUID(),activity=randomUUID();
  let r=await http('/rest/v1/leads',{token:admin.token,method:'POST',prefer:'return=representation',
    body:{id:lead,company_id:company,customer_name:'API detail Lead'}});
  check(r.status===201,'Lead detail API fixture created by authenticated Admin');
  r=await http('/rest/v1/rpc/set_lead_assignees',{token:admin.token,method:'POST',
    body:{p_company:company,p_lead:lead,p_users:[sale.id]}});
  check(r.status===204,'Admin assigns Sale for care API');
  r=await http('/rest/v1/lead_care_activities',{token:sale.token,method:'POST',prefer:'return=representation',
    body:{id:activity,company_id:company,lead_id:lead,content:'  Gọi khách\nHẹn gặp  ',
      created_by:admin.id,created_at:'2000-01-01T00:00:00Z',creator_name_snapshot:'Forged'}});
  check(r.status===201&&r.body[0].created_by===sale.id&&r.body[0].content==='Gọi khách\nHẹn gặp'
    &&r.body[0].creator_name_snapshot==='Detail Sales'
    &&new Date(r.body[0].created_at).getTime()>Date.now()-60000,
  'Care HTTP insert stamps creator, name and server time despite spoofed values');
  r=await http(`/rest/v1/lead_care_activities?company_id=eq.${company}&lead_id=eq.${lead}&select=id`,{token:viewer.token});
  check(r.status===200&&r.body.length===0,'Unassigned Sale cannot read Lead care');
  r=await http('/rest/v1/rpc/get_lead_creator_name',{token:sale.token,method:'POST',
    body:{p_company:company,p_lead:lead}});
  check(r.status===200&&r.body==='admin','Assigned Sale reads Lead creator name without user.view');
  await owner.query("SELECT public.set_user_permission($1,$2,'lead.view.all','allow')",[company,viewer.id]);
  r=await http(`/rest/v1/lead_care_activities?company_id=eq.${company}&lead_id=eq.${lead}&select=id`,{token:viewer.token});
  check(r.status===200&&r.body.length===1,'View-all reads care without assignment');
  r=await http('/rest/v1/lead_care_activities',{token:viewer.token,method:'POST',
    body:{company_id:company,lead_id:lead,content:'No edit scope'}});
  check(r.status===403,'View-all with role edit but without Lead write scope cannot post care');
  r=await http('/rest/v1/rpc/set_lead_assignees',{token:viewer.token,method:'POST',
    body:{p_company:company,p_lead:lead,p_users:[sale.id,viewer.id]}});
  check(r.status===403,'View-all alone cannot assign');
  await owner.query("SELECT public.set_user_permission($1,$2,'lead.assign','allow')",[company,viewer.id]);
  r=await http('/rest/v1/rpc/set_lead_assignees',{token:viewer.token,method:'POST',
    body:{p_company:company,p_lead:lead,p_users:[sale.id,viewer.id]}});
  check(r.status===204,'View-all plus lead.assign adds active Sale');
  r=await http('/rest/v1/rpc/list_lead_assignees',{token:viewer.token,method:'POST',
    body:{p_company:company,p_lead:lead}});
  check(r.status===200&&r.body.length===2,'Assignee RPC returns two same-company names');
  r=await http('/rest/v1/rpc/delete_lead_care_activity',{token:viewer.token,method:'POST',
    body:{p_company:company,p_activity:activity}});
  check(r.status===200&&r.body===false,'Another assigned Sale cannot delete creator care');
  r=await http('/rest/v1/rpc/delete_lead_care_activity',{token:sale.token,method:'POST',
    body:{p_company:company,p_activity:activity}});
  check(r.status===200&&r.body===true,'Creator deletes care in same Vietnam day');
  r=await http('/rest/v1/lead_care_activities',{token:sale.token,method:'POST',prefer:'return=representation',
    body:{id:activity,company_id:company,lead_id:lead,content:'Old care'}});
  check(r.status===201,'Creator can add another care item');
  await db.query("UPDATE public.lead_care_activities SET created_at=clock_timestamp()-interval '1 day' WHERE id=$1",[activity]);
  r=await http('/rest/v1/rpc/delete_lead_care_activity',{token:sale.token,method:'POST',
    body:{p_company:company,p_activity:activity}});
  check(r.status===200&&r.body===false,'Creator cannot delete prior-day care');
  r=await http(`/rest/v1/lead_care_activities?lead_id=eq.${lead}&select=id`,{token:foreign.token});
  check(r.status===200&&r.body.length===0,'Other tenant cannot read care');
  r=await http('/rest/v1/rpc/set_lead_assignees',{token:admin.token,method:'POST',
    body:{p_company:company,p_lead:lead,p_users:[sale.id,marketing.id]}});
  check(r.status===400&&r.body?.code==='23514','Assignment RPC rejects Marketing department');
  r=await http(`/rest/v1/leads?id=eq.${lead}`,{token:admin.token,method:'PATCH',prefer:'return=representation',
    body:{customer_name:'API detail changed',phone:'0912'}});
  check(r.status===200&&r.body.length===1,'Admin updates Lead fields through HTTP');
  r=await http('/rest/v1/rpc/get_lead_history',{token:sale.token,method:'POST',
    body:{p_company:company,p_lead:lead,p_limit:50}});
  check(r.status===200&&r.body.some(x=>x.action_code==='lead.customer_name_changed')
    &&r.body.some(x=>x.action_code==='lead.contact_changed'),
  'Assigned Sale reads grouped Lead History through scoped RPC');
  const quote=randomUUID(),version=randomUUID();
  r=await http('/rest/v1/quotes',{token:admin.token,method:'POST',
    body:{id:quote,company_id:company,lead_id:lead,title:'API quote'}});
  check(r.status===201,'Admin creates Quote document');
  r=await http('/rest/v1/quote_versions',{token:admin.token,method:'POST',
    body:{id:version,company_id:company,quote_id:quote,version_number:1}});
  check(r.status===201,'Direct Quote V1 insert succeeds');
  r=await http('/rest/v1/rpc/clone_quote_version',{token:admin.token,method:'POST',
    body:{p_company:company,p_source:version}});
  check(r.status===200&&r.body,'Quote V2 clone succeeds');
  r=await http('/rest/v1/rpc/get_lead_history',{token:viewer.token,method:'POST',
    body:{p_company:company,p_lead:lead,p_limit:50}});
  check(r.status===200&&r.body.filter(x=>x.action_code==='lead.quote_created').length===1
    &&r.body.filter(x=>x.action_code==='lead.quote_version_created').length===1,
  'View-all reads only approved Quote V1 and V2 History');
  r=await http(`/rest/v1/activity_logs?entity_id=eq.${lead}&select=id`,{token:sale.token});
  check(r.status===200&&r.body.length===0,'General audit table remains hidden from Sale');
  await owner.query("SELECT public.set_user_permission($1,$2,'lead.assign','deny')",[company,viewer.id]);
  r=await http('/rest/v1/rpc/set_lead_assignees',{token:viewer.token,method:'POST',
    body:{p_company:company,p_lead:lead,p_users:[sale.id]}});
  check(r.status===403,'Explicit user deny still blocks assignment');
}
