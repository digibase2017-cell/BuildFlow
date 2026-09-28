// Shared UI for company-managed single and multi-select catalogs.
const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,char=>({
  '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;',
})[char]);
export const foldOption=value=>String(value??'').toLocaleLowerCase('vi').normalize('NFD')
  .replace(/[\u0300-\u036f]/g,'').replace(/đ/g,'d');

export function managedOptionHtml({key,label,addLabel=label.toLowerCase(),searchable=false}) {
  return `<div class="managed-picker" data-picker="${escapeHtml(key)}">
    <label>${escapeHtml(label)}</label>
    <button type="button" class="managed-toggle" aria-label="Mở danh sách ${escapeHtml(label)}" aria-expanded="false"><span class="managed-value"></span><span aria-hidden="true">▾</span></button>
    <div class="managed-dropdown" hidden>
      ${searchable?`<div class="managed-search"><span aria-hidden="true">⌕</span><input type="search" aria-label="Tìm ${escapeHtml(label.toLowerCase())}" placeholder="Tìm ${escapeHtml(label.toLowerCase())}..."></div>`:''}
      <div class="managed-list"></div>
      <button type="button" class="managed-add">＋ Thêm ${escapeHtml(addLabel)}</button>
      <div class="managed-add-row" hidden><input type="text" maxlength="200" aria-label="Tên ${escapeHtml(label.toLowerCase())} mới" placeholder="Tên ${escapeHtml(label.toLowerCase())} mới"><button type="button" class="managed-add-save">Thêm</button></div>
      <p class="managed-error" role="alert" hidden></p>
    </div>
    <p class="managed-history" hidden></p>
  </div>`;
}

let globalEventsReady=false;
function closeMenus(except=null) {
  document.querySelectorAll('.managed-menu:not([hidden])').forEach(menu=>{
    if(menu===except)return;
    menu.hidden=true;menu.previousElementSibling.setAttribute('aria-expanded','false');
  });
}
function closeDropdowns(except=null) {
  document.querySelectorAll('.managed-picker').forEach(picker=>{
    if(picker===except)return;
    const dropdown=picker.querySelector('.managed-dropdown');
    dropdown.hidden=true;picker.querySelector('.managed-toggle').setAttribute('aria-expanded','false');
  });
}
function setupGlobalEvents() {
  if(globalEventsReady)return;globalEventsReady=true;
  document.addEventListener('click',event=>{
    if(!event.target.closest('.managed-more,.managed-menu'))closeMenus();
    if(!event.target.closest('.managed-picker'))closeDropdowns();
  });
  document.addEventListener('keydown',event=>{
    if(event.key!=='Escape')return;
    const open=document.querySelector('.managed-menu:not([hidden])');
    if(open){closeMenus();event.stopPropagation();return;}
    closeDropdowns();
  });
}

