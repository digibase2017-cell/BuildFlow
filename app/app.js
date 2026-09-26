import {setTimezone, statuses, projectCode, day, selectProjects, periodRange, statistics, excelWorkbook} from '/projects.mjs';
const root = document.querySelector('#app');
const state = { config: null, session: null, profile: null, role: null, projects: [], selected: null, selectedLead: null, leadProjectBudgets: [], mode: 'projects', leads: [], options: [], permissions: new Set(), canWrite: false,
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
    if(state.permissions.has('lead.view')) {
      try {const budgets=await request('/rest/v1/rpc/lead_project_budgets',{method:'POST',body:{p_company:state.profile.company_id,p_lead:state.selected.source_lead_id}});
        const entry=budgets.find(item=>item.project_id===id);if(entry){state.projectBudget=entry.budget;state.canEditProjectBudget=entry.can_edit;}}
      catch(error){if(!(state.permissions.has('financial.view')||isManager()))throw error;}
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
  root.innerHTML=`<div class="shell ${state.collapsed?'collapsed':''}"><aside class="sidebar"><div class="brand" aria-label="Build Flow">Build<span>Flow</span></div><nav aria-label="Điều hướng chính">${menu.map(([icon,label])=>`<button class="nav-item ${(label==='Dự án'&&state.mode==='projects')||(label==='Lead'&&state.mode==='leads')?'active':''} ${['Thư viện hạng mục','Nhân sự'].includes(label)?'divider':''}" ${(label==='Dự án'||(label==='Lead'&&(state.permissions.has('lead.view')||isManager())))?'aria-current="page"':'disabled title="Chức năng chưa được triển khai"'} data-nav="${label}"><span class="nav-icon">${icon}</span><span class="nav-label">${label}</span></button>`).join('')}</nav><button class="collapse" id="collapse" aria-label="Thu gọn hoặc mở rộng sidebar">‹ <span class="nav-label">Thu gọn</span></button></aside><main class="main"><header class="topbar"><div class="top-actions"><button class="icon-button" id="reload" aria-label="Tải lại dữ liệu">↻</button><span class="avatar">${escaped(initials(state.profile.full_name))}</span><div>${person}<small>${escaped(state.role||'Thành viên')}</small></div><button class="icon-button" id="logout" aria-label="Đăng xuất" title="Đăng xuất">⇥</button></div></header><div class="content">${state.error?`<div class="alert" role="alert">${escaped(state.error)} <button id="retry">Thử lại</button></div>`:''}${state.message?`<div class="alert success" role="status">${escaped(state.message)}</div>`:''}${content}</div></main></div>`;
  document.querySelectorAll('[data-nav]').forEach(button=>button.onclick=async()=>{
    if(button.disabled)return;
    state.mode=button.dataset.nav==='Lead'?'leads':'projects';state.selected=null;state.selectedLead=null;state.error='';
    try{if(state.mode==='leads')await loadLeads();else await loadProjects();}catch(error){state.error=error.message;}render();
  });
  document.querySelector('#collapse').onclick=()=>{state.collapsed=!state.collapsed;render();};
  document.querySelector('#logout').onclick=async()=>{
    if(state.session?.access_token)await raw('/auth/v1/logout',{method:'POST',token:state.session.access_token}).catch(()=>{});
    setSession(null);state.profile=null;state.projects=[];state.leads=[];state.selected=null;state.selectedLead=null;state.error='';state.message='';render();
  };
  const reload=async()=>{state.error='';try{await loadProfile();if(state.mode==='leads')await loadLeads();else await loadProjects();}catch(error){state.error=error.message;}render();};
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
  document.querySelector('#create')?.addEventListener('click',createProject);
  document.querySelector('#export').onclick=async()=>{
    try {await loadProjects();const rows=selectProjects(state.projects,state);const url=URL.createObjectURL(new Blob([excelWorkbook(rows)],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}));const a=document.createElement('a');a.href=url;a.download='Build-Flow-Du-an.xlsx';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);render();}catch(error){notice(error.message,true);}
  };
}

