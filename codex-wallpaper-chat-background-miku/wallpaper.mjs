import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const root = path.dirname(fileURLToPath(import.meta.url));
const port = 9335;
const base = `http://127.0.0.1:${port}`;
const key = '__codexChatWallpaper';
const execFileAsync = promisify(execFile);
const verifiedTargets = new Set();
const appearanceWarningTargets = new Set();
const mode = process.argv[2] || '--watch';
const validModes = new Set(['--watch', '--once', '--status', '--pause', '--resume', '--remove', '--validate']);
if (!validModes.has(mode)) throw new Error(`Unknown mode: ${mode}`);

async function getTargets() {
  const response = await fetch(`${base}/json/list`, { signal: AbortSignal.timeout(4000) });
  if (!response.ok) throw new Error(`CDP returned HTTP ${response.status}`);
  const targets = await response.json();
  const mainTargets = targets.filter((target) => target.type === 'page' &&
    typeof target.url === 'string' && /^app:\/\/-\/index\.html(?:[?#]|$)/.test(target.url) &&
    !new URL(target.url).searchParams.get('initialRoute')?.includes('avatar-overlay') &&
    typeof target.id === 'string' && /^[a-zA-Z0-9._-]+$/.test(target.id) &&
    typeof target.webSocketDebuggerUrl === 'string');
  if(mainTargets.some(target=>!verifiedTargets.has(target.id))) {
    const {stdout}=await execFileAsync('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(root,'verify-cdp.ps1')],{windowsHide:true,timeout:12000});
    if(stdout.trim()!=='verified')throw new Error('Could not verify Codex CDP ownership');
    mainTargets.forEach(target=>verifiedTargets.add(target.id));
  }
  return mainTargets;
}

class Session {
  constructor(target) {
    this.targetId=target.id;
    const url = new URL(target.webSocketDebuggerUrl);
    if (url.protocol !== 'ws:' || url.hostname !== '127.0.0.1' ||
        Number(url.port) !== port || url.pathname !== `/devtools/page/${target.id}` ||
        url.username || url.password || url.search || url.hash) {
      throw new Error('Rejected an unexpected CDP WebSocket address');
    }
    this.socket = new WebSocket(url.href);
    this.sequence = 0;
    this.pending = new Map();
  }

  async open() {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('CDP connection timed out')), 5000);
      this.socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
      this.socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('CDP connection failed')); }, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      let message;
      try { message = JSON.parse(String(event.data)); } catch { return; }
      if (!message.id) return;
      const request = this.pending.get(message.id);
      if (!request) return;
      clearTimeout(request.timer);
      this.pending.delete(message.id);
      if (message.error) request.reject(new Error(message.error.message));
      else request.resolve(message.result);
    });
    this.socket.addEventListener('close', () => {
      for (const request of this.pending.values()) {
        clearTimeout(request.timer);
        request.reject(new Error('CDP connection closed'));
      }
      this.pending.clear();
    });
    await this.send('Runtime.enable');
    return this;
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method} timed out`));
      }, 12000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async eval(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression, returnByValue: true, awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.text || 'Renderer evaluation failed');
    }
    return result.result?.value;
  }

  close() { this.socket.close(); }
}

async function readPlaylist() {
  const settings = JSON.parse(await fs.readFile(path.join(root, 'settings.json'), 'utf8'));
  const opacity = Number(settings.opacity);
  const veil = Number(settings.veil);
  if (!(opacity >= 0 && opacity <= 1 && veil >= 0 && veil <= 1)) {
    throw new Error('settings.json requires opacity and veil between 0 and 1');
  }
  const dir = path.join(root, 'wallpapers');
  const names = (await fs.readdir(dir)).filter((name) => name.toLowerCase().endsWith('.mp4')).sort();
  if (!names.length) throw new Error(`No MP4 files found in ${dir}`);
  const files = [];
  let total = 0;
  for (const name of names) {
    const file = path.join(dir, name);
    const stat = await fs.stat(file);
    if (!stat.isFile()) continue;
    total += stat.size;
    if (stat.size > 64 * 1024 * 1024 || total > 128 * 1024 * 1024) {
      throw new Error('Playlist limit: 64 MB per MP4 and 128 MB total');
    }
    files.push({ name, bytes: await fs.readFile(file) });
  }
  return { settings: { opacity, veil, appearance: settings.appearance ?? 'dark', starHighlights: settings.starHighlights !== false,
    highlightOpacity: settings.highlightOpacity ?? 0.98 }, files };
}

async function setDarkAppearance(session) {
  if(await session.eval("document.documentElement.classList.contains('electron-dark')||document.documentElement.dataset.theme==='dark'")) return;
  const success = await session.eval(`(async () => {
    const bridge=window.electronBridge;
    if(!bridge?.sendMessageFromView) throw new Error('Codex setting bridge is not ready');
    return new Promise((resolve,reject)=>{
      const requestId=crypto.randomUUID();
      const cleanup=()=>{clearTimeout(timer);window.removeEventListener('message',handler);};
      const handler=(event)=>{
        const reply=event.data;
        if(reply?.type!=='fetch-response'||reply.requestId!==requestId)return;
        cleanup();
        if(reply.responseType==='success'&&reply.status===200)resolve(true);
        else reject(new Error(reply.error || 'Codex could not save dark appearance'));
      };
      const timer=setTimeout(()=>{cleanup();reject(new Error('Dark appearance setting timed out'));},8000);
      window.addEventListener('message',handler);
      Promise.resolve(bridge.sendMessageFromView({type:'fetch',requestId,method:'POST',
        url:'vscode://codex/set-setting',body:JSON.stringify({key:'appearanceTheme',value:'dark'})}))
        .catch(error=>{cleanup();reject(error);});
    });
  })()`);
  if(!success) throw new Error('Dark appearance was not applied');
}

async function apply(session, playlist, renderer) {
  if(playlist.settings.appearance==='dark') {
    try {
      await setDarkAppearance(session);
      appearanceWarningTargets.delete(session.targetId);
    } catch(error) {
      if(!appearanceWarningTargets.has(session.targetId)) {
        console.warn(`${new Date().toISOString()} Native dark appearance could not be saved; wallpaper will still load: ${error.message}`);
        appearanceWarningTargets.add(session.targetId);
      }
    }
  }
  const current = await session.eval(`window.${key}?.status?.() ?? null`);
  if (current?.installed && current.version === 6 && current.count === playlist.files.length) {
    return current;
  }
  if (current?.installed) await session.eval(`window.${key}.remove()`);
  await session.eval(renderer);
  await session.eval(`window.${key}.configure(${JSON.stringify(playlist.settings)})`);
  for (const file of playlist.files) {
    await session.eval(`window.${key}.beginFile(${JSON.stringify(file.name)})`);
    for (let offset = 0; offset < file.bytes.length; offset += 128 * 1024) {
      const chunk = file.bytes.subarray(offset, offset + 128 * 1024).toString('base64');
      await session.eval(`window.${key}.addChunk(${JSON.stringify(chunk)})`);
    }
    await session.eval(`window.${key}.endFile()`);
  }
  return session.eval(`window.${key}.status()`);
}

async function visitTargets(action, waitMs = 0) {
  const deadline = Date.now() + waitMs;
  do {
    try {
      const targets = await getTargets();
      if (!targets.length) throw new Error('No Codex chat renderer is available yet');
      const results = [];
      for (const target of targets) {
        const session = new Session(target);
        try {
          await session.open();
          results.push({ target: target.id, result: await action(session) });
        } finally { session.close(); }
      }
      return results;
    } catch (error) {
      if (Date.now() >= deadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  } while (true);
}

async function main() {
  if (mode === '--validate') {
    const playlist = await readPlaylist();
    console.log(JSON.stringify({
      files: playlist.files.map(({ name, bytes }) => ({ name, bytes: bytes.length })),
      settings: playlist.settings,
    }, null, 2));
    return;
  }
  if (mode === '--watch' || mode === '--once') {
    const playlist = await readPlaylist();
    const renderer = await fs.readFile(path.join(root, 'renderer.js'), 'utf8');
    let busy = false;
    let lastSummary = null;
    let lastError = null;
    const tick = async (throwOnError = false) => {
      if (busy) return;
      busy = true;
      try {
        const result = await visitTargets((session) => apply(session, playlist, renderer), mode === '--once' ? 60000 : 0);
        const summary=JSON.stringify(result.map(({target,result:r})=>({target,version:r?.version,count:r?.count,attached:r?.attached,current:r?.current,playing:r?.playing,error:r?.error})));
        if(summary!==lastSummary||lastError)console.log(JSON.stringify({ time: new Date().toISOString(), targets: result }));
        lastSummary=summary;lastError=null;
      } catch (error) {
        if(error.message!==lastError)console.error(`${new Date().toISOString()} ${error.message}`);
        lastError=error.message;
        if (throwOnError) throw error;
      }
      finally { busy = false; }
    };
    if (mode === '--watch') {
      const stopRequest=path.join(process.env.LOCALAPPDATA || root,'CodexChatWallpaper','watcher-stop.request');
      setInterval(()=>{fs.access(stopRequest).then(()=>process.exit(0)).catch(()=>{});},1000);
    }
    await tick(mode === '--once');
    if (mode === '--watch') setInterval(tick, 5000);
    return;
  }
  const expression = mode === '--status' ? `window.${key}?.status?.() ?? null` :
    mode === '--remove' ? `window.${key}?.remove?.() ?? false` :
    mode === '--pause' ? `window.${key}?.pause?.() ?? false` :
    `window.${key}?.resume?.() ?? false`;
  console.log(JSON.stringify(await visitTargets((session) => session.eval(expression)), null, 2));
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
