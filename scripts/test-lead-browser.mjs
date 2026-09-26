const {chromium}=await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
import {spawn,spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const seeded=spawnSync(process.execPath,['scripts/seed-local-demo.mjs','--local-only'],{encoding:'utf8',windowsHide:true});assert.equal(seeded.status,0,seeded.stderr);
const [,email,password]=seeded.stdout.match(/owner: (\S+) \/ (\S+)/);
const server=spawn(process.execPath,['app/server.mjs'],{windowsHide:true,stdio:'pipe',env:{...process.env,PROJECT_APP_PORT:'4177'}});
const browser=await chromium.launch({channel:'msedge',headless:true});const page=await browser.newPage({viewport:{width:1366,height:768}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
const base='http://127.0.0.1:4177';
try {
 for(let i=0;i<40;i++){try{if((await fetch(base)).ok)break;}catch{}await new Promise(r=>setTimeout(r,250));}
 await page.goto(base);await page.getByLabel('Email',{exact:true}).fill(email);await page.getByLabel('Mật khẩu',{exact:true}).fill(password);await page.getByRole('button',{name:'Đăng nhập',exact:true}).click();await page.getByRole('heading',{name:'Danh sách dự án'}).waitFor();
 await page.locator('[data-nav="Lead"]').click();await page.getByRole('heading',{name:'Lead',exact:true}).waitFor();await page.getByRole('button',{name:'Tạo Lead'}).click();
 await page.locator('[name="customer_name"]').fill('Khách Lead mới');
 await page.locator('[data-picker="source"] .picker-toggle').click();page.once('dialog',d=>d.accept('Facebook'));await page.locator('[data-picker="source"] .picker-add').click();await page.locator('[data-picker="source"] [data-choice="Facebook"]').click();
 await page.locator('[name="source_2"]').fill('Bài quảng cáo A');await page.locator('[name="source_3"]').fill('ad-123');
 await page.locator('[data-picker="execution_types"] .picker-toggle').click();await page.locator('[data-picker="execution_types"] [data-choice="Thiết kế"]').click();await page.locator('[data-picker="execution_types"] .picker-toggle').click();await page.locator('[data-picker="execution_types"] [data-choice="Thi công"]').click();
 await page.locator('[data-picker="building_type"] .picker-toggle').click();await page.locator('[data-picker="building_type"] [data-choice="Nhà hàng"]').click();
 await page.locator('[name="budget"]').fill('120000000');
 await page.locator('[name="status"]').selectOption('Thất bại');
 await page.getByRole('button',{name:'Lưu Lead'}).click();await page.getByText('Vui lòng chọn lý do thất bại.').waitFor();
 await page.locator('[data-picker="failure_reason"] .picker-toggle').click();page.once('dialog',d=>d.accept('Giá cao'));await page.locator('[data-picker="failure_reason"] .picker-add').click();await page.locator('[data-picker="failure_reason"] [data-choice="Giá cao"]').click();
 assert.equal(await page.locator('.form-error:not([hidden])').count(),0,'Reason error clears after selection');
 await page.screenshot({path:'artifacts/build-flow-lead-form.png',fullPage:true});
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Lead form does not scroll the whole page horizontally');
 await page.getByRole('button',{name:'Lưu Lead'}).click();await page.getByRole('button',{name:'Khách Lead mới'}).waitFor();await page.getByRole('button',{name:'Khách Lead mới'}).click();
 assert.match(await page.locator('[data-picker="failure_reason"] .picker-toggle').textContent(),/Giá cao/);
 await page.locator('[data-picker="failure_reason"] .picker-toggle').click();page.once('dialog',d=>d.accept());await page.locator('[data-picker="failure_reason"] [aria-label="Xóa lựa chọn Giá cao"]').click();
 assert.match(await page.locator('[data-picker="failure_reason"] .picker-toggle').textContent(),/Giá cao/);
 await page.locator('[name="status"]').selectOption('Thành công');await page.getByRole('button',{name:'Lưu Lead'}).click();
 await page.locator('[data-nav="Dự án"]').click();await page.getByRole('button',{name:'Tạo dự án',exact:false}).click();
 const leadOption=await page.locator('select[name=lead] option').filter({hasText:'Khách Lead mới'}).getAttribute('value');await page.locator('select[name=lead]').selectOption(leadOption);
 await page.getByLabel('Tên dự án',{exact:true}).fill('Dự án từ Lead mới');await page.getByRole('button',{name:'Tạo dự án',exact:true}).click();await page.getByRole('button',{name:'Dự án từ Lead mới'}).click();
 assert.match(await page.locator('#project-options').textContent(),/Thiết kế/);assert.match(await page.locator('#project-options').textContent(),/Thi công/);
 await page.locator('[data-budget="project"]').fill('130000000');await page.locator('[data-save-budget]').click();
 await page.waitForFunction(()=>document.querySelector('[data-budget="project"]')?.value==='130000000'&&document.querySelector('[data-save-budget]')?.disabled===false);
 assert.equal(await page.locator('[data-budget="project"]').inputValue(),'130000000');
 await page.screenshot({path:'artifacts/build-flow-lead-fields.png',fullPage:true});assert.deepEqual(errors,[]);console.log('PASS Lead browser: option +/×, mandatory reason, archived history, multi-type copy, one editable budget on Lead and Project.');
}catch(error){console.log('Alert:',await page.locator('[role=alert]').allTextContents());console.log('Detail error:',await page.locator('.extra-error:not([hidden])').allTextContents());throw error;}finally{await browser.close();server.kill();}