export function bindManagedOption(root,config) {
  setupGlobalEvents();
  const toggle=root.querySelector('.managed-toggle'),dropdown=root.querySelector('.managed-dropdown');
  const list=root.querySelector('.managed-list'),search=root.querySelector('.managed-search input');
  const add=root.querySelector('.managed-add'),addRow=root.querySelector('.managed-add-row');
  const addInput=addRow.querySelector('input'),save=addRow.querySelector('button'),error=root.querySelector('.managed-error');
  const multiple=Boolean(config.multiple),placeholder=config.placeholder||`Chọn ${config.label.toLowerCase()}`;
  const rawSelected=()=>multiple?(config.getValue()||[]):(config.getValue()?[config.getValue()]:[]);
  const options=()=>config.getOptions().filter(option=>option.is_active!==false)
    .sort((a,b)=>a.label.localeCompare(b.label,'vi'));
  const selected=()=>rawSelected().filter(value=>options().some(option=>option.label===value));
  const showError=message=>{error.textContent=message;error.hidden=false;config.onError?.(message);};
  const clearError=()=>{error.hidden=true;error.textContent='';};
  const change=value=>{config.onChange(value);render();};
  function render() {
    const values=selected();
    const stored=config.getStoredValue?.();
    const storedValues=stored===undefined?[]:Array.isArray(stored)?stored:stored?[stored]:[];
    const historical=[...new Set([...rawSelected(),...storedValues])].filter(value=>!values.includes(value));
    const history=root.querySelector('.managed-history');
    history.hidden=!historical.length;history.textContent=historical.length?`${config.historyLabel||'Đã lưu trước đây'}: ${historical.join(', ')}`:'';
    root.querySelector('.managed-value').innerHTML=values.length
      ? values.map(value=>`<span class="managed-chip">${escapeHtml(value)}<span class="managed-chip-remove" role="button" tabindex="0" aria-label="Bỏ chọn ${escapeHtml(value)}" data-value="${escapeHtml(value)}">×</span></span>`).join('')
      : `<span class="managed-placeholder">${escapeHtml(placeholder)}</span>`;
    const query=foldOption(search?.value.trim());
    const visible=options().filter(option=>!query||foldOption(option.label).includes(query));
    list.innerHTML=visible.length?visible.map(option=>`<div class="managed-option ${values.includes(option.label)?'is-selected':''}">
      <button type="button" class="managed-choice" data-value="${escapeHtml(option.label)}" aria-pressed="${values.includes(option.label)}"><span class="managed-check" aria-hidden="true">${values.includes(option.label)?'☑':'☐'}</span><span>${escapeHtml(option.label)}</span></button>
      ${config.allowDelete?`<button type="button" class="managed-more" data-id="${escapeHtml(option.id)}" aria-label="Quản lý ${escapeHtml(option.label)}" aria-haspopup="menu" aria-expanded="false">⋮</button><div class="managed-menu" role="menu" hidden><button type="button" class="managed-delete" role="menuitem" data-id="${escapeHtml(option.id)}" data-value="${escapeHtml(option.label)}">🗑 Xóa khỏi danh sách</button></div>`:''}
    </div>`).join(''):'<p class="managed-empty">Không có lựa chọn phù hợp.</p>';
    add.hidden=!config.allowAdd;toggle.disabled=Boolean(config.disabled);
  }
  toggle.addEventListener('click',()=>{
    const opening=dropdown.hidden;closeDropdowns(root);closeMenus();
    dropdown.hidden=!opening;toggle.setAttribute('aria-expanded',String(opening));
  });
  root.querySelector('.managed-value').addEventListener('click',event=>{
    const remove=event.target.closest('.managed-chip-remove');if(!remove)return;
    event.stopPropagation();const value=remove.dataset.value;
    change(multiple?selected().filter(item=>item!==value):null);
  });
  root.querySelector('.managed-value').addEventListener('keydown',event=>{
    if(!['Enter',' '].includes(event.key)||!event.target.matches('.managed-chip-remove'))return;
    event.preventDefault();event.stopPropagation();
    const value=event.target.dataset.value;change(multiple?selected().filter(item=>item!==value):null);
  });
  search?.addEventListener('input',()=>{closeMenus();render();});
  list.addEventListener('scroll',()=>closeMenus());
  list.addEventListener('click',async event=>{
    const more=event.target.closest('.managed-more');
    if(more){event.stopPropagation();const menu=more.nextElementSibling,opening=menu.hidden;closeMenus();menu.hidden=!opening;more.setAttribute('aria-expanded',String(opening));
      if(opening){const rect=more.getBoundingClientRect();menu.style.top=`${rect.bottom+2}px`;menu.style.right=`${Math.max(4,innerWidth-rect.right)}px`;}
      return;}
    const choice=event.target.closest('.managed-choice');
    if(choice){event.stopPropagation();const value=choice.dataset.value,current=selected();change(multiple?(current.includes(value)?current.filter(item=>item!==value):[...current,value]):(current.includes(value)?null:value));return;}
    const remove=event.target.closest('.managed-delete');
    if(remove){remove.disabled=true;clearError();const wasSelected=selected().includes(remove.dataset.value);
      try{await config.onDelete(remove.dataset.id);closeMenus();const value=remove.dataset.value;
        if(wasSelected)config.onChange(multiple?rawSelected().filter(item=>item!==value):null);
        render();}
      catch(cause){remove.disabled=false;showError(cause.message);}}
  });
  add.addEventListener('click',()=>{addRow.hidden=false;addInput.focus();});
  save.addEventListener('click',async()=>{
    const label=addInput.value.trim();if(!label){showError('Vui lòng nhập tên lựa chọn.');return;}
    save.disabled=true;clearError();
    try{await config.onAdd(label);const value=options().find(option=>foldOption(option.label)===foldOption(label))?.label||label;
      config.onChange(multiple?[...new Set([...selected(),value])]:value);
      addInput.value='';addRow.hidden=true;search&&(search.value='');render();}
    catch(cause){showError(cause.message);}finally{save.disabled=false;}
  });
  addInput.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();save.click();}});
  render();
  return {render};
}