async function createProject() {
  try {
    const leads=(await allRows('leads','id,lead_number,customer_name,status')).filter(l=>l.status==='Thành công');
    const backdrop=document.createElement('div');backdrop.className='dialog-backdrop';
    backdrop.innerHTML=`<form class="dialog" role="dialog" aria-modal="true" aria-labelledby="create-title"><h2 id="create-title">Tạo dự án từ Lead</h2><label class="field">Lead thành công<select name="lead" required><option value="">Chọn Lead</option>${leads.map(l=>`<option value="${l.id}">#${l.lead_number} · ${escaped(l.customer_name)}</option>`).join('')}</select></label><label class="field">Tên dự án<input name="name" required maxlength="250"></label><label class="field">Địa chỉ công trình<input name="address"></label><fieldset><legend>Module dự án</legend>${[['design','Thiết kế'],['purchasing','Mua hàng'],['production','Sản xuất'],['construction','Thi công']].map(([v,t])=>`<label><input type="checkbox" name="${v}"> ${t}</label>`).join(' ')}</fieldset><p>Nghiệm thu và Thanh toán luôn có trong dự án.</p><div class="alert form-error" hidden></div><div class="dialog-actions"><button type="button" class="ghost" id="cancel-create">Hủy</button><button class="primary" type="submit" ${!leads.length?'disabled':''}>Tạo dự án</button></div></form>`;
    root.append(backdrop);const form=backdrop.querySelector('form');form.elements.lead.focus();
    const close=()=>backdrop.remove();backdrop.querySelector('#cancel-create').onclick=close;
    backdrop.onkeydown=e=>{if(e.key==='Escape')close();};
    form.onsubmit=async e=>{e.preventDefault();const submit=form.querySelector('[type=submit]');submit.disabled=true;
      try {await request('/rest/v1/rpc/create_project_from_lead',{method:'POST',body:{p_company:state.profile.company_id,p_lead:form.elements.lead.value,p_name:form.elements.name.value.trim(),p_project_address:form.elements.address.value.trim()||null,p_has_design:form.elements.design.checked,p_has_purchasing:form.elements.purchasing.checked,p_has_production:form.elements.production.checked,p_has_construction:form.elements.construction.checked}});close();state.filter='active';state.page=1;await loadProjects();notice('Đã tạo dự án.');}
      catch(error){const alert=form.querySelector('.form-error');alert.hidden=false;alert.textContent=error.message;submit.disabled=false;}
    };
  }catch(error){notice(error.message,true);}
}

