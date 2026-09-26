export const statuses = ['Chưa bắt đầu','Đang thực hiện','Tạm dừng','Hoàn thành','Đã hủy'];
export const projectCode = p => String(p.project_number).padStart(2, '0');
let companyTimezone='Asia/Ho_Chi_Minh';
export function setTimezone(value) { new Intl.DateTimeFormat('en',{timeZone:value}).format(); companyTimezone=value; }
export const day = value => !value ? '' : /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : new Date(value).toLocaleDateString('en-CA', {timeZone:companyTimezone});
export function selectProjects(rows, options) {
  const query = options.search.trim().toLocaleLowerCase('vi');
  return rows.filter(p => (options.filter === 'hidden' ? p.is_hidden : !p.is_hidden) &&
    (!options.status || (options.status === 'Quá hạn' ? p.overdue : p.status === options.status)) &&
    (!options.from || day(p.created_at) >= options.from) && (!options.to || day(p.created_at) <= options.to) &&
    `${p.name} ${projectCode(p)} ${p.id} ${p.customer || ''}`.toLocaleLowerCase('vi').includes(query))
    .sort((a,b) => (a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id)) * (options.sort === 'asc' ? 1 : -1));
}
export function periodRange(period, now = new Date()) {
  const end = day(now);
  if (period === 'all' || period === 'custom') return {from:'',to:''};
  const start = new Date(`${end}T00:00:00Z`);
  start.setUTCDate(start.getUTCDate() - Number(period) + 1);
  return {from:start.toISOString().slice(0,10),to:end};
}
export function statistics(rows, from, to, now = new Date()) {
  const visible = rows.filter(p => !p.is_hidden);
  const range = from && to ? {from,to} : periodRange('30',now);
  const length = (Date.parse(range.to)-Date.parse(range.from))/86400000+1;
  const previousTo = new Date(Date.parse(range.from)-86400000).toISOString().slice(0,10);
  const previousFrom = new Date(Date.parse(range.from)-length*86400000).toISOString().slice(0,10);
  const count = (field, start, end) => visible.filter(p => p[field] && (field!=='completed_date'||p.status==='Hoàn thành') && day(p[field]) >= start && day(p[field]) <= end).length;
  const delta = field => {
    const current = count(field,range.from,range.to), previous = count(field,previousFrom,previousTo);
    return previous ? `${current >= previous ? '↑' : '↓'} ${Math.abs((current-previous)/previous*100).toFixed(0)}%` : current ? '—' : '→ 0%';
  };
  return [
    {label:'Tổng dự án',value: from && to ? count('created_at',from,to) : visible.length,trend:delta('created_at'),icon:'▣'},
    {label:'Hoàn thành',value:from && to ? count('completed_date',from,to) : visible.filter(p=>p.status==='Hoàn thành').length,trend:delta('completed_date'),icon:'✓'},
    {label:'Đang thực hiện',value:visible.filter(p=>p.status==='Đang thực hiện').length,icon:'⚒'},
    {label:'Quá hạn',value:visible.filter(p=>p.overdue).length,icon:'!'}];
}
// Minimal OOXML workbook in an uncompressed ZIP. No formulas, macros or external links.
export function excelWorkbook(rows) {
  const enc=new TextEncoder();
  const xml=value=>String(value??'').replace(/[<>&"']/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[c])).replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g,'');
  const values=[['STT','ID','Ngày tạo','Tên dự án','Loại công trình','Tiến độ','Trạng thái','Ngày bắt đầu','Ngày dự kiến HT','Người phụ trách'],...rows.map((p,i)=>[i+1,projectCode(p),day(p.created_at),p.name,p.building_type||'',`${p.progress_percent}%`,p.status+(p.overdue?' · Quá hạn':''),p.start_date,p.deadline,p.responsible])];
  const files={
    '[Content_Types].xml':'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
    '_rels/.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml':'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Danh sách dự án" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/worksheets/sheet1.xml':'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols><col min="1" max="10" width="22" customWidth="1"/></cols><sheetData>'+values.map((row,i)=>`<row r="${i+1}">`+row.map((v,j)=>`<c r="${String.fromCharCode(65+j)}${i+1}" t="inlineStr"><is><t xml:space="preserve">${xml(v)}</t></is></c>`).join('')+'</row>').join('')+'</sheetData></worksheet>'
  };
  const crc32=bytes=>{let crc=0xffffffff;for(const byte of bytes){crc^=byte;for(let k=0;k<8;k++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;};
  const chunks=[],directory=[];let offset=0;
  for(const [name,value] of Object.entries(files)) {
    const filename=enc.encode(name),data=enc.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+value),crc=crc32(data);
    const header=new Uint8Array(30+filename.length),h=new DataView(header.buffer);
    h.setUint32(0,0x04034b50,true);h.setUint16(4,20,true);h.setUint16(12,33,true);h.setUint32(14,crc,true);h.setUint32(18,data.length,true);h.setUint32(22,data.length,true);h.setUint16(26,filename.length,true);header.set(filename,30);
    const central=new Uint8Array(46+filename.length),c=new DataView(central.buffer);
    c.setUint32(0,0x02014b50,true);c.setUint16(4,20,true);c.setUint16(6,20,true);c.setUint16(14,33,true);c.setUint32(16,crc,true);c.setUint32(20,data.length,true);c.setUint32(24,data.length,true);c.setUint16(28,filename.length,true);c.setUint32(42,offset,true);central.set(filename,46);
    chunks.push(header,data);directory.push(central);offset+=header.length+data.length;
  }
  const size=directory.reduce((sum,item)=>sum+item.length,0),end=new Uint8Array(22),e=new DataView(end.buffer);
  e.setUint32(0,0x06054b50,true);e.setUint16(8,directory.length,true);e.setUint16(10,directory.length,true);e.setUint32(12,size,true);e.setUint32(16,offset,true);
  const result=new Uint8Array(offset+size+22);let cursor=0;for(const chunk of [...chunks,...directory,end]){result.set(chunk,cursor);cursor+=chunk.length;}return result;
}
