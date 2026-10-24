import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const temp=await mkdtemp(path.join(tmpdir(),'codex-wallpaper-test-'));
let child,timer;
try {
  const loader=path.join(temp,'offline.mjs');
  await writeFile(loader,"globalThis.fetch=async()=>{throw new Error('isolated test: CDP disabled')};\n");
  await mkdir(path.join(temp,'CodexChatWallpaper'));
  await writeFile(path.join(temp,'CodexChatWallpaper','watcher-stop.request'),'stop');
  child=spawn(process.execPath,['--import',pathToFileURL(loader).href,path.join(root,'wallpaper.mjs'),'--watch'],{windowsHide:true,env:{...process.env,LOCALAPPDATA:temp},stdio:['ignore','ignore','pipe']});
  let errorText='';child.stderr.on('data',data=>{errorText+=data});
  const closed=new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',code=>resolve(code))});
  const timeout=new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Cooperative stop timed out')),5000)});
  const code=await Promise.race([closed,timeout]);
  if(code!==0)throw Error('Unexpected watcher exit '+code+': '+errorText);
  console.log('PASS: real watcher exits cleanly on its own stop signal; CDP was disabled throughout.');
} finally {
  clearTimeout(timer);
  if(child?.exitCode===null)child.kill();
  if(path.dirname(path.resolve(temp)).toLowerCase()!==path.resolve(tmpdir()).toLowerCase()||!path.basename(temp).startsWith('codex-wallpaper-test-'))throw Error('Unsafe test cleanup path');
  await rm(temp,{recursive:true,force:true});
}
