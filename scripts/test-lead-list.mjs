import assert from 'node:assert/strict';
import { test } from 'node:test';
import { accentPattern, leadQuery, leadTabs, vnd, firstProjects } from '../app/leads.mjs';

test('Lead tabs follow the six approved Sale statuses', () => {
  assert.deepEqual(leadTabs.map(item => item[1]), ['Tất cả','Mới','Đang chăm sóc','Đã hẹn gặp','Đã báo giá','Thành công','Thất bại','Hoạt động mới nhất']);
  assert.deepEqual(leadTabs.slice(1,7).map(item => item[2]), leadTabs.slice(1,7).map(item => item[1]));
});

test('search pattern folds Vietnamese accents at any name position', () => {
  const pattern = new RegExp(accentPattern('hoàng'), 'iu');
  for (const name of ['Hoàng Nguyễn','Nguyen Van Hoang','Trần Hoàng']) assert.match(name, pattern);
  assert.doesNotMatch('Hùng Nguyễn', pattern);
});

test('Lead query applies filters on server and fetches one extra row without count', () => {
  const url = new URL(leadQuery({ companyId:'company', tab:'meeting', search:'hoàng', source:'Website', buildingType:'Nhà đất', assignee:'user', page:3, pageSize:50 }), 'http://localhost');
  assert.equal(url.searchParams.get('company_id'), 'eq.company');
  assert.equal(url.searchParams.get('status'), 'eq.Đã hẹn gặp');
  assert.equal(url.searchParams.get('source'), 'eq.Website');
  assert.equal(url.searchParams.get('building_type'), 'eq.Nhà đất');
  assert.equal(url.searchParams.get('assignee_filter.user_id'), 'eq.user');
  assert.equal(url.searchParams.get('offset'), '100');
  assert.equal(url.searchParams.get('limit'), '51');
  assert.equal(url.searchParams.get('order'), 'created_at.desc,id.desc');
  assert.equal(url.searchParams.has('count'), false);
  assert.equal(url.searchParams.get('select').includes('notes'), false);
});

test('phone search ignores spaces and money uses VND format', () => {
  const url = new URL(leadQuery({ companyId:'company', search:'090 123 4567' }), 'http://localhost');
  assert.match(url.searchParams.get('or'), /phone\.imatch\.0\[\[:space:\]\]\*9/);
  assert.equal(vnd(1200000000), '1.200.000.000 ₫');
});

test('first project for a Lead is the earliest with a stable ID tie break', () => {
  assert.deepEqual([...firstProjects([
    {id:'b',source_lead_id:'one',created_at:'2026-09-28T10:00:00Z'},
    {id:'z',source_lead_id:'one',created_at:'2026-09-27T10:00:00Z'},
    {id:'a',source_lead_id:'one',created_at:'2026-09-27T10:00:00Z'},
  ])], [['one','a']]);
});

test('latest tab retains server pagination and supports ID A-Z sorting', () => {
  const url=new URL(leadQuery({companyId:'company',tab:'latest',sortId:true,page:2,pageSize:100}), 'http://localhost');
  assert.equal(url.searchParams.get('order'),'lead_number.asc,id.asc');
  assert.equal(url.searchParams.get('limit'),'101');
  assert.equal(url.searchParams.get('offset'),'100');
});
