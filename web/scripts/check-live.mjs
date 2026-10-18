import {readFile,writeFile} from 'node:fs/promises';
import {createPublicClient,http,fallback,keccak256} from 'viem';
const root=new URL('../src/contracts/',import.meta.url);
const deployment=JSON.parse(await readFile(new URL('deployment.json',root),'utf8'));
const network=JSON.parse(await readFile(new URL('network.json',root),'utf8'));
const fingerprints=JSON.parse(await readFile(new URL('runtime.json',root),'utf8'));
const client=createPublicClient({transport:fallback(network.network.rpcUrls.map(url=>http(url,{timeout:20000,retryCount:0})))})
const result={sources:network.network.rpcUrls,chainId:await client.getChainId(),contracts:[]};
if(result.chainId!==deployment.chainId)throw new Error('wrong chain');
for(const c of deployment.contracts){
 const code=await client.getCode({address:c.address}),f=fingerprints[c.name];
 if(!code||code==='0x')throw new Error(`${c.name}: no code`);
 let normalized=code.slice(2);
 for(const {start,length} of f.immutableReferences)normalized=normalized.slice(0,start*2)+'0'.repeat(length*2)+normalized.slice((start+length)*2);
 const matches=keccak256(`0x${normalized}`)===f.hash;
 result.contracts.push({name:c.name,address:c.address,runtimeMatches:matches});
 if(!matches)throw new Error(`${c.name}: runtime mismatch`);
}
const vault=deployment.contracts.find(c=>c.name==='KeelSpinVault');
const abi=JSON.parse(await readFile(new URL('KeelSpinVault.abi.json',root),'utf8'));
result.block=String(await client.getBlockNumber());
result.state={};
for(const name of ['currentRoundId','roundCount','activeRoundId','router','fwa','teamWallet','minBet','spinReward','liveTarget','imdBalance','betsPaused']){try{result.state[name]=String(await client.readContract({address:vault.address,abi,functionName:name}))}catch{result.state[name]='read unavailable'}}
await writeFile(new URL('../../artifacts/live-check.json',import.meta.url),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result,null,2));
