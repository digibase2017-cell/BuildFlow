import assert from 'node:assert/strict';

// Called only inside the reset-guarded local integration harness.
export async function testQuoteSources({ owner, foreignClient, company, other, check }) {
  async function rejected(sql, values, code, name, constraint) {
    await assert.rejects(owner.query(sql, values), e => e.code === code && (!constraint || e.constraint === constraint), name);
    check(true, name);
  }
  const lead = (await owner.query("INSERT INTO public.leads(company_id,customer_name,status) VALUES ($1,'Source customer','Thành công') RETURNING id", [company])).rows[0].id;
  const secondLead = (await owner.query("INSERT INTO public.leads(company_id,customer_name,status) VALUES ($1,'Different customer','Thành công') RETURNING id", [company])).rows[0].id;
  const project = (await owner.query("SELECT public.create_project_from_lead($1,$2,'Source A',NULL,false,true,true,true) AS id", [company, lead])).rows[0].id;
  const sibling = (await owner.query("SELECT public.create_project_from_lead($1,$2,'Source B',NULL,false,true,true,true) AS id", [company, lead])).rows[0].id;
  const wrongProject = (await owner.query("SELECT public.create_project_from_lead($1,$2,'Different Lead') AS id", [company, secondLead])).rows[0].id;
  const quote = (await owner.query("INSERT INTO public.quotes(company_id,lead_id,title) VALUES ($1,$2,'Source quote') RETURNING id", [company, lead])).rows[0].id;
  const versions = [];
  for (let number = 1; number <= 4; number++) {
    const version = (await owner.query('INSERT INTO public.quote_versions(company_id,quote_id,version_number) VALUES ($1,$2,$3) RETURNING id', [company, quote, number])).rows[0].id;
    const room = (await owner.query("INSERT INTO public.quote_rooms(company_id,version_id,name) VALUES ($1,$2,'Room') RETURNING id", [company, version])).rows[0].id;
    const group = (await owner.query("INSERT INTO public.quote_groups(company_id,version_id,room_id,name) VALUES ($1,$2,$3,'Group') RETURNING id", [company, version, room])).rows[0].id;
    const item = (await owner.query("INSERT INTO public.quote_items(company_id,version_id,group_id,name,unit,item_count) VALUES ($1,$2,$3,$4,'cái',2) RETURNING id", [company, version, group, `Quote item V${number}`])).rows[0].id;
    if (number !== 4) await owner.query('SELECT public.finalize_quote_version($1,$2)', [company, version]);
    versions.push({ version, item });
  }
  const apply = (p, v) => owner.query('SELECT public.apply_quote_version($1,$2,$3)', [company, p, v]);
  await rejected('SELECT public.apply_quote_version($1,$2,$3)', [company, project, versions[3].version], '23514', 'Cannot apply draft Quote');
  await rejected('SELECT public.apply_quote_version($1,$2,$3)', [company, wrongProject, versions[0].version], '23514', 'Cannot apply finalized Quote from a different Lead');
  const foreignLead = (await foreignClient.query("INSERT INTO public.leads(company_id,customer_name) VALUES ($1,'Foreign quote customer') RETURNING id", [other])).rows[0].id;
  const foreignQuote = (await foreignClient.query("INSERT INTO public.quotes(company_id,lead_id,title) VALUES ($1,$2,'Foreign quote') RETURNING id", [other, foreignLead])).rows[0].id;
  const foreignVersion = (await foreignClient.query('INSERT INTO public.quote_versions(company_id,quote_id,version_number) VALUES ($1,$2,1) RETURNING id', [other, foreignQuote])).rows[0].id;
  await foreignClient.query('SELECT public.finalize_quote_version($1,$2)', [other, foreignVersion]);
  await rejected('SELECT public.apply_quote_version($1,$2,$3)', [company, project, foreignVersion], '23514', 'Cannot apply another tenant Quote');
  check((await owner.query('SELECT count(*)::int AS n FROM public.project_quote_history WHERE project_id=$1', [project])).rows[0].n === 0,
    'Rejected applications leave no partial history');
  await apply(project, versions[0].version);
  await owner.query('SELECT public.set_project_financials($1,$2,5000,3000)', [company, project]);
  const catalog = (await owner.query("INSERT INTO public.catalog_items(company_id,item_code,name,unit) VALUES ($1,'SOURCE-CATALOG','Catalog original','cái') RETURNING id", [company])).rows[0].id;
  const copied = [];
  for (const kind of ['purchasing', 'production', 'construction']) {
    const module = (await owner.query(`INSERT INTO public.project_${kind}(company_id,project_id) VALUES ($1,$2) RETURNING id`, [company, project])).rows[0].id;
    const siblingModule = (await owner.query(`INSERT INTO public.project_${kind}(company_id,project_id) VALUES ($1,$2) RETURNING id`, [company, sibling])).rows[0].id;
    const insert = `INSERT INTO public.${kind}_items(company_id,project_id,${kind}_id,name,unit,required_quantity,source_quote_item_id,source_quote_version_id)
      VALUES ($1,$2,$3,'Copied snapshot','cái',2,$4,$5) RETURNING id`;
    const id = (await owner.query(insert, [company, project, module, versions[0].item, versions[0].version])).rows[0].id;
    check(Boolean(id), `${kind}: accepts source from applied version`);
    await rejected(insert, [company, sibling, siblingModule, versions[0].item, versions[0].version], '23503',
      `${kind}: same Lead does not prove application to sibling Project`, `fk_${kind}_items_applied_quote`);
    await rejected(insert, [company, project, module, versions[2].item, versions[2].version], '23503',
      `${kind}: rejects finalized version never applied to this Project`, `fk_${kind}_items_applied_quote`);
    await rejected(insert, [company, project, module, versions[3].item, versions[3].version], '23503',
      `${kind}: rejects draft source`, `fk_${kind}_items_applied_quote`);
    await rejected(insert, [company, project, module, versions[0].item, versions[1].version], '23503',
      `${kind}: rejects mismatched Quote item/version`, `fk_${kind}_items_quote`);
    await rejected(insert, [company, project, module, versions[0].item, null], '23514',
      `${kind}: nullable source version cannot bypass provenance`, `chk_${kind}_items_quote_source_pair`);
    await rejected(insert, [company, project, siblingModule, versions[0].item, versions[0].version], '23503',
      `${kind}: cannot spoof module Project`, `fk_${kind}_items_module`);
    if (kind !== 'construction') {
      await rejected(`INSERT INTO public.${kind}_items(company_id,project_id,${kind}_id,name,unit,required_quantity,source_quote_item_id,source_quote_version_id,source_catalog_item_id)
        VALUES ($1,$2,$3,'Two sources','cái',2,$4,$5,$6)`, [company, project, module, versions[0].item, versions[0].version, catalog], '23514',
        `${kind}: Quote and Catalog cannot both be direct sources`, `chk_${kind}_items_one_direct_source`);
      await owner.query(`INSERT INTO public.${kind}_items(company_id,project_id,${kind}_id,name,unit,required_quantity,source_catalog_item_id)
        VALUES ($1,$2,$3,'Catalog snapshot','cái',4,$4)`, [company, project, module, catalog]);
    }
    copied.push({ kind, module, id, insert });
  }
  await apply(project, versions[1].version);
  for (const { kind, module, id, insert } of copied) {
    const row = (await owner.query(`SELECT name,required_quantity,source_quote_version_id FROM public.${kind}_items WHERE id=$1`, [id])).rows[0];
    check(row.name === 'Copied snapshot' && Number(row.required_quantity) === 2 && row.source_quote_version_id === versions[0].version,
      `${kind}: switching current Quote preserves existing snapshot`);
    check(Boolean((await owner.query(insert, [company, project, module, versions[0].item, versions[0].version])).rows[0].id),
      `${kind}: historical V1 remains a valid new source after switching to V2`);
    await owner.query(`UPDATE public.${kind}_items SET name='Locally edited snapshot',required_quantity=5 WHERE id=$1`, [id]);
  }
  check((await owner.query('SELECT name,item_count FROM public.quote_items WHERE id=$1', [versions[0].item])).rows[0].name === 'Quote item V1',
    'Editing module snapshots does not modify finalized Quote source');
  await owner.query("UPDATE public.catalog_items SET name='Catalog edited' WHERE id=$1", [catalog]);
  for (const kind of ['purchasing', 'production']) {
    check((await owner.query(`SELECT name,required_quantity FROM public.${kind}_items WHERE source_catalog_item_id=$1`, [catalog])).rows.every(r => r.name === 'Catalog snapshot' && Number(r.required_quantity) === 4),
      `${kind}: editing Catalog does not update snapshot`);
  }
  await apply(project, versions[0].version);
  check(Number((await owner.query('SELECT contract_value FROM public.project_financials WHERE project_id=$1', [project])).rows[0].contract_value) === 3000,
    'V1 to V2 to V1 never rewrites contract value');
  check((await owner.query('SELECT count(*)::int AS n,count(*) FILTER(WHERE replaced_at IS NULL)::int AS active FROM public.project_quote_history WHERE project_id=$1', [project])).rows.every(r => r.n === 3 && r.active === 1),
    'Snapshot scenario retains three applications and one active history');
}
