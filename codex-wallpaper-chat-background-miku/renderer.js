(() => {
  const KEY = '__codexChatWallpaper';
  const MAIN = 'main:is(.main-surface,[data-app-shell-main-surface],[class*="_MainContentSurface_"])';
  const STYLE_ID = 'codex-chat-wallpaper-style';
  const LAYER_ID = 'codex-chat-wallpaper-layer';

  if (window[KEY]?.version === 6) return 'already-installed';

  const state = {
    version: 6,
    paused: false,
    files: [],
    pending: null,
    index: 0,
    options: { opacity: 0.68, veil: 0.16, starHighlights: true, highlightOpacity: 0.98 },
    main: null,
    video: null,
    observer: null,
    timer: null,
    originals: new Map(),
    highlight: null,
    highlightCleanup: null,
    reference: null,
    frameCallback: null,
    fileToken: 0,
  };

  function installStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = `
      html[data-cw-active] body {
        position: relative !important;
        isolation: isolate !important;
        background: transparent !important;
        --cw-edge-rgb: 24,25,29;
        --cw-panel-rgb: 28,29,34;
      }
      ${MAIN}.codex-chat-wallpaper-main {
        position: relative !important;
        isolation: isolate !important;
        overflow: hidden !important;
        background: transparent !important;
        border-left-color: transparent !important;
      }
      html.electron-dark .codex-chat-wallpaper-main,
      html.dark .codex-chat-wallpaper-main {
        --cw-edge-rgb: 24,25,29;
        --cw-panel-rgb: 28,29,34;
      }
      #${LAYER_ID} {
        position: fixed !important;
        inset: 0 !important;
        z-index: -1 !important;
        overflow: hidden !important;
        pointer-events: none !important;
        background: rgb(var(--cw-edge-rgb)) !important;
      }
      #${LAYER_ID} video {
        display: block !important;
        width: 100% !important;
        height: 100% !important;
        object-fit: cover !important;
        object-position: center !important;
        pointer-events: none !important;
      }
      #${LAYER_ID}::after {
        content: '';
        position: absolute;
        inset: 0;
        z-index: 1;
        background:
          linear-gradient(90deg,rgba(var(--cw-edge-rgb),.74),rgba(var(--cw-edge-rgb),.54) 250px,rgba(var(--cw-edge-rgb),.22) 345px,transparent 500px),
          linear-gradient(0deg,rgba(var(--cw-edge-rgb),.96),rgba(var(--cw-edge-rgb),.66) 38px,transparent 180px),
          linear-gradient(180deg,rgba(var(--cw-edge-rgb),.55),transparent 95px),
          linear-gradient(270deg,rgba(var(--cw-edge-rgb),.25),transparent 65px),
          rgba(var(--cw-edge-rgb),var(--codex-chat-wallpaper-veil,0.16));
        pointer-events: none;
      }
      #${LAYER_ID} canvas {
        position: absolute !important;
        inset: 0 !important;
        width: 100% !important;
        height: 100% !important;
        object-fit: cover !important;
        pointer-events: none !important;
        z-index: 2 !important;
        filter: drop-shadow(0 0 1.5px rgba(255,250,200,.38));
      }
      .codex-chat-wallpaper-main [data-summary-panel-variant] {
        background: rgba(var(--cw-panel-rgb),.76) !important;
        backdrop-filter: blur(20px) saturate(115%) !important;
        border: 1px solid rgba(170,180,190,.17) !important;
        box-shadow: 0 8px 32px rgba(10,20,35,.10),0 0 22px rgba(var(--cw-panel-rgb),.15) !important;
      }
      .codex-chat-wallpaper-main [data-composer-surface-variant] {
        background: rgba(var(--cw-panel-rgb),.79) !important;
        backdrop-filter: blur(18px) saturate(110%) !important;
        border: 1px solid rgba(170,180,190,.18) !important;
        box-shadow: 0 6px 28px rgba(10,20,35,.07),0 0 30px rgba(var(--cw-panel-rgb),.18) !important;
      }
      .codex-chat-wallpaper-main [data-thread-scroll-footer] [class*="_background_"] {
        background: transparent !important;
        box-shadow: none !important;
      }
      .codex-chat-wallpaper-main :is(.app-shell-main-content-top-fade,[data-app-shell-main-content-top-fade]:not(:has(*)),[class*="_MainContentTopFade_"]) {
        background: transparent !important;
      }
      html[data-cw-active] aside.app-shell-left-panel {
        border-color: rgba(160,175,190,.12) !important;
        box-shadow: 12px 0 35px rgba(10,12,18,.08) !important;
      }
      html[data-cw-active] header:is([data-app-shell-header-edge-scroll],[class*="_Header_"]) {
        background: rgba(var(--cw-panel-rgb),.25) !important;
        backdrop-filter: blur(12px) !important;
        border-color: rgba(160,175,190,.10) !important;
      }
    `;
    document.head.append(style);
  }

  function setTransparent(element) {
    if (state.originals.has(element)) return;
    state.originals.set(element, {
      value: element.style.getPropertyValue('background-color'),
      priority: element.style.getPropertyPriority('background-color'),
    });
    element.style.setProperty('background-color', 'transparent', 'important');
  }

  function clearLargeSurfaces() {
    for (const [element,original] of state.originals) {
      if(element.isConnected) continue;
      if(original.value) element.style.setProperty('background-color',original.value,original.priority);
      else element.style.removeProperty('background-color');
      state.originals.delete(element);
    }
    const main = state.main;
    if (!main?.isConnected) return;
    const box = {width:innerWidth,height:innerHeight};
    for (const element of document.body.querySelectorAll('main,aside,nav,header,div,section')) {
      if (element.id === LAYER_ID || element.closest(`#${LAYER_ID}`)) continue;
      if (element.closest('[role="dialog"],[data-summary-panel-variant],[data-composer-surface-variant],pre')) continue;
      const r = element.getBoundingClientRect();
      const wideSurface=r.width>box.width*.65&&r.height>box.height*.5;
      const sideSurface=r.width>36&&r.width<box.width*.36&&r.height>box.height*.68;
      if (!wideSurface&&!sideSurface) continue;
      const bg = getComputedStyle(element).backgroundColor;
      const alpha = bg.match(/^rgba?\([^)]*?[,/ ]\s*([\d.]+)\s*\)$/);
      if (bg === 'transparent' || bg === 'rgba(0, 0, 0, 0)' || (alpha && Number(alpha[1]) < 0.75)) continue;
      setTransparent(element);
    }
  }

  function attach() {
    const main = [...document.querySelectorAll(MAIN)].filter((element) => {
      const r = element.getBoundingClientRect();
      return r.width > 200 && r.height > 200 && getComputedStyle(element).visibility !== 'hidden';
    }).sort((a,b) => {
      const ra=a.getBoundingClientRect(), rb=b.getBoundingClientRect();
      return rb.width*rb.height-ra.width*ra.height;
    })[0];
    if (!main || !state.files.length) return false;
    if (state.main !== main) {
      state.main?.classList.remove('codex-chat-wallpaper-main');
      state.main = main;
      main.classList.add('codex-chat-wallpaper-main');
    }
    if (!document.getElementById(LAYER_ID)) {
      document.documentElement.setAttribute('data-cw-active','true');
      const layer = document.createElement('div');
      layer.id = LAYER_ID;
      layer.style.setProperty('--codex-chat-wallpaper-veil', String(state.options.veil));
      const video = document.createElement('video');
      video.muted = true;
      video.autoplay = !state.paused;
      video.playsInline = true;
      video.preload = 'auto';
      video.style.opacity = String(state.options.opacity);
      video.addEventListener('ended', () => advance());
      video.addEventListener('error', () => advance());
      layer.append(video);
      const canvas = document.createElement('canvas');
      canvas.width = 16;
      canvas.height = 9;
      layer.append(canvas);
      state.highlight = canvas;
      document.body.prepend(layer);
      state.video = video;
      state.index = 0;
      playCurrent();
    }
    clearLargeSurfaces();
    return true;
  }

  function playCurrent() {
    if (!state.video || !state.files.length) return;
    const file = state.files[state.index % state.files.length];
    state.fileToken++;
    state.reference = null;
    stopHighlightFrames();
    state.video.loop = state.files.length === 1;
    state.video.src = file.url;
    state.video.load();
    if (!state.paused && !document.hidden) state.video.play().catch(() => {});
    if (state.options.starHighlights && file.name.toLowerCase() === 'miku.mp4') {
      prepareStarReference(file.url, state.fileToken);
      startHighlightFrames();
    }
  }

  const smooth = (a,b,x) => {
    const t=Math.max(0,Math.min(1,(x-a)/(b-a)));
    return t*t*(3-2*t);
  };

  function stopHighlightFrames() {
    if (state.frameCallback !== null && state.video?.cancelVideoFrameCallback) {
      state.video.cancelVideoFrameCallback(state.frameCallback);
    }
    state.frameCallback = null;
    state.highlightCleanup?.();
    state.highlightCleanup = null;
    if (state.highlight) state.highlight.getContext('2d').clearRect(0,0,state.highlight.width,state.highlight.height);
  }

  async function prepareStarReference(url, token) {
    const referenceVideo = document.createElement('video');
    referenceVideo.muted = true;
    referenceVideo.src = url;
    try {
      await new Promise((resolve,reject) => {
        referenceVideo.onloadeddata=resolve;
        referenceVideo.onerror=reject;
        referenceVideo.load();
      });
      await new Promise((resolve) => {
        referenceVideo.onseeked=resolve;
        referenceVideo.currentTime=Math.min(3.1,referenceVideo.duration*.8);
      });
      const canvas=document.createElement('canvas');
      canvas.width=640;canvas.height=360;
      const ctx=canvas.getContext('2d',{willReadFrequently:true});
      ctx.drawImage(referenceVideo,0,0,640,360);
      if(token===state.fileToken) state.reference=ctx.getImageData(0,0,640,360).data;
    } catch {} finally {
      referenceVideo.removeAttribute('src');referenceVideo.load();
    }
  }

  function startHighlightFrames() {
    const source=document.createElement('canvas');source.width=640;source.height=360;
    const sourceCtx=source.getContext('2d',{willReadFrequently:true});
    const mask=document.createElement('canvas');mask.width=640;mask.height=360;
    const maskCtx=mask.getContext('2d');
    const targetCtx=state.highlight.getContext('2d');
    const output=maskCtx.createImageData(640,360);
    let active=true;
    // Coordinates use half of the original 1280x720 Miku video frame.
    const regions=[
      {x0:189,x1:258,y0:82,y1:164,eye:true,cx:224,cy:123,rx:37,ry:43},
      {x0:381,x1:455,y0:83,y1:166,eye:true,cx:418,cy:124,rx:38,ry:43},
      {x0:435,x1:565,y0:17,y1:195,eye:false,cx:503,cy:65},
      {x0:7,x1:165,y0:197,y1:345,eye:false,cx:86,cy:273},
    ];
    const paint=() => {
      if(!active||!state.video||!state.highlight?.isConnected) return;
      if(state.video.readyState>=2) {
        // Match the covered viewport at its device pixel ratio, while keeping
        // the Miku frame's 16:9 ratio and limiting the overlay to 4K or source size.
        const dpr=Math.max(1,Number(window.devicePixelRatio)||1);
        const sourceUnits=Math.floor(Math.min(state.video.videoWidth/16,state.video.videoHeight/9));
        const viewportUnits=Math.ceil(Math.max(innerWidth/16,innerHeight/9)*dpr);
        const units=Math.max(1,Math.min(240,sourceUnits||240,viewportUnits));
        const width=units*16,height=units*9;
        if(state.highlight.width!==width||state.highlight.height!==height) {
          state.highlight.width=width;state.highlight.height=height;
        }
        sourceCtx.drawImage(state.video,0,0,640,360);
        const pixels=sourceCtx.getImageData(0,0,640,360).data;
        const dest=output.data;dest.fill(0);
        for(const region of regions) for(let y=region.y0;y<region.y1;y++) for(let x=region.x0;x<region.x1;x++) {
          const offset=(y*640+x)*4;
          const r=pixels[offset],g=pixels[offset+1],b=pixels[offset+2];
          const yellow=smooth(165,220,Math.min(r,g))*smooth(24,65,Math.min(r,g)-b)*(1-smooth(45,75,Math.abs(r-g)));
          let alpha=0;
          if(region.eye) {
            const distance=Math.hypot((x-region.cx)/region.rx,(y-region.cy)/region.ry);
            alpha=yellow*(1-smooth(.80,1,distance));
          } else if(state.reference) {
            const min=Math.min(r,g,b), max=Math.max(r,g,b);
            const white=smooth(205,240,min)*(1-smooth(18,50,max-min));
            const base=state.reference;
            const baseMin=Math.min(base[offset],base[offset+1],base[offset+2]);
            const movingWhite=white*smooth(12,50,min-baseMin);
            const baseYellow=Math.min(base[offset],base[offset+1])-base[offset+2];
            const core=1-smooth(14,28,Math.hypot(x-region.cx,y-region.cy));
            const movingYellow=yellow*core*smooth(16,65,Math.min(r,g)-b-baseYellow);
            const edge=Math.min(x-region.x0,region.x1-x,y-region.y0,region.y1-y);
            alpha=Math.max(movingWhite,movingYellow)*smooth(0,5,edge);
          }
          if(alpha>.01) {
            dest[offset]=255;dest[offset+1]=255;dest[offset+2]=255;
            dest[offset+3]=Math.round(255*alpha*state.options.highlightOpacity);
          }
        }
        maskCtx.putImageData(output,0,0);
        targetCtx.clearRect(0,0,width,height);
        targetCtx.save();
        targetCtx.globalCompositeOperation='source-over';
        targetCtx.drawImage(state.video,0,0,width,height);
        targetCtx.globalCompositeOperation='destination-in';
        targetCtx.imageSmoothingEnabled=true;
        targetCtx.imageSmoothingQuality='high';
        targetCtx.drawImage(mask,0,0,width,height);
        targetCtx.restore();
      }
    };
    const onResize=() => paint();
    window.addEventListener('resize',onResize);
    state.highlightCleanup=() => {
      active=false;
      window.removeEventListener('resize',onResize);
      source.width=source.height=0;
      mask.width=mask.height=0;
    };
    const render=() => {
      if(!active||!state.video||!state.highlight?.isConnected) return;
      paint();
      state.frameCallback=state.video.requestVideoFrameCallback(render);
    };
    paint();
    if(state.video.requestVideoFrameCallback) state.frameCallback=state.video.requestVideoFrameCallback(render);
  }

  function advance() {
    if (state.files.length < 2) return;
    state.index = (state.index + 1) % state.files.length;
    playCurrent();
  }

  function decodeChunks(chunks) {
    const parts = chunks.map((chunk) => {
      const binary = atob(chunk);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      return bytes;
    });
    return new Blob(parts, { type: 'video/mp4' });
  }

  state.beginFile = (name) => {
    if (state.pending) throw new Error('A file transfer is already in progress');
    state.pending = { name, chunks: [] };
    return true;
  };
  state.addChunk = (chunk) => {
    if (!state.pending) throw new Error('No active file transfer');
    state.pending.chunks.push(chunk);
    return state.pending.chunks.length;
  };
  state.endFile = () => {
    if (!state.pending) throw new Error('No active file transfer');
    const { name, chunks } = state.pending;
    state.pending = null;
    const url = URL.createObjectURL(decodeChunks(chunks));
    state.files.push({ name, url });
    if (state.video && state.files.length > 1) state.video.loop = false;
    attach();
    return state.files.length;
  };
  state.configure = (options) => {
    const opacity = Number(options.opacity);
    state.options.opacity = Math.min(1, Math.max(0, Number.isFinite(opacity) ? opacity : 0.68));
    state.options.veil = Math.min(1, Math.max(0, Number(options.veil) || 0));
    state.options.starHighlights = options.starHighlights !== false;
    const highlightOpacity = Number(options.highlightOpacity);
    state.options.highlightOpacity = Math.min(1, Math.max(0, Number.isFinite(highlightOpacity) ? highlightOpacity : 0.98));
    if (state.video) state.video.style.opacity = String(state.options.opacity);
    document.getElementById(LAYER_ID)?.style.setProperty('--codex-chat-wallpaper-veil', String(state.options.veil));
    return true;
  };
  state.pause = () => { state.paused = true; state.video?.pause(); return true; };
  state.resume = () => { state.paused = false; if (!document.hidden) state.video?.play().catch(() => {}); return true; };
  const onVisibility = () => {
    if (document.hidden) state.video?.pause();
    else if (!state.paused) state.video?.play().catch(() => {});
  };
  document.addEventListener('visibilitychange', onVisibility);
  state.status = () => ({ installed: true, version: state.version, coverage: 'window',
    dark: document.documentElement.classList.contains('electron-dark')||document.documentElement.dataset.theme==='dark',
    attached: !!state.main?.isConnected && state.main.getBoundingClientRect().width > 200,
    count: state.files.length, current: state.files[state.index]?.name || null,
    playing: !!state.video && !state.video.paused,
    currentTime: state.video?.currentTime ?? null,
    duration: Number.isFinite(state.video?.duration) ? state.video.duration : null,
    videoWidth: state.video?.videoWidth ?? 0,
    videoHeight: state.video?.videoHeight ?? 0,
    readyState: state.video?.readyState ?? 0,
    error: state.video?.error?.message ?? null });
  state.remove = () => {
    state.observer?.disconnect();
    document.removeEventListener('visibilitychange', onVisibility);
    clearInterval(state.timer);
    state.video?.pause();
    stopHighlightFrames();
    state.fileToken++;
    if(state.highlight) state.highlight.width=state.highlight.height=0;
    state.highlight=null;
    state.reference=null;
    document.getElementById(LAYER_ID)?.remove();
    document.getElementById(STYLE_ID)?.remove();
    document.documentElement.removeAttribute('data-cw-active');
    state.main?.classList.remove('codex-chat-wallpaper-main');
    for (const [element, original] of state.originals) {
      if (original.value) element.style.setProperty('background-color', original.value, original.priority);
      else element.style.removeProperty('background-color');
    }
    for (const file of state.files) URL.revokeObjectURL(file.url);
    delete window[KEY];
    return true;
  };

  installStyle();
  window[KEY] = state;
  state.observer = new MutationObserver(() => {
    if (!state.main?.isConnected) attach();
  });
  state.observer.observe(document.documentElement, { childList: true, subtree: true });
  state.timer = setInterval(attach, 2000);
  return 'installed';
})();
