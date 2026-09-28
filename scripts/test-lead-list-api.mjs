// Local-only API smoke test. Requires the disposable demo fixture; reset after use.
import assert from 'node:assert/strict';
import { createHmac, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import pg from 'pg';
import { leadQuery } from '../app/leads.mjs';

const root=fileURLToPath(new URL('../',import.meta.url));
assert.match(await readFile(path.join(root,'supabase/config.toml'),'utf8'),/^project_id = "project_saas_local"$/m);
const cli=path.join(root,'node_modules/supabase/dist/supabase.js');
const result=spawnSync(process.execPath,[cli,'status','--output','json'],{cwd:root,encoding:'utf8',windowsHide:true});
assert.equal(result.status,0,'Supabase Local must be running');
const status=JSON.parse(result.stdout);
assert.equal(status.API_URL,'http://127.0.0.1:54321');
assert.equal(new URL(status.DB_URL).host,'127.0.0.1:54322');
const db=new pg.Client({connectionString:status.DB_URL});await db.connect();
const people=(await db.query(`SELECT u.id,u.auth_user_id,u.company_id,r.code FROM public.users u JOIN public.roles r
  ON r.company_id=u.company_id AND r.id=u.role_id WHERE r.code IN ('owner','sales') ORDER BY r.code`)).rows;
assert.equal(people.length,2,'Run only with the two-user local demo fixture');
const owner=people.find(user=>user.code==='owner'),sales=people.find(user=>user.code==='sales');
assert.equal(owner.company_id,sales.company_id);
const company=owner.company_id;
assert.equal((await db.query('SELECT count(*)::int AS n FROM public.companies')).rows[0].n,1);
const encode=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
const token=user=>{const body=`${encode({alg:'HS256',typ:'JWT'})}.${encode({sub:user.auth_user_id,role:'authenticated',iss:'supabase-demo',exp:Math.floor(Date.now()/1000)+3600})}`;return `${body}.${createHmac('sha256',status.JWT_SECRET).update(body).digest('base64url')}`;};
async function api(user,url,{method='GET',body}={}){
  const response=await fetch(`${status.API_URL}${url}`,{method,headers:{apikey:status.ANON_KEY,Authorization:`Bearer ${token(user)}`,'Content-Type':'application/json',Prefer:'return=representation'},body:body===undefined?undefined:JSON.stringify(body)});
  const text=await response.text();if(!response.ok)throw new Error(`Local API ${method} ${url.split('?')[0]} returned ${response.status}: ${text.slice(0,250)}`);
  return text?JSON.parse(text):null;
}
try{
  await api(owner,'/rest/v1/rpc/add_lead_option',{method:'POST',body:{p_company:company,p_kind:'source',p_label:'Website'}});
  const examples=[['Hoàng Nguyễn','Mới','090 123 4567'],['Nguyen Van Hoang','Đã hẹn gặp','091 222 3333'],['Trần Hoàng','Đã báo giá','092 333 4444'],['Không khớp','Thành công','093 444 5555']];
  const ids=[];
  for(const [customer_name,leadStatus,phone] of examples){const id=randomUUID();ids.push(id);await api(owner,'/rest/v1/leads',{method:'POST',body:{id,company_id:company,customer_name,status:leadStatus,phone,source:'Website',building_type:'Nhà đất'}});}
  const names=await api(owner,leadQuery({companyId:company,search:'hoàng'}));
  assert.deepEqual(new Set(names.map(row=>row.id)),new Set(ids.slice(0,3)));
  const phone=await api(owner,leadQuery({companyId:company,search:'0901234567'}));
  assert.deepEqual(phone.map(row=>row.id),[ids[0]]);
  const combined=await api(owner,leadQuery({companyId:company,tab:'meeting',source:'Website',buildingType:'Nhà đất'}));
  assert.deepEqual(combined.map(row=>row.id),[ids[1]]);
  await api(owner,'/rest/v1/rpc/set_lead_assignees',{method:'POST',body:{p_company:company,p_lead:ids[0],p_users:[sales.id]}});
  const filtered=await api(owner,leadQuery({companyId:company,assignee:sales.id}));
  assert.deepEqual(filtered.map(row=>row.id),[ids[0]]);
  const scoped=await api(sales,leadQuery({companyId:company}));
  assert.deepEqual(scoped.map(row=>row.id),[ids[0]]);
  const bulk=Array.from({length:52},(_,i)=>({id:randomUUID(),company_id:company,customer_name:`Lead phân trang ${i}`}));
  await api(owner,'/rest/v1/leads',{method:'POST',body:bulk});
  assert.equal((await api(owner,leadQuery({companyId:company,page:1,pageSize:50}))).length,51);
  assert.equal((await api(owner,leadQuery({companyId:company,page:2,pageSize:50}))).length,9);
  console.log('PASS local Lead API: accent/phone search, combined filters, assignee filter, RLS scope and 50-row pagination.');
}finally{await db.end();}
