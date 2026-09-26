const {chromium}=await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
import {spawn,spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';
const seeded=spawnSync(process.execPath,['scripts/seed-local-demo.mjs','--local-only'],{encoding:'utf8',windowsHide:true});
assert.equal(seeded.status,0,seeded.stderr);
const credentials=Object.fromEntries([...seeded.stdout.matchAll(/(owner|sales): (\S+) \/ (\S+)/g)].map(m=>[m[1],{email:m[2],password:m[3]}]));
const server=spawn(process.execPath,['app/server.mjs'],{windowsHide:true,stdio:'pipe',env:{...process.env,PROJECT_APP_PORT:'4175'}});
const browser=await chromium.launch({channel:'msedge',headless:true});
const page=await browser.newPage({viewport:{width:1536,height:1024}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
try {
 for(let i=0;i<40;i++){try{if((await fetch('http://127.0.0.1:4175')).ok)break;}catch{}await new Promise(r=>setTimeout(r,250));}
 await page.goto('http://127.0.0.1:4175');
 const login=async role=>{await page.getByLabel('Email',{exact:true}).fill(credentials[role].email);await page.getByLabel('Mật khẩu',{exact:true}).fill(credentials[role].password);await page.getByRole('button',{name:'Đăng nhập',exact:true}).click();await page.getByRole('heading',{name:'Danh sách dự án',exact:true}).waitFor();await page.getByText('Tổng 2 dự án',{exact:true}).waitFor();};
 await login('owner');assert.equal(await page.locator('tbody tr').count(),2);
 await mkdir('artifacts',{recursive:true});
 for(const [width,height] of [[1536,1024],[1366,768],[1280,800]]){
  await page.setViewportSize({width,height});await page.screenshot({path:`artifacts/build-flow-${width}.png`,fullPage:true});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'No page-wide horizontal scrolling');
  assert.equal(await page.locator('thead th').count(),11);
 }
 await page.getByRole('button',{name:'Tạo dự án',exact:false}).click();await page.getByRole('dialog').waitFor();
 await page.locator('select[name=lead]').selectOption({index:1});await page.getByLabel('Tên dự án',{exact:true}).fill('Dự án kiểm thử giao diện');await page.getByRole('button',{name:'Tạo dự án',exact:true}).click();await page.getByText('Tổng 3 dự án',{exact:true}).waitFor();
 await page.getByLabel('Tìm dự án',{exact:true}).fill('kiểm thử');await page.getByText('Tổng 1 dự án',{exact:true}).waitFor();
 await page.locator('tbody summary').click();await page.getByRole('button',{name:'Ẩn dự án',exact:true}).click();await page.locator('#confirm').click();await page.getByText('Tổng 0 dự án',{exact:true}).waitFor();
 await page.getByRole('button',{name:'Đã ẩn',exact:true}).click();await page.getByText('Tổng 1 dự án',{exact:true}).waitFor();await page.locator('tbody summary').click();await page.getByRole('button',{name:'Bỏ ẩn dự án',exact:true}).click();await page.locator('#confirm').click();await page.getByText('Tổng 0 dự án',{exact:true}).waitFor();
 // Exercise real pagination beyond 50 rows using the signed-in Owner JWT, not postgres.
 await page.evaluate(async()=>{
   const config=await (await fetch('/config')).json(),session=JSON.parse(sessionStorage.getItem('project-saas-session'));
   const headers={apikey:config.anonKey,Authorization:'Bearer '+session.access_token,'Content-Type':'application/json'};
   const leads=await (await fetch(config.apiUrl+'/rest/v1/leads?select=id,company_id&limit=1',{headers})).json();
   for(let i=0;i<48;i++){
     const response=await fetch(config.apiUrl+'/rest/v1/rpc/create_project_from_lead',{method:'POST',headers,body:JSON.stringify({p_company:leads[0].company_id,p_lead:leads[0].id,p_name:'Kiểm thử phân trang '+i,p_project_address:null})});
     if(!response.ok)throw new Error('Pagination fixture RPC failed');
   }
 });
 await page.getByRole('button',{name:'Đang hiển thị',exact:true}).click();await page.getByLabel('Tìm dự án',{exact:true}).fill('');await page.getByLabel('Tải lại dữ liệu',{exact:true}).click();
 await page.getByText('Tổng 51 dự án',{exact:true}).waitFor();assert.equal(await page.locator('tbody tr').count(),20);
 await page.getByLabel('Trang sau',{exact:true}).click();assert.equal(await page.locator('tbody tr').count(),20);
 await page.getByLabel('Số kết quả mỗi trang',{exact:true}).selectOption('50');assert.equal(await page.locator('tbody tr').count(),50);assert.equal(await page.locator('.page-buttons span').textContent(),'1 / 2');
 await page.getByLabel('Trang sau',{exact:true}).click();assert.equal(await page.locator('tbody tr').count(),1);
 await page.getByLabel('Trạng thái',{exact:true}).selectOption('Tạm dừng');assert.equal(await page.locator('.page-buttons span').textContent(),'1 / 1');
 await page.getByLabel('Đăng xuất',{exact:true}).click();
 await login('sales');assert.equal(await page.getByRole('button',{name:'Đã ẩn',exact:true}).count(),0);assert.equal(await page.getByRole('button',{name:'Tạo dự án',exact:false}).count(),1);
 await page.getByLabel('Tìm dự án',{exact:true}).fill('Riverside');await page.getByText('Tổng 1 dự án',{exact:true}).waitFor();
 const downloadPromise=page.waitForEvent('download');await page.getByRole('button',{name:'Xuất Excel',exact:false}).click();const download=await downloadPromise;assert.equal(download.suggestedFilename(),'Build-Flow-Du-an.xlsx');
 assert.deepEqual(errors,[]);console.log('PASS browser: owner login/create/hide/unhide; Sales scope; filtered export; 3 viewport overflow checks; 51-row pagination at 20/50 and filter reset; no JS errors.');
}catch(error){console.log(await page.locator('[role=alert]').allTextContents());throw error;}finally{await browser.close();server.kill();}
