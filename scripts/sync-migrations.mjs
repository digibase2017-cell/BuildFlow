import { readdir, readFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
const source = path.join(root, 'source_migrations');
const target = path.join(root, 'supabase', 'migrations');
const files = (await readdir(source)).filter(n => /^\d{3}_.*\.sql$/.test(n)).sort();
if (files.length !== 11) throw new Error('Expected exactly 11 source migrations');
await mkdir(target, {recursive:true});
for (const [index, name] of files.entries()) {
  const number = name.slice(0,3);
  if (+number !== index+1) throw new Error(`Unexpected sequence: ${name}`);
  const destination = `20260924${String(index+1).padStart(6,'0')}_${name.slice(4)}`;
  await writeFile(path.join(target,destination), await readFile(path.join(source,name)));
}
console.log('Synced 11 migrations byte-for-byte; only Supabase filenames changed.');
