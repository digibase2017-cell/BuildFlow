import test from 'node:test';
import assert from 'node:assert/strict';
import {selectProjects,statistics,excelWorkbook,periodRange} from '../app/projects.mjs';
const options={filter:'active',status:'',search:'',from:'',to:'',sort:'desc'};
const row=(id,extra={})=>({id,project_number:Number(id),name:'Dự án',status:'Đang thực hiện',created_at:'2026-09-25T01:00:00Z',is_hidden:false,progress_percent:50,...extra});
test('hidden excluded; deterministic timestamp and ID tie order',()=>{
 const data=[row('1'),row('2'),row('3',{is_hidden:true}),row('4',{created_at:'2026-09-25T02:00:00Z'})];
 assert.deepEqual(selectProjects(data,options).map(p=>p.id),['4','2','1']);
 assert.deepEqual(selectProjects(data,{...options,sort:'asc'}).map(p=>p.id),['1','2','4']);
});
test('combined customer search status and inclusive local date range',()=>{
 const data=[row('1',{customer:'Nguyễn An',created_at:'2026-09-24T18:00:00Z'}),row('2',{customer:'Nguyễn An',status:'Tạm dừng'})];
 assert.equal(selectProjects(data,{...options,search:'nguyễn',status:'Đang thực hiện',from:'2026-09-25',to:'2026-09-25'}).length,1);
 assert.equal(selectProjects(data,{...options,search:'02'})[0].id,'2');
});
test('overdue warning does not replace underlying status',()=>{
 const data=[row('1',{overdue:true})];assert.equal(selectProjects(data,{...options,status:'Quá hạn'})[0].status,'Đang thực hiện');
});
test('statistics exclude hidden and compare equal length adjacent intervals',()=>{
 const data=[row('1'),row('2',{created_at:'2026-09-24T01:00:00Z'}),row('3',{is_hidden:true,overdue:true})];
 const result=statistics(data,'2026-09-25','2026-09-25');assert.equal(result[0].value,1);assert.equal(result[0].trend,'↑ 0%');assert.equal(result[3].value,0);
});
test('Excel exports all matching rows, escapes XML and keeps formula text inert',()=>{
 const data=Array.from({length:51},(_,i)=>row(String(i+1),{name:'=HYPERLINK("x") <&'}));
 const xml=new TextDecoder().decode(excelWorkbook(data));assert.equal((xml.match(/<row r=/g)||[]).length,52);assert.ok(xml.includes('&lt;&amp;'));assert.ok(!xml.includes('<f>'));assert.ok(xml.includes('t="inlineStr"'));
});
test('period crosses month boundary with exact calendar day count',()=>assert.deepEqual(periodRange('7',new Date('2026-03-02T00:00:00Z')),{from:'2026-02-24',to:'2026-03-02'}));
