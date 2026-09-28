import {setTimezone, statuses, projectCode, day, selectProjects, periodRange, statistics, excelWorkbook} from '/projects.mjs';
import {leadTabs, leadQuery, vnd, firstProjects} from '/leads.mjs';
import {managedOptionHtml,bindManagedOption} from '/managed-options.mjs';
const root = document.querySelector('#app');
const state = { config: null, session: null, profile: null, role: null, projects: [], selected: null, selectedLead: null, leadProjectBudgets: [], mode: 'projects', leads: [], options: [], defaultProvince: null, permissions: new Set(), canWrite: false,
  leadDetail: {tab:'care', assignments:[], names:new Map(), creator:'', quotes:null, history:null, loading:false, error:''},
  leadList: { tab:'all', search:'', source:'', buildingType:'', assignee:'', sortId:false, page:1, pageSize:50, hasNext:false, loading:false, staff:[], assignments:new Map(), names:new Map(), firstProjects:new Map(), requestId:0 },
  filter: 'active', search: '', status: '', period: 'all', from: '', to: '', sort: 'desc', page: 1, pageSize: 20, loading: false, collapsed: false, busy: false, message: '', error: '' };
const escaped = value => String(value ?? '').replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const isManager = () => ['owner', 'admin'].includes(state.role);
const saved = sessionStorage.getItem('project-saas-session');
if (saved) { try { state.session = JSON.parse(saved); } catch { sessionStorage.removeItem('project-saas-session'); } }

