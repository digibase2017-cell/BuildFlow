import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
let failed = false;
function check(ok,message) { console.log(`${ok ? 'OK' : 'BLOCKED'}: ${message}`); if(!ok) failed=true; }
check(Number(process.versions.node.split('.')[0])>=20,`Node ${process.versions.node} (requires >=20)`);
const docker = spawnSync('docker',['info','--format','{{.ServerVersion}}'],{encoding:'utf8',timeout:15000});
check(docker.status===0,'Docker Engine must be running and reachable');
if(docker.status!==0) console.log('Open Docker Desktop, then rerun npm run check.');
const migrations = (await readdir(path.join(root,'supabase/migrations'))).filter(n=>n.endsWith('.sql')).sort();
const sources = (await readdir(path.join(root,'source_migrations'))).filter(n=>/^\d{3}_.*\.sql$/.test(n)).sort();
check(sources.length===11 && migrations.length===11,'Exactly 11 source and 11 Supabase migration files');
const hash = b => createHash('sha256').update(b).digest('hex');
for(let i=0;i<Math.min(sources.length,migrations.length);i++) {
 const a=await readFile(path.join(root,'source_migrations',sources[i]));
 const b=await readFile(path.join(root,'supabase/migrations',migrations[i]));
 check(hash(a)===hash(b),`Migration ${sources[i].slice(0,3)} matches source`);
}
process.exitCode=failed?1:0;