function can(code) { return state.canWrite && state.permissions?.has(code); }
async function loadOptions() {
  state.options=await allRows('lead_options','id,kind,label,is_active');
}
async function loadLeads() {
  state.leads=await allRows('leads','*');
  state.leads.sort((a,b)=>b.created_at.localeCompare(a.created_at)||b.id.localeCompare(a.id));
}
const leadStatuses=['Mới tiếp nhận','Đã liên hệ','Đã gửi báo giá','Đàm phán','Thành công','Thất bại'];
const pickerKind={source:'source',execution_types:'execution_type',building_type:'building_type',failure_reason:'failure_reason'};
const pickerTitle={source:'Nguồn',execution_types:'Loại thực hiện',building_type:'Loại công trình',failure_reason:'Lý do thất bại'};
function pickerHtml(key,draft,editable) {
  const current=draft[key],selected=Array.isArray(current)?current:current?[current]:[];
  const choices=state.options.filter(o=>o.kind===pickerKind[key]&&o.is_active);
  return `<div class="option-picker" data-picker="${key}"><label>${pickerTitle[key]}</label><button type="button" class="picker-toggle" ${editable?'':'disabled'}>${selected.length?selected.map(escaped).join(', '):'Chọn '+pickerTitle[key].toLowerCase()} ▾</button><div class="picker-menu" hidden>
    ${selected.length&&!Array.isArray(current)?'<button type="button" class="picker-clear">Bỏ chọn</button>':''}
    ${choices.map(o=>`<div class="picker-row"><button type="button" class="picker-choice" data-choice="${escaped(o.label)}" aria-pressed="${selected.includes(o.label)}">${selected.includes(o.label)?'✓ ':''}${escaped(o.label)}</button>${editable?`<button type="button" class="picker-remove" data-option="${o.id}" aria-label="Xóa lựa chọn ${escaped(o.label)}">×</button>`:''}</div>`).join('')}
    ${editable?'<button type="button" class="picker-add">＋ Thêm lựa chọn</button>':''}</div></div>`;
}
function bindPickers(container,draft,editable,onChange=()=>{}) {
  const showPickerError=error=>{
    const box=container.querySelector('.form-error')||container.closest('.project-extra')?.querySelector('.extra-error');
    if(box){box.hidden=false;box.textContent=error.message;}else notice(error.message,true);
  };
  for(const old of container.querySelectorAll('[data-picker]')) {
    let picker=old,key=picker.dataset.picker;
    const update=(keepOpen=false)=>{const fresh=document.createElement('div');fresh.innerHTML=pickerHtml(key,draft,editable);if(keepOpen)fresh.querySelector('.picker-menu').hidden=false;picker.replaceWith(fresh.firstElementChild);bindPickers(container,draft,editable,onChange);onChange();};
    picker.querySelector('.picker-toggle').onclick=()=>{picker.querySelector('.picker-menu').hidden=!picker.querySelector('.picker-menu').hidden;};
    picker.querySelector('.picker-clear')?.addEventListener('click',()=>{draft[key]=null;update();});
    picker.querySelectorAll('[data-choice]').forEach(button=>button.onclick=()=>{
      const label=button.dataset.choice;
      draft[key]=key==='execution_types'?(draft[key].includes(label)?draft[key].filter(v=>v!==label):[...draft[key],label]):label;
      update();
    });
    picker.querySelector('.picker-add')?.addEventListener('click',async()=>{
      const label=prompt('Tên lựa chọn mới:')?.trim();if(!label)return;
      try{await request('/rest/v1/rpc/add_lead_option',{method:'POST',body:{p_company:state.profile.company_id,p_kind:pickerKind[key],p_label:label}});await loadOptions();update(true);}
      catch(error){showPickerError(error);}
    });
    picker.querySelectorAll('[data-option]').forEach(button=>button.onclick=async()=>{
      if(!confirm('Xóa khỏi danh sách chọn? Nội dung đã dùng vẫn được giữ.'))return;
      try{await request('/rest/v1/rpc/archive_lead_option',{method:'POST',body:{p_company:state.profile.company_id,p_option:button.dataset.option}});await loadOptions();update(true);}
      catch(error){showPickerError(error);}
    });
  }
}
function leadListView() {
  shell(`<section class="page-heading"><div><h1>Lead</h1><p>Thông tin khách hàng và quá trình chăm sóc.</p></div>${can('lead.create')?'<button id="new-lead" class="primary">＋ Tạo Lead</button>':''}</section>
    <section class="table-card"><div class="table-scroll"><table class="lead-table"><thead><tr><th>Số Lead</th><th>Khách hàng</th><th>Nguồn</th><th>Loại thực hiện</th><th>Loại công trình</th><th>Trạng thái Sale</th><th>Lý do thất bại</th></tr></thead><tbody>${state.leads.map(l=>`<tr><td>${l.lead_number}</td><td><button type="button" class="project-link" data-lead="${l.id}">${escaped(l.customer_name)}</button></td><td>${escaped(l.source||'—')}</td><td>${escaped((l.execution_types||[]).join(', ')||'—')}</td><td>${escaped(l.building_type||'—')}</td><td>${escaped(l.status)}</td><td>${escaped(l.failure_reason||'—')}</td></tr>`).join('')||'<tr><td colspan="7" class="empty">Chưa có Lead trong phạm vi bạn được xem.</td></tr>'}</tbody></table></div></section>`);
  document.querySelector('#new-lead')?.addEventListener('click',()=>{state.selectedLead={execution_types:[],status:'Mới tiếp nhận'};render();});
  document.querySelectorAll('[data-lead]').forEach(button=>button.onclick=async()=>{state.selectedLead=state.leads.find(l=>l.id===button.dataset.lead);state.leadProjectBudgets=[];render();try{state.leadProjectBudgets=await request('/rest/v1/rpc/lead_project_budgets',{method:'POST',body:{p_company:state.profile.company_id,p_lead:state.selectedLead.id}});render();}catch(error){state.error=error.message;render();}});
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
    ${existing?`<section class="project-extra"><h3>Ngân sách Project từ Lead này</h3>${state.leadProjectBudgets.length?state.leadProjectBudgets.map(p=>`<div class="budget-fields"><label class="field">Dự án #${p.project_number} · Ngân sách (VND)<input type="number" min="0" data-lead-project-budget="${p.project_id}" value="${p.budget??''}" ${p.can_edit?'':'disabled'}></label>${p.can_edit?`<button type="button" class="ghost" data-save-lead-project-budget="${p.project_id}">Lưu ngân sách</button>`:''}</div>`).join(''):'<p class="muted">Chưa có Project liên kết.</p>'}<div class="alert budget-error" hidden></div></section>`:''}</section></div>`);
  document.querySelector('#back-leads').onclick=()=>{state.selectedLead=null;render();};
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
    try{await request(existing?`/rest/v1/leads?company_id=eq.${state.profile.company_id}&id=eq.${lead.id}`:'/rest/v1/leads',{method:existing?'PATCH':'POST',body});await loadLeads();state.selectedLead=null;notice('Đã lưu Lead.');}
    catch(error){const alert=form.querySelector('.form-error');alert.hidden=false;alert.textContent=error.message;button.disabled=false;}
  };
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
  if(state.mode==='leads')return state.selectedLead?leadFormView():leadListView();
  if (state.selected) return detailView();
  listView();
}
try {
  const response = await fetch('/config');
  if (!response.ok) throw new Error('Không thể kết nối cấu hình ứng dụng local.');
  state.config = await response.json();
  if (state.session) { try { await loadProfile(); await loadProjects(); } catch (error) {
    setSession(null); state.profile = null; state.error = error.message;
  } }
  render();
} catch (error) { root.innerHTML = `<div class="loading">${escaped(error.message)}</div>`; }