function setSession(session) {
  state.session = session;
  if (session) sessionStorage.setItem('project-saas-session', JSON.stringify(session));
  else sessionStorage.removeItem('project-saas-session');
}
function notice(message, error = false) {
  state.message = error ? '' : message;
  state.error = error ? message : '';
  render();
}
async function raw(path, { method = 'GET', body, token } = {}) {
  const response = await fetch(`${state.config.apiUrl}${path}`, {
    method, headers: { apikey: state.config.anonKey,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const payload = await response.text();
  let data = null;
  try { data = payload ? JSON.parse(payload) : null; } catch { data = payload; }
  return { ok: response.ok, status: response.status, data };
}
async function refreshSession() {
  if (!state.session?.refresh_token) throw new Error('Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.');
  const response = await raw('/auth/v1/token?grant_type=refresh_token', {
    method: 'POST', body: { refresh_token: state.session.refresh_token },
  });
  if (!response.ok) { setSession(null); throw new Error('Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.'); }
  setSession(response.data);
}
async function request(path, options = {}) {
  if (!state.session?.access_token) throw new Error('Vui lòng đăng nhập.');
  if (state.session.expires_at && Date.now() / 1000 > state.session.expires_at - 40) await refreshSession();
  let response = await raw(path, { ...options, token: state.session.access_token });
  if (response.status === 401) {
    await refreshSession();
    response = await raw(path, { ...options, token: state.session.access_token });
  }
  if (!response.ok) {
    const code = response.data?.code;
    if (response.status === 403) throw new Error('Bạn không có quyền thực hiện thao tác này hoặc thuê bao đang ở chế độ chỉ đọc.');
    throw new Error(code === '22023' ? 'Dữ liệu trạng thái ẩn không hợp lệ.' :
      response.data?.message || `Yêu cầu thất bại (${response.status}).`);
  }
  return response.data;
}
async function loadProfile() {
  const user = await request('/auth/v1/user');
  const profiles = await request(`/rest/v1/users?auth_user_id=eq.${encodeURIComponent(user.id)}&select=id,company_id,full_name,role_id,is_active`);
  if (profiles.length !== 1 || !profiles[0].is_active) throw new Error('Tài khoản chưa được gắn vào công ty đang hoạt động.');
  state.profile = profiles[0];
  const companies=await request(`/rest/v1/companies?id=eq.${encodeURIComponent(state.profile.company_id)}&select=timezone`);
  if(!companies[0])throw new Error('Không thể truy cập công ty.');
  setTimezone(companies[0].timezone);
  const access=await request('/rest/v1/rpc/my_capabilities',{method:'POST',body:{p_company:state.profile.company_id}});
  state.role=access.role;
  state.permissions=new Set(access.permissions||[]);
  state.canWrite=access.can_write;
  state.canCreate=state.canWrite&&state.permissions.has('project.create');
  await loadOptions();
  const preferences=await request(`/rest/v1/user_preferences?company_id=eq.${state.profile.company_id}&user_id=eq.${state.profile.id}&select=default_province`);
  state.defaultProvince=preferences[0]?.default_province||null;
}
async function allRows(table, select) {
  const rows=[];
  for(let offset=0;;) {
    const batch=await request(`/rest/v1/${table}?company_id=eq.${encodeURIComponent(state.profile.company_id)}&select=${select}&order=id.asc&limit=500&offset=${offset}`);
    rows.push(...batch);if(!batch.length)return rows;offset+=batch.length;
  }
}
async function loadProjects() {
  state.loading=true;render();
  try {
    const [projects,leads,users,modules]=await Promise.all([
      allRows('projects','*'),allRows('leads','id,customer_name').catch(()=>[]),allRows('users','id,full_name').catch(()=>[]),
      Promise.all(['project_designs','project_purchasing','project_production','project_construction','purchasing_items','production_items','construction_items'].map(async table=>{
        const due=table==='purchasing_items'?'expected_receipt_date':'deadline';
        return (await allRows(table,`id,project_id,status,${due}`)).map(row=>({...row,due:row[due]}));
      }))
    ]);
    const today=day(new Date());
    const overdue=row=>row.due&&row.due<today&&!['Hoàn thành','Đã xong','Đã nhận','Đã duyệt','Đã hủy'].includes(row.status);
    const late=new Set(modules.flat().filter(overdue).map(row=>row.project_id));
    state.projects=projects.map(p=>({...p,customer:leads.find(l=>l.id===p.source_lead_id)?.customer_name||'',responsible:users.find(u=>u.id===p.main_responsible_user_id)?.full_name||'',overdue:late.has(p.id)||overdue({...p,due:p.deadline})}));
  } catch(error){state.projects=[];throw error;} finally{state.loading=false;}
}
async function loadSelected(id) {
  const rows = await request(`/rest/v1/projects?company_id=eq.${encodeURIComponent(state.profile.company_id)}&id=eq.${encodeURIComponent(id)}&select=*`);
  state.selected = rows[0] || null;
  state.projectBudget=null;state.canEditProjectBudget=false;
  if(state.selected) {
    if(state.permissions.has('lead.view')||state.permissions.has('lead.view.all')) {
      try {const budgets=await request('/rest/v1/rpc/lead_project_budgets',{method:'POST',body:{p_company:state.profile.company_id,p_lead:state.selected.source_lead_id}});
        const entry=budgets.find(item=>item.project_id===id);if(entry){state.projectBudget=entry.budget;state.canEditProjectBudget=entry.can_edit;}}
      catch(error){if(!error.message.startsWith('Bạn không có quyền')&&!(state.permissions.has('financial.view')||isManager()))throw error;}
    }
    if(state.projectBudget===null&&(state.permissions.has('financial.view')||isManager())) {
      const finance=await request(`/rest/v1/project_financials?company_id=eq.${encodeURIComponent(state.profile.company_id)}&project_id=eq.${encodeURIComponent(id)}&select=budget`);
      state.projectBudget=finance[0]?.budget??null;
    }
    state.canEditProjectBudget ||= state.canWrite&&state.permissions.has('financial.edit');
  }
  if (!state.selected) state.error = 'Không tìm thấy Project hoặc bạn không có quyền truy cập.';
  render();
}
function loginView() {
  root.innerHTML = `<main class="login-wrap"><form class="login-card" id="login-form">
    <div class="brand"><span class="brand-mark">◈</span> Build Flow</div>
    <div class="eyebrow login-eyebrow">WORKSPACE · LOCAL</div>
    <h1>Chào mừng trở lại</h1><p>Đăng nhập để theo dõi dự án và công việc trong công ty của bạn.</p>
    ${state.error ? `<div class="alert" role="alert">${escaped(state.error)}</div>` : ''}
    <label class="field">Email<input name="email" type="email" autocomplete="username" required placeholder="ten@congty.vn"></label>
    <label class="field">Mật khẩu<input name="password" type="password" autocomplete="current-password" required placeholder="••••••••"></label>
    <button class="primary full" type="submit" ${state.busy ? 'disabled' : ''}>${state.busy ? 'Đang đăng nhập…' : 'Đăng nhập'}</button>
    <p class="login-note">Ứng dụng chỉ kết nối Supabase Local của workspace này.</p>
  </form></main>`;
  document.querySelector('#login-form').addEventListener('submit', async event => {
    event.preventDefault();
    const email = event.target.elements.email.value;
    const password = event.target.elements.password.value;
    state.busy = true; state.error = ''; render();
    try {
      const response = await raw('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password } });
      if (!response.ok) throw new Error('Email hoặc mật khẩu không đúng.');
      setSession(response.data);
      await loadProfile(); await loadProjects();
      state.mode='projects'; state.selectedLead=null; state.filter = 'active'; state.search=''; state.status=''; state.period='all'; state.from=''; state.to=''; state.page=1; state.error = '';
    } catch (error) { setSession(null); state.profile = null; state.error = error.message; }
    finally { state.busy = false; render(); }
  });
}
const initials=name=>name.trim().split(/\s+/).slice(-2).map(word=>word[0]).join('').toUpperCase();
function shell(content) {
  const person=escaped(state.profile.full_name);
  const menu=[['⌂','Tổng quan'],['♙','Lead'],['▤','Báo giá'],['▣','Dự án'],['✎','Thiết kế'],['▱','Mua hàng'],['▥','Sản xuất'],['♧','Thi công'],['▧','Thư viện hạng mục'],['▱','Tài liệu'],['▤','Tài chính'],['▥','Báo cáo'],['♙','Nhân sự'],['⚙','Cài đặt']];
  root.innerHTML=`<div class="shell ${state.collapsed?'collapsed':''}"><aside class="sidebar"><div class="brand" aria-label="Build Flow">Build<span>Flow</span></div><nav aria-label="Điều hướng chính">${menu.map(([icon,label])=>`<button class="nav-item ${(label==='Dự án'&&state.mode==='projects')||(label==='Lead'&&state.mode==='leads')?'active':''} ${['Thư viện hạng mục','Nhân sự'].includes(label)?'divider':''}" ${(label==='Dự án'||(label==='Lead'&&(state.permissions.has('lead.view')||state.permissions.has('lead.view.all')||isManager())))?'aria-current="page"':'disabled title="Chức năng chưa được triển khai"'} data-nav="${label}"><span class="nav-icon">${icon}</span><span class="nav-label">${label}</span></button>`).join('')}</nav><button class="collapse" id="collapse" aria-label="Thu gọn hoặc mở rộng sidebar">‹ <span class="nav-label">Thu gọn</span></button></aside><main class="main"><header class="topbar"><div class="top-actions"><button class="icon-button" id="reload" aria-label="Tải lại dữ liệu">↻</button><span class="avatar">${escaped(initials(state.profile.full_name))}</span><div>${person}<small>${escaped(state.role||'Thành viên')}</small></div><button class="icon-button" id="logout" aria-label="Đăng xuất" title="Đăng xuất">⇥</button></div></header><div class="content">${state.error?`<div class="alert" role="alert">${escaped(state.error)} <button id="retry">Thử lại</button></div>`:''}${state.message?`<div class="alert success" role="status">${escaped(state.message)}</div>`:''}${content}</div></main></div>`;
  document.querySelectorAll('[data-nav]').forEach(button=>button.onclick=async()=>{
    if(button.disabled)return;
    state.mode=button.dataset.nav==='Lead'?'leads':'projects';state.selected=null;state.selectedLead=null;state.error='';
    try{if(state.mode==='leads'){location.hash='#/leads';state.leadList.page=1;await loadLeadStaff();await loadLeads();}else await loadProjects();}catch(error){state.error=error.message;}render();
  });
  document.querySelector('#collapse').onclick=()=>{state.collapsed=!state.collapsed;render();};
  document.querySelector('#logout').onclick=async()=>{
    if(state.session?.access_token)await raw('/auth/v1/logout',{method:'POST',token:state.session.access_token}).catch(()=>{});
    setSession(null);state.profile=null;state.projects=[];state.leads=[];state.selected=null;state.selectedLead=null;state.error='';state.message='';render();
  };
  const reload=async()=>{state.error='';try{await loadProfile();if(state.mode==='leads'){await loadLeadStaff();await loadLeads();}else await loadProjects();}catch(error){state.error=error.message;}render();};
  document.querySelector('#reload').onclick=reload;document.querySelector('#retry')?.addEventListener('click',reload);
}
function date(value) { return value ? day(value).split('-').reverse().join('/') : '—'; }
function listView() {
  const shown=selectProjects(state.projects,state),pages=Math.max(1,Math.ceil(shown.length/state.pageSize));
  state.page=Math.min(state.page,pages);const offset=(state.page-1)*state.pageSize;
  const badge=p=>`<span class="badge status-${statuses.indexOf(p.status)}">${escaped(p.status)}</span>${p.overdue?'<span class="badge overdue">Quá hạn</span>':''}`;
  shell(`<section class="page-heading"><div><h1>Danh sách dự án</h1><p>Quản lý, theo dõi tiến độ và hiệu quả của tất cả dự án.</p></div>${state.canCreate?'<button class="primary" id="create">＋ Tạo dự án</button>':''}</section>
    <section class="stats" aria-label="Thống kê dự án">${statistics(state.projects,state.from,state.to).map((card,i)=>`<article class="stat stat-${i}"><span class="stat-icon">${card.icon}</span><div>${card.label}<strong>${state.loading?'…':i===3&&!isManager()?'—':card.value}</strong>${card.trend?`<small title="So sánh khoảng ngày đã chọn; mặc định 30 ngày gần nhất. Không có mẫu số: —">${card.trend}</small>`:''}</div></article>`).join('')}</section>
    <div class="toolbar"><input class="search" id="search" type="search" placeholder="Tìm tên dự án, ID, khách hàng…" aria-label="Tìm dự án" value="${escaped(state.search)}">
    <select id="status" aria-label="Trạng thái"><option value="">Tất cả trạng thái</option>${[...statuses,'Quá hạn'].map(v=>`<option ${state.status===v?'selected':''}>${v}</option>`).join('')}</select>
    <select id="period" aria-label="Thời gian tạo"><option value="all">Thời gian: Tất cả</option>${[['7','7 ngày gần nhất'],['30','30 ngày gần nhất'],['custom','Khoảng ngày tùy chọn']].map(([v,t])=>`<option value="${v}" ${state.period===v?'selected':''}>${t}</option>`).join('')}</select>
    ${state.period==='custom'?`<label>Từ <input id="from" type="date" value="${state.from}" aria-label="Từ ngày"></label><label>Đến <input id="to" type="date" value="${state.to}" aria-label="Đến ngày"></label>`:''}
    <button class="ghost export" id="export" ${state.loading||!shown.length?'disabled':''}>▧ &nbsp; Xuất Excel</button></div>
    ${isManager()?`<div class="visibility"><button data-filter="active" aria-pressed="${state.filter==='active'}">Đang hiển thị</button><button data-filter="hidden" aria-pressed="${state.filter==='hidden'}">Đã ẩn</button></div>`:''}
    <section class="table-card"><div class="table-scroll" tabindex="0" role="region" aria-label="Bảng dự án"><table><thead><tr><th>STT</th><th>ID</th><th aria-sort="${state.sort==='desc'?'descending':'ascending'}"><button id="sort">Ngày tạo ${state.sort==='desc'?'↓':'↑'}</button></th><th>Tên dự án</th><th>Loại công trình</th><th>Tiến độ</th><th>Trạng thái</th><th>Ngày bắt đầu</th><th>Ngày dự kiến HT</th><th>Người phụ trách</th><th>Thao tác</th></tr></thead><tbody>
    ${state.loading?'<tr><td colspan="11" class="empty">Đang tải dự án…</td></tr>':shown.slice(offset,offset+state.pageSize).map((p,i)=>`<tr><td>${offset+i+1}</td><td>${escaped(projectCode(p))}</td><td>${date(p.created_at)}</td><td><button class="project-link" data-id="${p.id}">${escaped(p.name)}</button></td><td>${escaped(p.building_type||'—')}</td><td><div class="progress-cell"><progress max="100" value="${Number(p.progress_percent)}" aria-label="Tiến độ ${escaped(p.name)}"></progress>${Number(p.progress_percent)}%</div></td><td>${badge(p)}</td><td>${date(p.start_date)}</td><td>${date(p.deadline)}</td><td>${p.responsible?`<div class="person"><span class="avatar">${escaped(initials(p.responsible))}</span>${escaped(p.responsible)}</div>`:'—'}</td><td><details class="actions"><summary aria-label="Thao tác ${escaped(p.name)}">•••</summary><div><button data-id="${p.id}">Xem chi tiết</button>${isManager()?`<button data-hide="${p.id}">${p.is_hidden?'Bỏ ẩn':'Ẩn'} dự án</button>`:''}</div></details></td></tr>`).join('')||'<tr><td colspan="11" class="empty">Không có dự án phù hợp.</td></tr>'}</tbody></table></div>
    <footer class="pagination"><label>Hiển thị <select id="page-size" aria-label="Số kết quả mỗi trang">${[20,50].map(n=>`<option value="${n}" ${state.pageSize===n?'selected':''}>${n} kết quả/trang</option>`).join('')}</select></label><span>Tổng ${shown.length} dự án</span><div class="page-buttons"><button data-page="1" ${state.page===1?'disabled':''} aria-label="Trang đầu">«</button><button data-page="${state.page-1}" ${state.page===1?'disabled':''} aria-label="Trang trước">‹</button><span>${state.page} / ${pages}</span><button data-page="${state.page+1}" ${state.page===pages?'disabled':''} aria-label="Trang sau">›</button><button data-page="${pages}" ${state.page===pages?'disabled':''} aria-label="Trang cuối">»</button></div></footer></section>
    ${!isManager()?'<p class="data-note">Cảnh báo quá hạn chỉ dựa trên hoạt động bạn được phép xem; chưa có số tổng hợp toàn dự án.</p>':''}`);
  const reset=()=>{state.page=1;render();};
  document.querySelector('#search').oninput=event=>{state.search=event.target.value;reset();document.querySelector('#search').focus();};
  document.querySelector('#status').onchange=e=>{state.status=e.target.value;reset();};
  document.querySelector('#period').onchange=e=>{state.period=e.target.value;Object.assign(state,periodRange(state.period));reset();};
  ['from','to'].forEach(key=>document.querySelector('#'+key)?.addEventListener('change',e=>{state[key]=e.target.value;if(state.from&&state.to&&state.from>state.to){state[key]='';state.error='Ngày bắt đầu phải trước hoặc bằng ngày kết thúc.';}else state.error='';reset();}));
  document.querySelector('#sort').onclick=()=>{state.sort=state.sort==='desc'?'asc':'desc';reset();};
  document.querySelector('#page-size').onchange=e=>{state.pageSize=Number(e.target.value);reset();};
  document.querySelectorAll('[data-page]').forEach(b=>b.onclick=()=>{state.page=Number(b.dataset.page);render();});
  document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{state.filter=b.dataset.filter;reset();});
  document.querySelectorAll('[data-id]').forEach(b=>b.onclick=async()=>{try{await loadSelected(b.dataset.id);}catch(error){notice(error.message,true);}});
  document.querySelectorAll('[data-hide]').forEach(b=>b.onclick=()=>confirmToggle(state.projects.find(p=>p.id===b.dataset.hide)));
  document.querySelector('#create')?.addEventListener('click',()=>createProject());
  document.querySelector('#export').onclick=async()=>{
    try {await loadProjects();const rows=selectProjects(state.projects,state);const url=URL.createObjectURL(new Blob([excelWorkbook(rows)],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}));const a=document.createElement('a');a.href=url;a.download='Build-Flow-Du-an.xlsx';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);render();}catch(error){notice(error.message,true);}
  };
}

async function createProject(leadId=null) {
  try {
    const selectedLead=leadId?(state.leads.find(lead=>lead.id===leadId)|| (state.selectedLead?.id===leadId?state.selectedLead:null)):null;
    if(leadId&&!selectedLead)throw new Error('Lead đã chọn không còn trong trang hiện tại. Vui lòng tải lại danh sách.');
    const leads=leadId?[selectedLead]:(await allRows('leads','id,lead_number,customer_name,status')).filter(l=>l.status==='Thành công');
    const backdrop=document.createElement('div');backdrop.className='dialog-backdrop';
    backdrop.innerHTML=`<form class="dialog" role="dialog" aria-modal="true" aria-labelledby="create-title"><h2 id="create-title">Tạo dự án từ Lead</h2>${leadId?`<p>Lead #${selectedLead.lead_number} · ${escaped(selectedLead.customer_name)}</p><input type="hidden" name="lead" value="${leadId}">`:`<label class="field">Lead thành công<select name="lead" required><option value="">Chọn Lead</option>${leads.map(l=>`<option value="${l.id}">#${l.lead_number} · ${escaped(l.customer_name)}</option>`).join('')}</select></label>`}<label class="field">Tên dự án<input name="name" required maxlength="250"></label><label class="field">Địa chỉ công trình<input name="address"></label><fieldset><legend>Module dự án</legend>${[['design','Thiết kế'],['purchasing','Mua hàng'],['production','Sản xuất'],['construction','Thi công']].map(([v,t])=>`<label><input type="checkbox" name="${v}"> ${t}</label>`).join(' ')}</fieldset><p>Nghiệm thu và Thanh toán luôn có trong dự án.</p><div class="alert form-error" hidden></div><div class="dialog-actions"><button type="button" class="ghost" id="cancel-create">Hủy</button><button class="primary" type="submit" ${!leads.length?'disabled':''}>Tạo dự án</button></div></form>`;
    root.append(backdrop);const form=backdrop.querySelector('form');(leadId?form.elements.name:form.elements.lead).focus();
    const close=()=>backdrop.remove();backdrop.querySelector('#cancel-create').onclick=close;
    backdrop.onkeydown=e=>{if(e.key==='Escape')close();};
    form.onsubmit=async e=>{e.preventDefault();const submit=form.querySelector('[type=submit]');submit.disabled=true;
      try {await request('/rest/v1/rpc/create_project_from_lead',{method:'POST',body:{p_company:state.profile.company_id,p_lead:form.elements.lead.value,p_name:form.elements.name.value.trim(),p_project_address:form.elements.address.value.trim()||null,p_has_design:form.elements.design.checked,p_has_purchasing:form.elements.purchasing.checked,p_has_production:form.elements.production.checked,p_has_construction:form.elements.construction.checked}});close();if(state.selectedLead?.id===leadId)await openLead(leadId);else if(leadId)await loadLeads();else{state.filter='active';state.page=1;await loadProjects();}notice('Đã tạo dự án.');}
      catch(error){const alert=form.querySelector('.form-error');alert.hidden=false;alert.textContent=error.message;submit.disabled=false;}
    };
  }catch(error){notice(error.message,true);}
}

function can(code) { return state.canWrite && state.permissions?.has(code); }
async function loadOptions() {
  state.options=await allRows('lead_options','id,kind,label,is_active');
}
async function loadLeads() {
  const list=state.leadList,requestId=++list.requestId;
  list.loading=true;state.error='';if(state.mode==='leads'&&!state.selectedLead)render();
  try {
    const rows=await request(leadQuery({companyId:state.profile.company_id,...list}));
    if(requestId!==list.requestId)return;
    state.leads=rows.slice(0,list.pageSize);
    list.hasNext=rows.length>list.pageSize;
    list.firstProjects=new Map();
    list.assignments=new Map(state.leads.map(lead=>[lead.id,[]]));
    list.names=new Map(list.staff.map(user=>[user.id,user.full_name]));
    if(state.leads.length&&list.tab!=='latest'){
      const ids=state.leads.map(lead=>lead.id).join(',');
      const visibleProjects=[];
      for(let offset=0;;offset+=1000){
        const projects=await request(`/rest/v1/projects?company_id=eq.${state.profile.company_id}&source_lead_id=in.(${ids})&select=id,source_lead_id,created_at&order=created_at.asc,id.asc&limit=1000&offset=${offset}`);
        if(requestId!==list.requestId)return;
        visibleProjects.push(...projects);
        if(projects.length<1000)break;
      }
      list.firstProjects=firstProjects(visibleProjects);
    }
    if(state.leads.length&&(state.permissions.has('lead.view')||isManager())) {
      const ids=state.leads.map(lead=>lead.id).join(',');
      const assignments=[];for(let offset=0;;offset+=1000){const batch=await request(`/rest/v1/lead_assignments?company_id=eq.${state.profile.company_id}&lead_id=in.(${ids})&unassigned_at=is.null&select=lead_id,user_id&order=id.asc&limit=1000&offset=${offset}`);assignments.push(...batch);if(batch.length<1000)break;}
      if(requestId!==list.requestId)return;
      for(const item of assignments)list.assignments.get(item.lead_id)?.push(item.user_id);
      const unknown=[...new Set(assignments.map(item=>item.user_id))].filter(id=>!list.names.has(id));
      if(unknown.length){const names=await request(`/rest/v1/users?company_id=eq.${state.profile.company_id}&id=in.(${unknown.join(',')})&select=id,full_name`);
        if(requestId!==list.requestId)return;for(const user of names)list.names.set(user.id,user.full_name);}
    }
  } catch(error){if(requestId===list.requestId){state.leads=[];list.hasNext=false;state.error=error.message;}}
  finally{if(requestId===list.requestId){list.loading=false;if(state.mode==='leads'&&!state.selectedLead)render();}}
}
async function loadLeadStaff() {
  if(!state.permissions.has('lead.assign')){state.leadList.staff=[];return;}
  const staff=await request('/rest/v1/rpc/list_sale_candidates',{method:'POST',body:{p_company:state.profile.company_id}});
  state.leadList.staff=staff.map(user=>({id:user.user_id,full_name:user.full_name}));
}
const leadStatuses=['Mới','Đang chăm sóc','Đã hẹn gặp','Đã báo giá','Thành công','Thất bại'];
const pickerKind={source:'source',execution_types:'execution_type',building_type:'building_type',failure_reason:'failure_reason'};
const pickerTitle={source:'Nguồn 1',execution_types:'Loại thực hiện',building_type:'Loại công trình',failure_reason:'Lý do thất bại',province:'Tỉnh/Thành phố'};
pickerKind.province='province';
const optionValues=kind=>state.options.filter(item=>item.kind===kind&&item.is_active);
const mayManageOptions=kind=>can('lead.create')||can('lead.edit')||(['execution_type','building_type'].includes(kind)&&can('project.edit'));
const addManagedOption=async(kind,label)=>{
  await request(kind==='province'?'/rest/v1/rpc/add_province_option':'/rest/v1/rpc/add_lead_option',{
    method:'POST',body:kind==='province'?{p_company:state.profile.company_id,p_label:label}:{p_company:state.profile.company_id,p_kind:kind,p_label:label},
  });await loadOptions();
};
const deleteManagedOption=async id=>{
  await request('/rest/v1/rpc/archive_lead_option',{method:'POST',body:{p_company:state.profile.company_id,p_option:id}});
  await loadOptions();
};
function pickerHtml(key,draft,editable) {
  return managedOptionHtml({key,label:pickerTitle[key],addLabel:key==='source'?'nguồn':key==='province'?'tỉnh/thành phố':pickerTitle[key].toLowerCase(),searchable:key==='province'});
}
function bindPickers(container,draft,editable,onChange=()=>{}) {
  for(const picker of container.querySelectorAll('[data-picker]')){
    const key=picker.dataset.picker,kind=pickerKind[key];
    bindManagedOption(picker,{label:pickerTitle[key],multiple:key==='execution_types',searchable:key==='province',
      disabled:!editable,allowAdd:editable&&mayManageOptions(kind),allowDelete:editable&&mayManageOptions(kind),
      getOptions:()=>optionValues(kind),getValue:()=>draft[key],onChange:value=>{draft[key]=value;onChange(key);},
      onAdd:label=>addManagedOption(kind,label),onDelete:deleteManagedOption,
      onError:message=>{const box=container.querySelector('.form-error,.lead-card-error')||container.closest('.project-extra')?.querySelector('.extra-error');if(box){box.hidden=false;box.textContent=message;}},
    });
  }
}
let leadSearchTimer;
function leadAssigneeCell(lead) {
  const list=state.leadList,ids=list.assignments.get(lead.id)||[];
  const canAssign=can('lead.assign')&&list.staff.length>0&&(isManager()||state.permissions.has('lead.view'));
  const name=id=>list.names.get(id)||'Người phụ trách chưa hiển thị';
  const avatars=ids.slice(0,3).map(id=>`<span class="lead-avatar" title="${escaped(name(id))}">${escaped(list.names.has(id)?initials(name(id)):'?')}</span>`).join('');
  const summary=`<span class="lead-avatars">${avatars||'<span class="muted">Chưa phân công</span>'}${ids.length>3?`<span class="lead-more">+${ids.length-3}</span>`:''}</span><span aria-hidden="true">⌄</span>`;
  const choices=canAssign?list.staff.map(user=>`<label class="lead-choice"><input type="checkbox" value="${user.id}" ${ids.includes(user.id)?'checked':''}><span>${escaped(user.full_name)}</span></label>`).join(''):
    ids.map(id=>`<div class="lead-choice">${escaped(name(id))}</div>`).join('')||'<p class="muted">Chưa phân công</p>';
  return `<details class="lead-assignees" data-assignees="${lead.id}"><summary aria-label="Người phụ trách của ${escaped(lead.customer_name)}">${summary}</summary><div class="lead-assignee-menu">${canAssign?'<input type="search" class="lead-person-search" placeholder="Tìm nhân viên Sale..." aria-label="Tìm nhân viên Sale">':''}<div class="lead-person-list">${choices}</div><p class="lead-assign-error" role="alert" hidden></p></div></details>`;
}
function leadListView() {
  const list=state.leadList,latest=list.tab==='latest';
  const options=kind=>state.options.filter(item=>item.kind===kind&&item.is_active).map(item=>item.label);
  const selectOptions=(items,value)=>items.map(item=>`<option value="${escaped(item)}" ${value===item?'selected':''}>${escaped(item)}</option>`).join('');
  const badge=lead=>`<span class="badge lead-status-${leadStatuses.indexOf(lead.status)}">${escaped(lead.status)}</span>`;
  const rows=list.loading?`<tr><td colspan="${latest?6:12}" class="empty">Đang tải Lead…</td></tr>`:latest?
    state.leads.map(lead=>`<tr><td>—</td><td>${lead.lead_number}</td><td><a class="lead-name" href="#/leads/${lead.id}" data-lead="${lead.id}">${escaped(lead.customer_name)}</a></td><td>${escaped(lead.phone||'—')}</td><td>${leadAssigneeCell(lead)}</td><td>Chưa có hoạt động</td></tr>`).join('')||'<tr><td colspan="6" class="empty">Không có Lead phù hợp.</td></tr>':
    state.leads.map(lead=>`<tr><td>${lead.lead_number}</td><td><a class="lead-name" href="#/leads/${lead.id}" data-lead="${lead.id}">${escaped(lead.customer_name)}</a></td><td>${escaped(lead.phone||'—')}</td><td>${escaped(lead.source||'—')}</td><td>${escaped(lead.building_type||'—')}</td><td>${escaped((lead.execution_types||[]).join(', ')||'—')}</td><td>${escaped(vnd(lead.budget))}</td><td>${leadAssigneeCell(lead)}</td><td>${date(lead.created_at)}</td><td>${badge(lead)}</td><td>${lead.status==='Thất bại'?escaped(lead.failure_reason||'—'):'—'}</td><td>${list.firstProjects.has(lead.id)?`<button type="button" class="lead-project-button existing" data-open-project="${list.firstProjects.get(lead.id)}" aria-label="Mở dự án đầu tiên từ ${escaped(lead.customer_name)}">Đã có</button>`:can('project.create')?`<button type="button" class="lead-project-button" data-create-project="${lead.id}" aria-label="Tạo dự án từ ${escaped(lead.customer_name)}">+</button>`:''}</td></tr>`).join('')||'<tr><td colspan="12" class="empty">Không có Lead phù hợp.</td></tr>';
  shell(`<section class="page-heading"><div><h1>Danh sách Lead</h1></div>${can('lead.create')?'<button id="new-lead" class="primary">+ Thêm Lead</button>':''}</section>
    <nav class="lead-tabs" aria-label="Trạng thái Lead">${leadTabs.map(([key,label])=>`<button type="button" data-lead-tab="${key}" class="${list.tab===key?'active':''}" aria-current="${list.tab===key?'page':'false'}">${label}</button>`).join('')}</nav>
    <div class="toolbar lead-toolbar"><input class="search" id="lead-search" type="search" placeholder="Tìm theo tên khách hàng hoặc số điện thoại..." aria-label="Tìm Lead" value="${escaped(list.search)}">
      <select id="lead-source" aria-label="Nguồn 1"><option value="">Nguồn 1: Tất cả</option>${selectOptions(options('source'),list.source)}</select>
      <select id="lead-building" aria-label="Loại công trình"><option value="">Loại công trình: Tất cả</option>${selectOptions(options('building_type'),list.buildingType)}</select>
      <select id="lead-assignee-filter" aria-label="Người phụ trách"><option value="">Người phụ trách: Tất cả</option>${list.staff.map(user=>`<option value="${user.id}" ${list.assignee===user.id?'selected':''}>${escaped(user.full_name)}</option>`).join('')}</select>
      <button id="lead-clear" class="ghost lead-clear" type="button">Xóa bộ lọc</button></div>
    ${latest?'<p class="alert">Chưa có API hoạt động chăm khách theo Lead; thời gian và nội dung hoạt động chưa thể xác minh hoặc sắp xếp.</p>':''}
    <section class="table-card"><div class="table-scroll" tabindex="0" role="region" aria-label="Bảng danh sách Lead"><table class="lead-table ${latest?'lead-latest':''}"><thead><tr>${(latest?['Thời gian','ID','Tên khách hàng','SĐT','Tên người phụ trách','Hoạt động mới nhất']:['ID','Tên khách hàng','Điện thoại','Nguồn','Loại công trình','Loại thực hiện','Ngân sách','Người phụ trách','Ngày tạo','Trạng thái Sale','Lý do thất bại','Tạo dự án']).map(label=>`<th>${latest&&label==='ID'?`<button type="button" id="lead-id-sort" aria-label="Sắp xếp ID A-Z" aria-pressed="${list.sortId}">ID</button>`:label}</th>`).join('')}</tr></thead><tbody>${rows}</tbody></table></div>
      <footer class="pagination lead-pagination"><label>Hiển thị <select id="lead-page-size" aria-label="Số Lead mỗi trang">${[50,100].map(n=>`<option value="${n}" ${list.pageSize===n?'selected':''}>${n} Lead/trang</option>`).join('')}</select></label><div class="page-buttons"><button id="lead-prev" ${list.page===1||list.loading?'disabled':''}>Trang trước</button><span>Trang ${list.page}</span><button id="lead-next" ${!list.hasNext||list.loading?'disabled':''}>Trang sau</button></div></footer></section>`);
  const refresh=()=>{list.page=1;loadLeads();};
  document.querySelector('#new-lead')?.addEventListener('click',()=>{location.hash='#/leads/new';state.selectedLead={execution_types:[],status:'Mới'};render();});
  document.querySelectorAll('[data-lead-tab]').forEach(button=>button.onclick=()=>{clearTimeout(leadSearchTimer);list.tab=button.dataset.leadTab;refresh();});
  document.querySelector('#lead-id-sort')?.addEventListener('click',()=>{list.sortId=true;refresh();});
  document.querySelector('#lead-search').oninput=event=>{list.search=event.target.value;clearTimeout(leadSearchTimer);leadSearchTimer=setTimeout(refresh,400);};
  document.querySelector('#lead-source').onchange=event=>{list.source=event.target.value;refresh();};
  document.querySelector('#lead-building').onchange=event=>{list.buildingType=event.target.value;refresh();};
  document.querySelector('#lead-assignee-filter').onchange=event=>{list.assignee=event.target.value;refresh();};
  document.querySelector('#lead-clear').onclick=()=>{clearTimeout(leadSearchTimer);Object.assign(list,{tab:'all',search:'',source:'',buildingType:'',assignee:''});refresh();};
  document.querySelector('#lead-page-size').onchange=event=>{list.pageSize=Number(event.target.value);refresh();};
  document.querySelector('#lead-prev').onclick=()=>{list.page--;loadLeads();};
  document.querySelector('#lead-next').onclick=()=>{list.page++;loadLeads();};
  document.querySelectorAll('[data-lead]').forEach(link=>link.onclick=async event=>{event.preventDefault();location.hash=`#/leads/${link.dataset.lead}`;await openLead(link.dataset.lead);});
  document.querySelectorAll('[data-create-project]').forEach(button=>button.onclick=()=>createProject(button.dataset.createProject));
  document.querySelectorAll('[data-open-project]').forEach(button=>button.onclick=async()=>{try{state.mode='projects';await loadSelected(button.dataset.openProject);}catch(error){notice(error.message,true);}});
  document.querySelectorAll('.lead-assignees').forEach(details=>{
    details.querySelector('.lead-person-search')?.addEventListener('input',event=>{const term=event.target.value.toLocaleLowerCase('vi');details.querySelectorAll('.lead-choice').forEach(row=>{row.hidden=!row.textContent.toLocaleLowerCase('vi').includes(term);});});
    details.querySelectorAll('input[type=checkbox]').forEach(input=>input.addEventListener('change',async()=>{
      if(details.dataset.saving==='true')return;
      const before=[...(list.assignments.get(details.dataset.assignees)||[])];
      const users=[...details.querySelectorAll('input[type=checkbox]:checked')].map(item=>item.value);
      const controls=[...details.querySelectorAll('input[type=checkbox]')];
      const errorBox=details.querySelector('.lead-assign-error');
      details.dataset.saving='true';controls.forEach(item=>item.disabled=true);errorBox.hidden=true;
      try{
        await request('/rest/v1/rpc/set_lead_assignees',{method:'POST',body:{p_company:state.profile.company_id,p_lead:details.dataset.assignees,p_users:users}});
        list.assignments.set(details.dataset.assignees,users);await loadLeads();
      }catch(error){
        controls.forEach(item=>item.checked=before.includes(item.value));
        errorBox.textContent=error.message;errorBox.hidden=false;
      }finally{details.dataset.saving='false';controls.forEach(item=>item.disabled=false);}
    }));
  });
}
async function openLead(id) {
  try {
    const rows=await request(`/rest/v1/leads?company_id=eq.${encodeURIComponent(state.profile.company_id)}&id=eq.${encodeURIComponent(id)}&select=*`);
    if(!rows[0])throw new Error('Không tìm thấy Lead hoặc bạn không có quyền truy cập.');
    state.mode='leads';state.selectedLead=rows[0];state.error='';
    state.leadDetail={tab:'care',assignments:[],names:new Map(),creator:'',care:null,history:null,carePage:0,historyCursor:null,error:''};
    const detail=state.leadDetail,company=state.profile.company_id;
    const assignments=await request('/rest/v1/rpc/list_lead_assignees',{method:'POST',body:{p_company:company,p_lead:id}}).catch(error=>{detail.assigneeError=error.message;return[];});
    detail.assignments=assignments.map(row=>row.user_id);
    detail.names=new Map(assignments.map(row=>[row.user_id,row.full_name]));
    detail.creator=await request('/rest/v1/rpc/get_lead_creator_name',{method:'POST',body:{p_company:company,p_lead:id}}).catch(()=> '—');
    render();
  } catch(error){state.error=error.message;state.selectedLead=null;render();}
}
function createLeadView() {
  const options=kind=>state.options.filter(item=>item.kind===kind&&item.is_active);
  const field=(key,label,type='text',extra='')=>`<div class="create-field" data-field="${key}"><label for="new-${key}">${label}</label><input id="new-${key}" name="${key}" type="${type}" ${extra}><small class="field-error" role="alert" hidden></small></div>`;
  const canChooseAssignees=can('lead.assign')&&state.leadList.staff.length>0;
  const provinceChoices=options('province');
  const initialProvince=provinceChoices.some(item=>item.label===state.defaultProvince)?state.defaultProvince:'';
  const draft={province:initialProvince||null,source:null,building_type:null,execution_types:[]};
  shell(`<div class="new-lead-page"><nav class="lead-breadcrumb" aria-label="Breadcrumb"><a href="#/leads" id="new-lead-breadcrumb">Lead</a><span>›</span><span>Tạo Lead mới</span></nav>
    <form id="new-lead-form" novalidate><div class="new-lead-heading"><h1>Tạo Lead mới</h1><div class="new-lead-actions"><button type="button" class="ghost" id="cancel-new-lead">Hủy</button><button type="submit" class="primary" id="save-new-lead" ${can('lead.create')?'':'disabled'}>Lưu Lead</button></div></div>
    <section class="new-lead-card"><h2>1. Thông tin khách hàng</h2><div class="new-lead-grid customer-grid">
      ${field('customer_name','Tên khách hàng <span class="required">*</span>','text','required')}${field('phone','Số điện thoại','tel')}
      ${field('email','Email','email')}${field('zalo','Zalo / Facebook')}
      ${field('address','Địa chỉ')}
      <div class="province-group"><div class="create-field" data-field="province">${pickerHtml('province',draft,true)}<small class="field-error" role="alert" hidden></small></div><label class="default-province"><input type="checkbox" name="default_province" ${initialProvince?'checked':''}> Mặc định</label></div>
    </div></section>
    <section class="new-lead-card"><h2>2. Thông tin dự án</h2><div class="new-lead-grid project-grid">
      <div class="create-field" data-field="source">${pickerHtml('source',draft,true)}<small class="field-error" role="alert" hidden></small></div>${field('source_2','Nguồn 2')}${field('source_3','Nguồn 3')}
      <div class="create-field" data-field="building_type">${pickerHtml('building_type',draft,true)}</div>
      <div class="create-field" data-field="execution_types">${pickerHtml('execution_types',draft,true)}</div>
      ${field('budget','Ngân sách','number','min="0" step="1" inputmode="numeric"')}
      <div class="create-field assignee-field"><label>Người phụ trách</label><details><summary aria-label="Mở danh sách người phụ trách">▾</summary><div class="create-assignee-options">${canChooseAssignees?state.leadList.staff.map(user=>`<label><input type="checkbox" name="assignees" value="${user.id}"> ${escaped(user.full_name)}</label>`).join(''):'Không có nhân viên Sale khả dụng theo quyền hiện tại.'}</div></details><div class="selected-assignees" aria-live="polite"></div><small class="field-error" role="alert" hidden></small></div>
    </div></section>
    <section class="new-lead-card"><h2>3. Nhu cầu và ghi chú</h2><div class="new-lead-grid notes-grid"><div class="create-field"><label for="new-customer-requirements">Nhu cầu khách hàng</label><textarea id="new-customer-requirements" name="customer_requirements" rows="5"></textarea></div><div class="create-field"><label for="new-notes">Ghi chú</label><textarea id="new-notes" name="notes" rows="5"></textarea></div></div></section>
    <div class="alert create-general-error" role="alert" hidden></div></form></div>`);
  const form=document.querySelector('#new-lead-form');const draftLeadId=crypto.randomUUID();let saving=false;
  bindPickers(form,draft,true,key=>{if(key==='province')form.elements.default_province.checked=false;});
  const cancel=event=>{event?.preventDefault();location.hash='#/leads';state.selectedLead=null;loadLeads();};
  document.querySelector('#cancel-new-lead').onclick=cancel;document.querySelector('#new-lead-breadcrumb').onclick=cancel;
  const updateSelected=()=>{const names=[...form.querySelectorAll('[name=assignees]:checked')].map(input=>state.leadList.staff.find(user=>user.id===input.value)?.full_name).filter(Boolean);form.querySelector('.selected-assignees').textContent=names.join(', ');};
  form.querySelectorAll('[name=assignees]').forEach(input=>input.addEventListener('change',updateSelected));
  const showFieldError=(key,message)=>{const container=form.querySelector(`[data-field="${key}"]`),error=container?.querySelector('.field-error');if(error){error.textContent=message;error.hidden=false;container.querySelector('input,select')?.setAttribute('aria-invalid','true');}};
  form.oninput=event=>{const container=event.target.closest('[data-field]');if(container){container.querySelector('.field-error')?.setAttribute('hidden','');container.querySelector('input,select')?.removeAttribute('aria-invalid');}};
  form.onsubmit=async event=>{
    event.preventDefault();if(saving||!can('lead.create'))return;
    form.querySelectorAll('.field-error').forEach(error=>error.hidden=true);form.querySelectorAll('[aria-invalid]').forEach(input=>input.removeAttribute('aria-invalid'));
    const general=form.querySelector('.create-general-error');general.hidden=true;
    const customerName=form.elements.customer_name.value.trim();
    if(!customerName){showFieldError('customer_name','Vui lòng nhập tên khách hàng.');return;}
    if(form.elements.email.value&&!form.elements.email.checkValidity()){showFieldError('email','Email không đúng định dạng.');return;}
    if(form.elements.default_province.checked&&!draft.province){showFieldError('province','Chọn Tỉnh/Thành phố trước khi đặt mặc định.');return;}
    const budget=form.elements.budget.value;
    if(budget!==''&&(!form.elements.budget.checkValidity()||!Number.isSafeInteger(Number(budget)))){showFieldError('budget','Ngân sách phải là số nguyên không âm.');return;}
    const assignees=[...form.querySelectorAll('[name=assignees]:checked')].map(input=>input.value);
    const id=draftLeadId,button=form.querySelector('#save-new-lead');saving=true;button.disabled=true;button.textContent='Đang lưu…';
    try{
      const data={customer_name:customerName,phone:form.elements.phone.value.trim()||null,email:form.elements.email.value.trim()||null,zalo:form.elements.zalo.value.trim()||null,address:form.elements.address.value.trim()||null,source:draft.source,source_2:form.elements.source_2.value.trim()||null,source_3:form.elements.source_3.value.trim()||null,building_type:draft.building_type,execution_types:draft.execution_types,budget:budget===''?null:Number(budget),province:draft.province,customer_requirements:form.elements.customer_requirements.value.trim()||null,notes:form.elements.notes.value.trim()||null};
      await request('/rest/v1/rpc/create_lead_with_assignees',{method:'POST',body:{p_company:state.profile.company_id,p_lead:id,p_data:data,p_users:assignees,p_make_default:form.elements.default_province.checked}});
      if(form.elements.default_province.checked)state.defaultProvince=data.province;
      await loadLeads();state.selectedLead=null;
      if(isManager()||state.permissions.has('lead.view.all')||assignees.includes(state.profile.id)){location.hash=`#/leads/${id}`;await openLead(id);}
      else{location.hash='#/leads';notice('Đã tạo Lead mới.');}
    }catch(error){general.hidden=false;general.textContent=error.message;}
    finally{saving=false;if(button.isConnected){button.disabled=false;button.textContent='Lưu Lead';}}
  };
}
function leadFormView() {
  const lead=state.selectedLead,existing=Boolean(lead.id),editable=existing?can('lead.edit'):can('lead.create');
  const draft={source:lead.source||null,execution_types:[...(lead.execution_types||[])],building_type:lead.building_type||null,failure_reason:lead.failure_reason||null};
  const field=(name,title,type='text')=>`<label class="field">${title}<input name="${name}" type="${type}" value="${escaped(lead[name]??'')}" ${editable?'':'disabled'} ${name==='customer_name'?'required':''}></label>`;
  shell(`<div class="detail"><button id="back-leads" class="back">← Danh sách Lead</button><section class="detail-card"><h1>${existing?'Chi tiết Lead #'+lead.lead_number:'Tạo Lead'}</h1><form id="lead-form" class="lead-form">
    ${field('customer_name','Tên khách hàng')}${field('phone','Điện thoại','tel')}${field('email','Email','email')}${field('zalo','Zalo / Facebook')}${field('address','Địa chỉ khách hàng')}
    ${pickerHtml('source',draft,editable)}${field('source_2','Source 2 · chiến dịch/bài quảng cáo')}${field('source_3','Source 3 · ID bài quảng cáo')}
    ${pickerHtml('execution_types',draft,editable)}${pickerHtml('building_type',draft,editable)}
    ${field('budget','Ngân sách (VND)','number')}
    <label class="field">Trạng thái Sale<select name="status" ${editable?'':'disabled'}>${leadStatuses.map(v=>`<option ${lead.status===v?'selected':''}>${v}</option>`).join('')}</select></label>
    <div id="reason-row">${pickerHtml('failure_reason',draft,editable)}</div>${field('customer_requirements','Nhu cầu khách hàng')}${field('notes','Ghi chú')}
    <div class="alert form-error" hidden></div>${editable?'<button type="submit" class="primary">Lưu Lead</button>':''}</form>
    ${existing&&state.leadProjectBudgets!==null?`<section class="project-extra"><h3>Ngân sách Project từ Lead này</h3>${state.leadProjectBudgets.length?state.leadProjectBudgets.map(p=>`<div class="budget-fields"><label class="field">Dự án #${p.project_number} · Ngân sách (VND)<input type="number" min="0" data-lead-project-budget="${p.project_id}" value="${p.budget??''}" ${p.can_edit?'':'disabled'}></label>${p.can_edit?`<button type="button" class="ghost" data-save-lead-project-budget="${p.project_id}">Lưu ngân sách</button>`:''}</div>`).join(''):'<p class="muted">Chưa có Project liên kết.</p>'}<div class="alert budget-error" hidden></div></section>`:''}</section></div>`);
  document.querySelector('#back-leads').onclick=()=>{location.hash='#/leads';state.selectedLead=null;render();};
  const form=document.querySelector('#lead-form'),reasonRow=document.querySelector('#reason-row');
  const toggleReason=()=>{reasonRow.hidden=form.elements.status.value!=='Thất bại';};
  const clearFormError=()=>{form.querySelector('.form-error').hidden=true;};
  form.elements.status.onchange=()=>{toggleReason();clearFormError();};toggleReason();
  form.addEventListener('input',clearFormError);
  bindPickers(form,draft,editable,clearFormError);
  document.querySelectorAll('[data-save-lead-project-budget]').forEach(button=>button.onclick=async()=>{const input=document.querySelector(`[data-lead-project-budget="${button.dataset.saveLeadProjectBudget}"]`);button.disabled=true;try{await request('/rest/v1/rpc/set_project_budget',{method:'POST',body:{p_company:state.profile.company_id,p_project:button.dataset.saveLeadProjectBudget,p_budget:input.value===''?null:Number(input.value)}});state.leadProjectBudgets=await request('/rest/v1/rpc/lead_project_budgets',{method:'POST',body:{p_company:state.profile.company_id,p_lead:lead.id}});render();}catch(error){const box=document.querySelector('.budget-error');box.hidden=false;box.textContent=error.message;button.disabled=false;}});
  form.onsubmit=async event=>{
    event.preventDefault();if(!editable)return;
    const budget=name=>form.elements[name].value===''?null:Number(form.elements[name].value);
    if(form.elements.status.value==='Thất bại'&&!draft.failure_reason){const alert=form.querySelector('.form-error');alert.hidden=false;alert.textContent='Vui lòng chọn lý do thất bại.';return;}
    const body={company_id:state.profile.company_id,customer_name:form.elements.customer_name.value.trim(),phone:form.elements.phone.value||null,email:form.elements.email.value||null,zalo:form.elements.zalo.value||null,address:form.elements.address.value||null,
      source:draft.source,source_2:form.elements.source_2.value||null,source_3:form.elements.source_3.value||null,execution_types:draft.execution_types,building_type:draft.building_type,budget:budget('budget'),status:form.elements.status.value,failure_reason:draft.failure_reason,customer_requirements:form.elements.customer_requirements.value||null,notes:form.elements.notes.value||null};
    if(!existing){body.id=crypto.randomUUID();body.created_by=state.profile.id;}
    const button=form.querySelector('[type=submit]');button.disabled=true;
    try{await request(existing?`/rest/v1/leads?company_id=eq.${state.profile.company_id}&id=eq.${lead.id}`:'/rest/v1/leads',{method:existing?'PATCH':'POST',body});await loadLeads();location.hash='#/leads';state.selectedLead=null;notice('Đã lưu Lead.');}
    catch(error){const alert=form.querySelector('.form-error');alert.hidden=false;alert.textContent=error.message;button.disabled=false;}
  };
}

function leadDetailView() {
  const lead=state.selectedLead,detail=state.leadDetail,company=state.profile.company_id;
  const canEditLead=can('lead.edit')&&(isManager()||detail.assignments.includes(state.profile.id));
  const line=(label,value)=>`<div class="lead-detail-line"><span>${label}</span><strong>${escaped(value??'—')}</strong></div>`;
  const multiline=(value)=>`<div class="lead-long-text">${escaped(value||'—')}</div>`;
  const input=(key,label,type='text')=>`<label class="create-field"><span>${label}</span><input name="${key}" type="${type}" value="${escaped(lead[key]??'')}"></label>`;
  const reasonDraft={failure_reason:lead.failure_reason||null};
  const cardHead=(title,group)=>`<div class="lead-card-head"><h2>${title}</h2>${canEditLead?`<button class="ghost" type="button" data-edit="${group}">Chỉnh sửa</button>`:''}</div>`;
  const assigneeName=id=>detail.names.get(id)||state.leadList.staff.find(user=>user.id===id)?.full_name||'Nhân viên';
  const assigneeRows=detail.assignments.map(id=>`<div class="lead-detail-person"><span class="lead-avatar">${escaped(initials(assigneeName(id)))}</span><span>${escaped(assigneeName(id))}</span>${can('lead.assign')&&!detail.assigneeError?`<button type="button" data-remove-person="${id}" aria-label="Gỡ ${escaped(assigneeName(id))}">×</button>`:''}</div>`).join('')||(detail.assigneeError?'':'<p class="muted">Chưa phân công</p>');
  shell(`<div class="lead-detail-page"><nav class="lead-breadcrumb"><a href="#/leads">Lead</a> › <a href="#/leads">Danh sách Lead</a> › Chi tiết Lead</nav>
    <div class="lead-detail-heading"><div><h1>Lead #${lead.lead_number} <span class="badge lead-status-${Math.max(0,leadStatuses.indexOf(lead.status))}">${escaped(lead.status)}</span></h1><p>Ngày tạo: ${leadDateTime(lead.created_at)}　|　Cập nhật: ${leadDateTime(lead.updated_at)}　|　Tạo bởi: ${escaped(detail.creator)}</p></div>${can('project.create')?`<button type="button" class="ghost lead-project-entry" id="detail-create-project">✎　Chuyển thành dự án</button>`:''}</div>
    <div class="lead-detail-grid"><section class="lead-detail-card">${cardHead('Thông tin khách hàng','customer')}<div id="customer-card">${line('Tên khách hàng',lead.customer_name)}${line('Điện thoại',lead.phone)}${line('Email',lead.email)}${line('Zalo / Facebook',lead.zalo)}${line('Địa chỉ khách hàng',lead.address)}${line('Tỉnh/Thành phố',lead.province)}<div class="lead-detail-block"><span>Ghi chú</span>${multiline(lead.notes)}</div></div></section>
      <section class="lead-detail-card">${cardHead('Thông tin nhu cầu','needs')}<div id="needs-card">${line('Loại thực hiện',(lead.execution_types||[]).join(', '))}${line('Loại công trình',lead.building_type)}${line('Ngân sách',vnd(lead.budget))}${line('Nguồn 1',lead.source)}${line('Nguồn 2',lead.source_2)}${line('Nguồn 3',lead.source_3)}<div class="lead-detail-block"><span>Nhu cầu khách hàng</span>${multiline(lead.customer_requirements)}</div></div></section>
      <div class="lead-detail-right"><section class="lead-detail-card"><div class="lead-card-head"><h2>Trạng thái và lý do</h2></div><label class="create-field">Trạng thái Sale<select id="detail-status" ${canEditLead?'':'disabled'}>${leadStatuses.map(status=>`<option ${lead.status===status?'selected':''}>${status}</option>`).join('')}</select></label>${pickerHtml('failure_reason',reasonDraft,canEditLead)}<p class="lead-card-error" role="alert" hidden></p></section>
        <section class="lead-detail-card"><div class="lead-card-head"><h2>Người phụ trách</h2></div>${detail.assigneeError?`<p class="alert">${escaped(detail.assigneeError)}</p>`:''}<div id="detail-assignees">${assigneeRows}</div>${can('lead.assign')&&!detail.assigneeError?`<details class="lead-add-person"><summary>＋　Thêm người phụ trách</summary><input type="search" placeholder="Tìm nhân viên Sale..." aria-label="Tìm nhân viên Sale"><div>${state.leadList.staff.filter(user=>!detail.assignments.includes(user.id)).map(user=>`<button type="button" data-add-person="${user.id}">${escaped(user.full_name)}</button>`).join('')||'<p class="muted">Không còn nhân viên Sale.</p>'}</div></details>`:''}<p class="lead-card-error" role="alert" hidden></p></section>
        <section class="lead-detail-card"><div class="lead-card-head"><h2>Thông tin hệ thống</h2></div>${line('Người tạo',detail.creator)}${line('Ngày tạo',leadDateTime(lead.created_at))}${line('Ngày cập nhật',leadDateTime(lead.updated_at))}</section></div></div>
    <nav class="lead-tabs lead-detail-tabs" aria-label="Thông tin Lead">${[['care','Hoạt động chăm khách'],['quotes','Báo giá'],['history','Lịch sử']].map(([key,label])=>`<button type="button" data-detail-tab="${key}" class="${detail.tab===key?'active':''}">${label}</button>`).join('')}</nav><section class="lead-detail-tab" id="detail-tab-content"></section></div>`);
  document.querySelector('#detail-create-project')?.addEventListener('click',()=>createProject(lead.id));
  document.querySelectorAll('[data-edit]').forEach(button=>button.onclick=()=>leadEditCard(button.dataset.edit));
  const status=document.querySelector('#detail-status'),reasonPicker=document.querySelector('[data-picker="failure_reason"]');
  const showError=(element,error)=>{const box=element.closest('.lead-detail-card').querySelector('.lead-card-error');box.textContent=error.message;box.hidden=false;};
  let reasonControl;
  reasonControl=bindManagedOption(reasonPicker,{label:'Lý do thất bại',disabled:!canEditLead||lead.status!=='Thất bại',allowAdd:canEditLead&&mayManageOptions('failure_reason'),allowDelete:canEditLead&&mayManageOptions('failure_reason'),
    getOptions:()=>optionValues('failure_reason'),getValue:()=>reasonDraft.failure_reason,getStoredValue:()=>lead.failure_reason,historyLabel:'Đang lưu trên Lead',
    onAdd:label=>addManagedOption('failure_reason',label),onDelete:deleteManagedOption,
    onChange:next=>{const previous=reasonDraft.failure_reason;reasonDraft.failure_reason=next;
      if(!next)return;
      (async()=>{try{await request(`/rest/v1/leads?company_id=eq.${company}&id=eq.${lead.id}`,{method:'PATCH',body:{status:status.value,failure_reason:next}});lead.status=status.value;lead.failure_reason=next;detail.history=null;leadDetailView();}
        catch(error){reasonDraft.failure_reason=previous;reasonControl.render();showError(reasonPicker,error);}})();},
    onError:message=>showError(reasonPicker,new Error(message)),
  });
  status.onchange=async()=>{const previous=lead.status,next=status.value;if(next==='Thất bại'&&!lead.failure_reason){const toggle=reasonPicker.querySelector('.managed-toggle');toggle.disabled=false;toggle.click();return;}status.disabled=true;reasonPicker.querySelector('.managed-toggle').disabled=true;
    try{await request(`/rest/v1/leads?company_id=eq.${company}&id=eq.${lead.id}`,{method:'PATCH',body:{status:next,failure_reason:next==='Thất bại'?lead.failure_reason:null}});lead.status=next;if(next!=='Thất bại')lead.failure_reason=null;detail.history=null;leadDetailView();}
    catch(error){status.value=previous;showError(status,error);status.disabled=!canEditLead;reasonPicker.querySelector('.managed-toggle').disabled=!canEditLead||previous!=='Thất bại';}};
  document.querySelectorAll('[data-add-person],[data-remove-person]').forEach(button=>button.onclick=async()=>{if(detail.assignmentSaving)return;const before=[...detail.assignments],id=button.dataset.addPerson||button.dataset.removePerson;detail.assignmentSaving=true;const controls=[...document.querySelectorAll('[data-add-person],[data-remove-person]')];controls.forEach(item=>item.disabled=true);
    const next=button.dataset.addPerson?[...before,id]:before.filter(item=>item!==id);
    try{await request('/rest/v1/rpc/set_lead_assignees',{method:'POST',body:{p_company:company,p_lead:lead.id,p_users:next}});detail.assignments=next;detail.history=null;const user=state.leadList.staff.find(item=>item.id===id);if(user)detail.names.set(id,user.full_name);leadDetailView();}
    catch(error){detail.assignments=before;controls.forEach(item=>item.disabled=false);showError(button,error);}
    finally{detail.assignmentSaving=false;}});
  document.querySelector('.lead-add-person input')?.addEventListener('input',event=>{const term=event.target.value.toLocaleLowerCase('vi');document.querySelectorAll('[data-add-person]').forEach(button=>button.hidden=!button.textContent.toLocaleLowerCase('vi').includes(term));});
  document.querySelectorAll('[data-detail-tab]').forEach(button=>button.onclick=()=>{detail.tab=button.dataset.detailTab;document.querySelectorAll('[data-detail-tab]').forEach(item=>item.classList.toggle('active',item===button));renderLeadDetailTab();});
  renderLeadDetailTab();
}
function leadDateTime(value){return value?new Intl.DateTimeFormat('vi-VN',{timeZone:'Asia/Ho_Chi_Minh',day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(value)):'—';}
function leadEditCard(group){
  const lead=state.selectedLead,customer=group==='customer',node=document.querySelector(customer?'#customer-card':'#needs-card');
  const draft={province:lead.province||null,source:lead.source||null,building_type:lead.building_type||null,execution_types:[...(lead.execution_types||[])]};
  let provinceChanged=false;
  const text=(name,label,type='text')=>`<label class="create-field">${label}<input name="${name}" type="${type}" value="${escaped(lead[name]??'')}"></label>`;
  node.innerHTML=`<form class="lead-card-form">${customer?`${text('customer_name','Tên khách hàng')}${text('phone','Điện thoại','tel')}${text('email','Email','email')}${text('zalo','Zalo / Facebook')}${text('address','Địa chỉ khách hàng')}${pickerHtml('province',draft,true)}<label class="create-field">Ghi chú<textarea name="notes">${escaped(lead.notes||'')}</textarea></label>`:
    `${pickerHtml('execution_types',draft,true)}${pickerHtml('building_type',draft,true)}${text('budget','Ngân sách','number')}${pickerHtml('source',draft,true)}${text('source_2','Nguồn 2')}${text('source_3','Nguồn 3')}<label class="create-field">Nhu cầu khách hàng<textarea name="customer_requirements" rows="8">${escaped(lead.customer_requirements||'')}</textarea></label>`}<p class="lead-card-error" role="alert" hidden></p><div class="lead-form-actions"><button type="button" class="ghost" data-cancel>Hủy</button><button type="submit" class="primary">Lưu</button></div></form>`;
  const form=node.querySelector('form');document.querySelector(`[data-edit="${group}"]`).hidden=true;
  bindPickers(form,draft,true,key=>{if(key==='province')provinceChanged=true;});
  form.querySelector('[data-cancel]').onclick=()=>leadDetailView();
  form.onsubmit=async event=>{event.preventDefault();const data=new FormData(form),body={};
    for(const key of customer?['customer_name','phone','email','zalo','address','notes']:['budget','source_2','source_3','customer_requirements'])body[key]=data.get(key)||null;
    if(customer&&provinceChanged)body.province=draft.province;
    else{body.building_type=draft.building_type;body.source=draft.source;}
    if(customer&&!String(body.customer_name||'').trim()){const box=form.querySelector('.lead-card-error');box.textContent='Vui lòng nhập tên khách hàng.';box.hidden=false;return;}
    if(!customer){body.execution_types=draft.execution_types;body.budget=body.budget===null?null:Number(body.budget);if(body.budget!==null&&(!Number.isFinite(body.budget)||body.budget<0)){const box=form.querySelector('.lead-card-error');box.textContent='Ngân sách không hợp lệ.';box.hidden=false;return;}}
    const save=form.querySelector('[type=submit]');save.disabled=true;
    try{await request(`/rest/v1/leads?company_id=eq.${state.profile.company_id}&id=eq.${lead.id}`,{method:'PATCH',body});Object.assign(lead,body);lead.updated_at=new Date().toISOString();state.leadDetail.history=null;leadDetailView();}
    catch(error){const box=form.querySelector('.lead-card-error');box.textContent=error.message;box.hidden=false;save.disabled=false;}};
}
async function renderLeadDetailTab(){
  const detail=state.leadDetail,lead=state.selectedLead,node=document.querySelector('#detail-tab-content');if(!node)return;
  if(detail.tab==='care'){
    if(detail.care===null){node.innerHTML='<p class="muted">Đang tải hoạt động…</p>';await loadLeadCare(true);return;}
    const vietnamDay=value=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Ho_Chi_Minh',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(value));
    const today=vietnamDay(new Date());
    const canPost=can('lead.edit')&&(isManager()||detail.assignments.includes(state.profile.id));
    node.innerHTML=`<h2>Hoạt động chăm khách</h2>${canPost?'<form id="lead-care-form" class="lead-care-form"><textarea name="content" aria-label="Nội dung hoạt động chăm khách" placeholder="Nhập nội dung hoạt động chăm khách..." required></textarea><button class="primary" type="submit">Gửi</button></form>':''}<p class="lead-tab-error" role="alert" hidden></p><div class="lead-care-list">${detail.care.map(item=>`<article class="lead-care-item"><time>${leadDateTime(item.created_at)}</time><span class="lead-avatar">${escaped(initials(item.creator_name_snapshot))}</span><strong>${escaped(item.creator_name_snapshot)}</strong><div class="lead-care-content">${escaped(item.content)}</div>${item.created_by===state.profile.id&&vietnamDay(item.created_at)===today?`<button class="ghost danger" type="button" data-delete-care="${item.id}">Xóa</button>`:''}</article>`).join('')||'<p class="muted">Chưa có hoạt động chăm khách.</p>'}</div>${detail.careHasNext?'<button class="ghost" type="button" id="more-care">Xem thêm</button>':''}`;
    const errorBox=node.querySelector('.lead-tab-error');
    node.querySelector('#lead-care-form')?.addEventListener('submit',async event=>{event.preventDefault();const form=event.currentTarget,button=form.querySelector('button'),content=form.elements.content.value.trim();if(!content)return;button.disabled=true;errorBox.hidden=true;
      try{await request('/rest/v1/lead_care_activities',{method:'POST',body:{company_id:state.profile.company_id,lead_id:lead.id,content}});detail.care=null;detail.carePage=0;await renderLeadDetailTab();}
      catch(error){errorBox.textContent=error.message;errorBox.hidden=false;button.disabled=false;}});
    node.querySelectorAll('[data-delete-care]').forEach(button=>button.onclick=async()=>{button.disabled=true;errorBox.hidden=true;
      try{const deleted=await request('/rest/v1/rpc/delete_lead_care_activity',{method:'POST',body:{p_company:state.profile.company_id,p_activity:button.dataset.deleteCare}});if(!deleted)throw new Error('Hoạt động không còn được phép xóa.');detail.care=detail.care.filter(item=>item.id!==button.dataset.deleteCare);renderLeadDetailTab();}
      catch(error){errorBox.textContent=error.message;errorBox.hidden=false;button.disabled=false;}});
    node.querySelector('#more-care')?.addEventListener('click',async event=>{event.currentTarget.disabled=true;detail.carePage++;await loadLeadCare(false);});
    return;
  }
  if(detail.tab==='history'){
    if(detail.history===null){node.innerHTML='<p class="muted">Đang tải lịch sử…</p>';await loadLeadHistory(true);return;}
    const labels={customer_name:'Tên khách hàng',phone:'Điện thoại',email:'Email',zalo:'Zalo/Facebook',address:'Địa chỉ',province:'Tỉnh/Thành phố',source:'Nguồn 1',source_2:'Nguồn 2',source_3:'Nguồn 3',execution_types:'Loại thực hiện',building_type:'Loại công trình',budget:'Ngân sách',customer_requirements:'Nhu cầu khách hàng',notes:'Ghi chú',status:'Trạng thái Sale',failure_reason:'Lý do thất bại'};
    const shown=value=>value===null||value===undefined||value===''?'—':Array.isArray(value)?value.join(', '):String(value);
    const description=item=>{const old=item.old_value||{},next=item.new_value||{};if(!item.action_code.endsWith('_changed'))return item.message;const changes=Object.keys(next).map(key=>`${labels[key]||key}: ${shown(old[key])} → ${shown(next[key])}`);return changes.length?`${item.message}: ${changes.join('; ')}`:item.message;};
    node.innerHTML=`<h2>Lịch sử</h2><p class="lead-tab-error" role="alert" hidden></p>${detail.history.map(item=>`<div class="lead-history-item"><time>${leadDateTime(item.event_at)}</time> · ${escaped(item.actor_name)} · ${escaped(description(item))}</div>`).join('')||'<p class="muted">Chưa có lịch sử thay đổi.</p>'}${detail.historyHasNext?'<button type="button" class="ghost" id="more-history">Xem thêm</button>':''}`;
    node.querySelector('#more-history')?.addEventListener('click',async event=>{event.currentTarget.disabled=true;await loadLeadHistory(false);});
    return;
  }
  node.innerHTML='<p class="muted">Đang tải báo giá…</p>';
  try{const quotes=await request(`/rest/v1/quotes?company_id=eq.${state.profile.company_id}&lead_id=eq.${lead.id}&select=id,quote_number,title,created_at,created_by&order=created_at.desc`);
    const ids=quotes.map(quote=>quote.id),versions=ids.length?await request(`/rest/v1/quote_versions?company_id=eq.${state.profile.company_id}&quote_id=in.(${ids.join(',')})&select=id,quote_id,version_number,total_amount,status,created_at,created_by&order=created_at.desc`):[];
    if(detail.tab!=='quotes'||state.selectedLead?.id!==lead.id)return;
    node.innerHTML=`<h2>Báo giá</h2>${quotes.length?quotes.map(quote=>`<section class="lead-quote"><strong>Báo giá #${quote.quote_number} · ${escaped(quote.title)}</strong>${versions.filter(version=>version.quote_id===quote.id).map(version=>`<div>V${version.version_number} · ${leadDateTime(version.created_at)} · ${escaped(vnd(version.total_amount))} · ${escaped(version.status)}</div>`).join('')||'<p class="muted">Chưa có phiên bản.</p>'}</section>`).join(''):'<p class="muted">Chưa có báo giá.</p>'}<p class="muted">Chưa có route tạo hoặc chi tiết báo giá trong ứng dụng hiện tại.</p>`;
  }catch(error){if(detail.tab==='quotes')node.innerHTML=`<p class="alert">${escaped(error.message)}</p>`;}
}
async function loadLeadCare(reset){
  const detail=state.leadDetail,lead=state.selectedLead,node=document.querySelector('#detail-tab-content');
  const page=reset?0:detail.carePage;
  try{const rows=await request(`/rest/v1/lead_care_activities?company_id=eq.${state.profile.company_id}&lead_id=eq.${lead.id}&select=id,content,created_by,creator_name_snapshot,created_at&order=created_at.desc,id.desc&limit=51&offset=${page*50}`);
    if(state.selectedLead?.id!==lead.id||detail.tab!=='care')return;
    detail.care=reset?rows.slice(0,50):[...(detail.care||[]),...rows.slice(0,50)];detail.careHasNext=rows.length>50;renderLeadDetailTab();}
  catch(error){if(node&&detail.tab==='care')node.innerHTML=`<p class="alert">${escaped(error.message)}</p><button type="button" class="ghost" id="retry-care">Thử lại</button>`;node?.querySelector('#retry-care')?.addEventListener('click',()=>loadLeadCare(true));}
}
async function loadLeadHistory(reset){
  const detail=state.leadDetail,lead=state.selectedLead,node=document.querySelector('#detail-tab-content');
  const last=reset?null:detail.history?.at(-1);
  try{const rows=await request('/rest/v1/rpc/get_lead_history',{method:'POST',body:{p_company:state.profile.company_id,p_lead:lead.id,p_limit:51,p_before_at:last?.event_at||null,p_before_id:last?.event_id||null}});
    if(state.selectedLead?.id!==lead.id||detail.tab!=='history')return;
    detail.history=reset?rows.slice(0,50):[...(detail.history||[]),...rows.slice(0,50)];detail.historyHasNext=rows.length>50;renderLeadDetailTab();}
  catch(error){if(node&&detail.tab==='history')node.innerHTML=`<p class="alert">${escaped(error.message)}</p><button type="button" class="ghost" id="retry-history">Thử lại</button>`;node?.querySelector('#retry-history')?.addEventListener('click',()=>loadLeadHistory(true));}
}
function detailView() {
  const project = state.selected;
  shell(`<div class="detail"><button class="back" id="back">← Tất cả dự án</button>
    <section class="detail-card"><div class="detail-head"><div><span class="badge ${project.is_hidden ? 'hidden' : ''}">${project.is_hidden ? 'Đã ẩn' : escaped(project.status)}</span>
      <h2>${escaped(project.name)}</h2><div class="muted">Dự án #${escaped(project.project_number)}</div></div>
      ${isManager() ? `<button class="${project.is_hidden ? 'primary' : 'ghost danger'}" id="toggle-hidden" ${state.busy ? 'disabled' : ''}>${project.is_hidden ? 'Bỏ ẩn dự án' : 'Ẩn dự án'}</button>` : ''}</div>
    <dl class="details"><div><dt>Trạng thái</dt><dd>${escaped(project.status)}</dd></div><div><dt>Tiến độ</dt><dd>${escaped(project.progress_percent)}%</dd></div>
      <div><dt>Địa chỉ</dt><dd>${escaped(project.project_address || 'Chưa cập nhật')}</dd></div><div><dt>Hạn hoàn thành</dt><dd>${date(project.deadline)}</dd></div>
      <div><dt>Mã Lead nguồn</dt><dd>${escaped(project.source_lead_id)}</dd></div><div><dt>Cập nhật lần cuối</dt><dd>${date(project.updated_at)}</dd></div></dl>
    <section class="project-extra"><h3>Phân loại và ngân sách</h3>
      <div id="project-options">${pickerHtml('execution_types',{execution_types:project.execution_types||[]},can('project.edit'))}${pickerHtml('building_type',{building_type:project.building_type||null},can('project.edit'))}</div>
      ${can('project.edit')?'<button type="button" class="ghost" id="save-project-types">Lưu phân loại</button>':''}
      <div class="budget-fields"><label class="field">Ngân sách (VND)<input type="number" min="0" data-budget="project" value="${state.projectBudget??''}" ${state.canEditProjectBudget?'':'disabled'}></label>${state.canEditProjectBudget?'<button class="ghost" type="button" data-save-budget>Lưu ngân sách</button>':''}</div>
      <div class="alert extra-error" hidden></div></section>
    <div class="note">${project.is_hidden ? 'Project này chỉ Owner/Admin xem được. Dữ liệu vẫn được giữ nguyên và vẫn tính vào quota.' : 'Quyền xem dự án và dữ liệu liên quan được kiểm tra theo Role và thành viên.'}</div>
    </section></div>`);
  document.querySelector('#back').addEventListener('click', () => { state.selected = null; state.error = ''; state.message = ''; render(); });
  document.querySelector('#toggle-hidden')?.addEventListener('click', () => confirmToggle(project));
  const draft={execution_types:[...(project.execution_types||[])],building_type:project.building_type||null};
  bindPickers(document.querySelector('#project-options'),draft,can('project.edit'));
  const showError=error=>{const box=document.querySelector('.extra-error');box.hidden=false;box.textContent=error.message;};
  document.querySelector('#save-project-types')?.addEventListener('click',async()=>{
    try{await request(`/rest/v1/projects?company_id=eq.${state.profile.company_id}&id=eq.${project.id}`,{method:'PATCH',body:{execution_types:draft.execution_types,building_type:draft.building_type}});await loadSelected(project.id);}
    catch(error){showError(error);}
  });
  document.querySelector('[data-save-budget]')?.addEventListener('click',async event=>{const button=event.currentTarget,field=document.querySelector('[data-budget="project"]');button.disabled=true;try{await request('/rest/v1/rpc/set_project_budget',{method:'POST',body:{p_company:state.profile.company_id,p_project:project.id,p_budget:field.value===''?null:Number(field.value)}});await loadSelected(project.id);}catch(error){showError(error);button.disabled=false;}});
}
function confirmToggle(project) {
  const hide = !project.is_hidden;
  const backdrop = document.createElement('div'); backdrop.className = 'dialog-backdrop';
  backdrop.innerHTML = `<div class="dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title">
    <h2 id="dialog-title">${hide ? 'Ẩn dự án?' : 'Bỏ ẩn dự án?'}</h2>
    <p>${hide ? 'Chỉ Owner/Admin sẽ tiếp tục xem được dự án và dữ liệu liên quan. Dự án vẫn tính vào quota.' : 'Những thành viên đang có quyền sẽ xem lại được dự án và dữ liệu liên quan.'}</p>
    <div class="dialog-actions"><button class="ghost" id="cancel">Hủy</button><button class="${hide ? 'ghost danger' : 'primary'}" id="confirm">${hide ? 'Ẩn dự án' : 'Bỏ ẩn'}</button></div></div>`;
  root.append(backdrop); backdrop.querySelector('#cancel').focus();
  const close = () => backdrop.remove();
  backdrop.querySelector('#cancel').addEventListener('click', close);
  backdrop.addEventListener('click', event => { if (event.target === backdrop) close(); });
  backdrop.addEventListener('keydown', event => { if (event.key === 'Escape') close(); });
  backdrop.querySelector('#confirm').addEventListener('click', async event => {
    event.target.disabled = true;
    try {
      await request('/rest/v1/rpc/set_project_hidden', { method: 'POST', body: {
        p_company: state.profile.company_id, p_project: project.id, p_hidden: hide,
      } });
      close(); state.error = ''; state.message = hide ? 'Đã ẩn dự án.' : 'Đã bỏ ẩn dự án.';
      await loadProjects(); if(state.selected) await loadSelected(project.id); else render();
    } catch (error) { close(); notice(error.message, true); }
  });
}
function render() {
  if (!state.profile) return loginView();
  if(state.mode==='leads')return state.selectedLead?(state.selectedLead.id?leadDetailView():createLeadView()):leadListView();
  if (state.selected) return detailView();
  listView();
}
try {
  const response = await fetch('/config');
  if (!response.ok) throw new Error('Không thể kết nối cấu hình ứng dụng local.');
  state.config = await response.json();
  if (state.session) { try { await loadProfile();
    const leadRoute=location.hash.match(/^#\/leads(?:\/(new|[0-9a-f-]{36}))?$/i);
    if(leadRoute){state.mode='leads';await loadLeadStaff();if(leadRoute[1]==='new')state.selectedLead={execution_types:[],status:'Mới'};
      else if(leadRoute[1])await openLead(leadRoute[1]);else await loadLeads();}
    else await loadProjects();
  } catch (error) {
    setSession(null); state.profile = null; state.error = error.message;
  } }
  render();
} catch (error) { root.innerHTML = `<div class="loading">${escaped(error.message)}</div>`; }
