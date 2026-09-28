import assert from 'node:assert/strict';
import test from 'node:test';
import {foldOption,managedOptionHtml} from '../app/managed-options.mjs';

test('Vietnamese search folds case, accents and Đ',()=>{
  assert.equal(foldOption('HÀ NỘI'),'ha noi');
  assert.equal(foldOption('Nam Định'),'nam dinh');
});

test('search is opt-in and add action uses configured label',()=>{
  const ordinary=managedOptionHtml({key:'source',label:'Nguồn 1',addLabel:'nguồn'});
  assert.doesNotMatch(ordinary,/managed-search/);
  assert.match(ordinary,/＋ Thêm nguồn/);
  const province=managedOptionHtml({key:'province',label:'Tỉnh\/Thành phố',searchable:true});
  assert.match(province,/managed-search/);
});
