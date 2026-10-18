import {readFile,writeFile} from 'node:fs/promises';
import {keccak256,stringToHex} from 'viem';
const root=new URL('../src/contracts/',import.meta.url);
const deployment=JSON.parse(await readFile(new URL('deployment.json',root),'utf8'));
const canonical=v=>Array.isArray(v)?v.map(canonical):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v;
const results={};
for(const c of deployment.contracts){
 const abi=JSON.parse(await readFile(new URL(`${c.name}.abi.json`,root),'utf8'));
 const hash=keccak256(stringToHex(JSON.stringify(canonical(abi)))).slice(2);
 if(hash!==c.abiHash)throw new Error(`${c.name}: ABI hash mismatch: ${hash}`);
 const artifact=JSON.parse(await readFile(new URL(`../../test/scratch/contracts/${c.name}.sol/${c.name}.json`,import.meta.url),'utf8'));
 const code=artifact.deployedBytecode.object;
 const refs=Object.values(artifact.deployedBytecode.immutableReferences??{}).flat();
 let normalized=code.slice(2);
 for(const {start,length} of refs)normalized=normalized.slice(0,start*2)+'0'.repeat(length*2)+normalized.slice((start+length)*2);
 results[c.name]={hash:keccak256(`0x${normalized}`),bytes:normalized.length/2,immutableReferences:refs,abiHash:hash};
 console.log(`${c.name}: canonical ABI hash matches handoff; runtime fingerprint generated (${normalized.length/2} bytes)`);
}
await writeFile(new URL('runtime.json',root),JSON.stringify(results,null,2)+'\n');
