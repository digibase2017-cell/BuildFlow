// Independent items contend on their shared aggregate module, not the same item.
export async function testModuleConcurrency({ db, owner, company, admin, race, check }) {
  const lead = (await owner.query("INSERT INTO public.leads(company_id,customer_name,status) VALUES ($1,'Multi-item race','Thành công') RETURNING id", [company])).rows[0].id;
  const project = (await owner.query("SELECT public.create_project_from_lead($1,$2,'Multi-item race',NULL,false,true,true,false) AS id", [company, lead])).rows[0].id;
  for (const [kind, batch, date, initial, working, completed] of [
    ['purchasing', 'purchasing_receipts', 'receipt_date', 'Chưa đặt', 'Đang mua', 'Đã nhận'],
    ['production', 'production_batches', 'completed_date', 'Chưa sản xuất', 'Đang sản xuất', 'Hoàn thành'],
  ]) {
    const module = (await owner.query(`INSERT INTO public.project_${kind}(company_id,project_id) VALUES ($1,$2) RETURNING id`, [company, project])).rows[0].id;
    const items = [];
    for (const name of ['A', 'B']) items.push((await owner.query(`INSERT INTO public.${kind}_items(company_id,project_id,${kind}_id,name,unit,required_quantity)
      VALUES ($1,$2,$3,$4,'cái',10) RETURNING id`, [company, project, module, name])).rows[0].id);
    const insert = (client, item) => client.query(`INSERT INTO public.${batch}(company_id,${kind}_item_id,${date},quantity)
      VALUES ($1,$2,current_date,10) RETURNING id`, [company, item]);
    const moduleStatus = async () => (await owner.query(`SELECT status FROM public.project_${kind} WHERE id=$1`, [module])).rows[0].status;
    let result = await race(db, admin.subject, c => insert(c, items[0]), admin.subject, c => insert(c, items[1]));
    if (result.second.error) throw result.second.error;
    check(await moduleStatus() === 'Đã xong', `${kind}: concurrent completion of different items completes shared module`);
    check((await owner.query(`SELECT status FROM public.${kind}_items WHERE ${kind}_id=$1`, [module])).rows.every(r => r.status === completed),
      `${kind}: both item completion states survive module contention`);
    const receipts = [result.first.rows[0].id, result.second.result.rows[0].id];
    result = await race(db, admin.subject,
      c => c.query(`UPDATE public.${batch} SET quantity=3 WHERE id=$1`, [receipts[0]]), admin.subject,
      c => c.query(`UPDATE public.${batch} SET quantity=4 WHERE id=$1`, [receipts[1]]));
    if (result.second.error) throw result.second.error;
    check(await moduleStatus() === initial, `${kind}: concurrent reductions restore initial aggregate phase`);
    check((await owner.query(`SELECT status FROM public.${kind}_items WHERE ${kind}_id=$1`, [module])).rows.every(r => r.status === initial),
      `${kind}: concurrent corrections preserve both saved earlier phases`);
    await owner.query(`UPDATE public.${batch} SET quantity=10 WHERE id=$1`, [receipts[0]]);
    check(await moduleStatus() === working, `${kind}: mixed completed and incomplete items yield working module`);
    result = await race(db, admin.subject,
      c => c.query(`UPDATE public.${batch} SET quantity=2 WHERE id=$1`, [receipts[0]]), admin.subject,
      c => c.query(`UPDATE public.${batch} SET quantity=10 WHERE id=$1`, [receipts[1]]));
    if (result.second.error) throw result.second.error;
    check(await moduleStatus() === working, `${kind}: opposing item transitions retain mixed aggregate status`);
    result = await race(db, admin.subject,
      c => c.query(`DELETE FROM public.${batch} WHERE id=$1`, [receipts[0]]), admin.subject,
      c => c.query(`DELETE FROM public.${batch} WHERE id=$1`, [receipts[1]]));
    if (result.second.error) throw result.second.error;
    check(await moduleStatus() === initial, `${kind}: concurrent deletions reconcile shared aggregate`);
    check((await owner.query(`SELECT count(*)::int AS n FROM public.${batch} WHERE ${kind}_item_id=ANY($1::uuid[])`, [items])).rows[0].n === 0,
      `${kind}: both concurrent deletions commit`);
  }
}
