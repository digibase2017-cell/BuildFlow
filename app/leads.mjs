export const leadTabs = [
  ['all', 'Tất cả', null],
  ['new', 'Mới', 'Mới'],
  ['caring', 'Đang chăm sóc', 'Đang chăm sóc'],
  ['meeting', 'Đã hẹn gặp', 'Đã hẹn gặp'],
  ['quoted', 'Đã báo giá', 'Đã báo giá'],
  ['won', 'Thành công', 'Thành công'],
  ['lost', 'Thất bại', 'Thất bại'],
  ['latest', 'Hoạt động mới nhất', null],
];

const accentGroups = [
  'aàáảãạăằắẳẵặâầấẩẫậ', 'eèéẻẽẹêềếểễệ',
  'iìíỉĩị', 'oòóỏõọôồốổỗộơờớởỡợ',
  'uùúủũụưừứửữự', 'yỳýỷỹỵ', 'dđ',
];
const groupFor = new Map(accentGroups.flatMap(group => [...group].map(char => [char, group])));

export function accentPattern(term) {
  return [...term.normalize('NFC').toLocaleLowerCase('vi').trim()]
    .map(char => {
      const group = groupFor.get(char);
      if (group) return `[${group}]`;
      if (/\s/.test(char)) return '[[:space:]]+';
      return char.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }).join('');
}

export function leadQuery({ companyId, tab = 'all', search = '', source = '', buildingType = '', assignee = '', sortId = false, page = 1, pageSize = 50 }) {
  const params = new URLSearchParams();
  const fields = 'id,lead_number,customer_name,phone,source,building_type,execution_types,budget,created_at,status,failure_reason';
  params.set('company_id', `eq.${companyId}`);
  params.set('select', assignee ? `${fields},assignee_filter:lead_assignments!inner(user_id)` : fields);
  params.set('order', tab === 'latest' && sortId ? 'lead_number.asc,id.asc' : 'created_at.desc,id.desc');
  params.set('limit', String(pageSize + 1));
  params.set('offset', String((page - 1) * pageSize));
  const status = leadTabs.find(item => item[0] === tab)?.[2];
  if (status) params.set('status', `eq.${status}`);
  if (source) params.set('source', `eq.${source}`);
  if (buildingType) params.set('building_type', `eq.${buildingType}`);
  if (assignee) {
    params.set('assignee_filter.user_id', `eq.${assignee}`);
    params.set('assignee_filter.unassigned_at', 'is.null');
  }
  const keyword = search.trim();
  if (keyword) {
    const expressions = [`customer_name.imatch.${accentPattern(keyword)}`];
    const digits = keyword.replace(/\s/g, '');
    if (/^[+\d]+$/.test(digits)) expressions.push(`phone.imatch.${[...digits].map(char => char === '+' ? '\\+' : char).join('[[:space:]]*')}`);
    params.set('or', `(${expressions.join(',')})`);
  }
  return `/rest/v1/leads?${params}`;
}

export const vnd = value => value == null ? '—' : `${new Intl.NumberFormat('vi-VN').format(Number(value))} ₫`;

export function firstProjects(rows) {
  const result = new Map();
  for (const project of rows) {
    const previous = result.get(project.source_lead_id);
    if (!previous || project.created_at < previous.created_at ||
      (project.created_at === previous.created_at && project.id < previous.id)) {
      result.set(project.source_lead_id, project);
    }
  }
  return new Map([...result].map(([leadId, project]) => [leadId, project.id]));
}
