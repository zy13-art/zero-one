import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
const source=await fs.readFile(new URL('../wallpaper.mjs',import.meta.url),'utf8');
const load=()=>{
  const warnings=[];
  const context=vm.createContext({console:{warn:message=>warnings.push(message)},process:{argv:['node','wallpaper.mjs','--status']},path:{dirname:()=>'.'},fileURLToPath:()=>'.',promisify:()=>()=>{},execFile:()=>{}});
  vm.runInContext(source.replace(/^import .*;\r?\n/gm,'').replace('import.meta.url','"file:///wallpaper.mjs"').replace(/main\(\)\.catch\([\s\S]*$/,'globalThis.api={setDarkAppearance,apply};'),context);
  return {api:context.api,warnings};
};
{
  const {api}=load();let calls=0;
  await api.setDarkAppearance({targetId:'already-dark',eval:async expression=>{calls++;if(expression.includes('electronBridge'))throw Error('Obsolete theme endpoint must not be called');return true;}});
  assert.equal(calls,1,'an already-dark page needs only a theme check');
  console.log('PASS: an already-dark page does not call the removed native endpoint.');
}
{
  const {api,warnings}=load();const expressions=[];
  const status={installed:true,version:6,count:1,playing:true};
  const session={targetId:'unsupported-theme',eval:async expression=>{
    expressions.push(expression);
    if(expression.includes('electronBridge'))throw Error('set-setting not implemented in the current Electron process');
    if(expression.includes('document.documentElement'))return false;
    if(expression.includes('?.status?.'))return null;
    return expression.includes('.status()')?status:true;
  }};
  const playlist={settings:{appearance:'dark'},files:[{name:'test.mp4',bytes:Buffer.from('fixture')}]};
  assert.equal(await api.apply(session,playlist,'/* renderer fixture */'),status);
  assert.ok(expressions.some(expression=>expression.includes('.endFile()')),'the video must still be loaded if the native theme endpoint is unavailable');
  await api.apply(session,playlist,'/* renderer fixture */');
  assert.equal(warnings.length,1,'a persistent native theme failure must not spam the watcher log');
  console.log('PASS: a theme compatibility error does not block the video, and is reported once.');
}
