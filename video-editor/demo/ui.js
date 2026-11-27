(() => {
  'use strict';

  const editorLib = window.createEditor;
  if (typeof editorLib !== 'function') {
    console.error('editor.js 未加载，无法启动编辑器');
    return;
  }

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const make = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const pad2 = value => String(value).padStart(2, '0');
  const fmtTime = seconds => {
    const total = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
    return `${pad2(Math.floor(total / 60))}:${pad2(total % 60)}`;
  };

  const el = {
    app: $('#app'),
    stage: $('#stage'),
    frame: $('#frame'),
    preview: $('#preview'),
    close: $('#btn-close'),
    quality: $('#btn-quality'),
    qualityLabel: $('#quality-label'),
    qualityMenu: $('#quality-menu'),
    exportBtn: $('#btn-export'),
    play: $('#btn-play'),
    playIcon: $('#play-icon use'),
    undo: $('#btn-undo'),
    redo: $('#btn-redo'),
    fullscreen: $('#btn-fullscreen'),
    fullscreenIcon: $('#fullscreen-icon use'),
    timeCurrent: $('#time-current'),
    projectPosition: $('#project-position'),
    timeTotal: $('#time-total'),
    timeline: $('#timeline'),
    timelineContent: $('#timeline-content'),
    ruler: $('#ruler'),
    clips: $('#clips'),
    cover: $('#cover'),
    coverCanvas: $('#cover-canvas'),
    mute: $('#btn-mute'),
    muteIcon: $('#mute-icon use'),
    muteLabel: $('#mute-label'),
    audioRow: $('#audio-row'),
    timedTracks: $('#timed-tracks'),
    audioAdd: $('#btn-add-audio'),
    addMedia: $('#btn-add-media'),
    textStack: $('#text-stack'),
    stickerLayer: $('#sticker-layer'),
    pipSlot: $('#pip-slot'),
    stageMessage: $('#stage-message'),
    stageLoader: $('#stage-loader'),
    previewExit: $('#btn-preview-exit'),
    toolbar: $('#toolbar'),
    sheetRoot: $('#sheet-root'),
    sheet: $('#sheet'),
    sheetTitle: $('#sheet-title'),
    sheetBody: $('#sheet-body'),
    sheetDone: $('#sheet-done'),
    sheetScrim: $('.sheet-scrim'),
    modalRoot: $('#modal-root'),
    modalCard: $('#modal-card'),
    modalScrim: $('.modal-scrim'),
    closedScreen: $('#closed-screen'),
    reenter: $('#btn-reenter'),
    toast: $('#toast'),
    statusTime: $('#status-time'),
    fileVideo: $('#file-video'),
    fileAudio: $('#file-audio'),
    filePip: $('#file-pip'),
    fileSticker: $('#file-sticker'),
  };

  const editor = editorLib(el.preview);

  const state = {
    data: null,
    pps: 58.5,
    playheadX: 218,
    clipSignature: '',
    layoutDirty: true,
    bootAt: performance.now(),
    videoReady: el.preview.readyState >= 1,
    quality: '1080p',
    muted: false,
    coverTime: null,
    coverSrc: null,
    coverKey: '',
    audio: null,
    lastAudioSync: 0,
    pip: null,
    texts: [],
    selectedTimed: null,
    stickers: [],
    effect: 'original',
    effectItem: null,
    sheet: null,
    textDraft: null,
    modalBusy: false,
    exportTimer: null,
    toastTimer: null,
    importing: false,
    stickerHintShown: false,
    pan: null,
    clockTimer: null,
    resizeTimer: null,
    wheelAt: 0,
  };

  const TILE_WIDTH = 60;
  const RES_LABEL = {
    '480P': '480p',
    '720P': '720p',
    '1080P': '1080p',
    '2K': '2K',
    '4K': '4K',
  };
  const RES_BITRATE = { '480p': 1.2, '720p': 2.2, '1080p': 3.6, '2K': 7, '4K': 15 };
  const STICKERS = ['😀', '😎', '🔥', '✨', '💯', '🎉', '❤️', '👍', '🌟', '🎬'];
  const STICKER_SPOTS = [
    [16, 16], [62, 20], [18, 58], [64, 58],
    [40, 38], [10, 36], [70, 74], [44, 12],
  ];
  const EFFECTS = [
    {
      id: 'original',
      name: '原片',
      filter: '',
      swatch: 'linear-gradient(135deg, #6e8fa6, #d8b98e 52%, #3e4d5a)',
    },
    {
      id: 'bw',
      name: '黑白',
      filter: 'grayscale(1) contrast(1.06)',
      swatch: 'linear-gradient(135deg, #6f6f6f, #dedede 52%, #3f3f3f)',
    },
    {
      id: 'warm',
      name: '暖阳',
      filter: 'sepia(.32) saturate(1.22) brightness(1.04)',
      swatch: 'linear-gradient(135deg, #b9752f, #ffd9a0 52%, #7a4318)',
    },
    {
      id: 'cool',
      name: '冷调',
      filter: 'hue-rotate(-12deg) saturate(1.12) brightness(.98)',
      swatch: 'linear-gradient(135deg, #2f5f8a, #9fd0ea 52%, #1d3550)',
    },
    {
      id: 'film',
      name: '复古',
      filter: 'sepia(.5) contrast(1.08) saturate(.85)',
      swatch: 'linear-gradient(135deg, #6f5a3c, #d9c19a 52%, #4a3826)',
    },
  ];

  /* ------------------------------------------------------------------ */
  /* 基础排版                                                           */
  /* ------------------------------------------------------------------ */

  function measure() {
    const width = el.timeline.clientWidth;
    if (!width) return;
    state.playheadX = width / 2;
    state.pps = Math.max(30, width * 0.1342);
  }

  function clockLabel() {
    const now = new Date();
    return `${now.getHours()}:${pad2(now.getMinutes())}`;
  }

  function estimateSize(seconds) {
    const rate = RES_BITRATE[state.quality] || 3.6;
    return Math.max(1, Math.round((seconds * rate) / 1));
  }

  function startOfClip(index) {
    if (!state.data) return 0;
    let total = 0;
    for (let i = 0; i < index && i < state.data.clips.length; i++) {
      total += state.data.clips[i].end - state.data.clips[i].start;
    }
    return total;
  }

  function locate(seconds) {
    const clips = state.data ? state.data.clips : [];
    let start = 0;
    for (let i = 0; i < clips.length; i++) {
      const clip = clips[i];
      const length = clip.end - clip.start;
      if (seconds < start + length || i === clips.length - 1) {
        return {
          clip,
          index: i,
          offset: clamp(seconds - start, 0, length),
        };
      }
      start += length;
    }
    return null;
  }

  function clipListSignature(clips) {
    return clips
      .map(clip => `${clip.id}:${clip.src}:${clip.start.toFixed(3)}:${clip.end.toFixed(3)}`)
      .join('|');
  }

  /* ------------------------------------------------------------------ */
  /* 抽帧：用隐藏 video + canvas，不上传、不读像素，可直接双击打开       */
  /* ------------------------------------------------------------------ */

  function drawCover(source, ctx, width, height) {
    const sourceWidth = source.videoWidth || source.width || 0;
    const sourceHeight = source.videoHeight || source.height || 0;
    if (!sourceWidth || !sourceHeight) return false;
    const scale = Math.max(width / sourceWidth, height / sourceHeight);
    const drawWidth = sourceWidth * scale;
    const drawHeight = sourceHeight * scale;
    ctx.clearRect(0, 0, width, height);
    ctx.drawImage(
      source,
      (width - drawWidth) / 2,
      (height - drawHeight) / 2,
      drawWidth,
      drawHeight
    );
    return true;
  }

  class FrameExtractor {
    constructor(src) {
      this.video = document.createElement('video');
      this.video.muted = true;
      this.video.playsInline = true;
      this.video.preload = 'auto';
      this.video.setAttribute('playsinline', '');
      this.video.setAttribute('aria-hidden', 'true');
      this.video.style.cssText =
        'position:fixed;left:-24px;bottom:0;width:1px;height:1px;opacity:.01;pointer-events:none;z-index:-1;';
      this.video.src = src;
      document.body.appendChild(this.video);
      this.ready = new Promise(resolve => {
        let settled = false;
        const finish = () => {
          if (settled) return;
          settled = true;
          resolve();
        };
        if (this.video.readyState >= 1) finish();
        else {
          this.video.addEventListener('loadedmetadata', finish, { once: true });
          this.video.addEventListener('error', finish, { once: true });
          setTimeout(finish, 8000);
        }
      });
      this.chain = Promise.resolve();
    }

    request(canvas, sourceTime) {
      const width = canvas.width;
      const height = canvas.height;
      this.chain = this.chain
        .then(async () => {
          await this.ready;
          const video = this.video;
          if (!video.videoWidth) return;
          const duration = Number.isFinite(video.duration) ? video.duration : sourceTime + 1;
          const target = clamp(sourceTime, 0, Math.max(0, duration - 0.05));
          if (Math.abs(video.currentTime - target) > 0.01) {
            await new Promise(resolve => {
              let settled = false;
              const finish = () => {
                if (settled) return;
                settled = true;
                video.removeEventListener('seeked', finish);
                video.removeEventListener('error', finish);
                clearTimeout(timer);
                resolve();
              };
              const timer = setTimeout(finish, 3000);
              video.addEventListener('seeked', finish);
              video.addEventListener('error', finish);
              try {
                video.currentTime = target;
              } catch {
                finish();
              }
            });
          }
          if (!video.videoWidth) return;
          drawCover(video, canvas.getContext('2d'), width, height);
        })
        .catch(() => {});
      return this.chain;
    }
  }

  const extractors = new Map();
  function extractorFor(src) {
    if (!src) return null;
    let extractor = extractors.get(src);
    if (!extractor) {
      extractor = new FrameExtractor(src);
      extractors.set(src, extractor);
    }
    return extractor;
  }

  // 抽帧缓存：同一时间点只 seek 一次，重建片段时直接复用，避免缩略图空白
  const frameCache = new Map();
  const framePending = new Map();
  const FRAME_CACHE_LIMIT = 96;
  const FRAME_WIDTH = 240;
  const FRAME_HEIGHT = 135;

  function frameKey(src, time) {
    return `${src}|${Math.round(time * 4) / 4}`;
  }

  function blitFrame(source, canvas) {
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    drawCover(source, ctx, canvas.width, canvas.height);
  }

  function requestFrame(src, time, canvas) {
    if (!src || !canvas) return;
    const key = frameKey(src, time);
    const cached = frameCache.get(key);
    if (cached) {
      frameCache.delete(key);
      frameCache.set(key, cached);
      blitFrame(cached, canvas);
      return;
    }
    let pending = framePending.get(key);
    if (!pending) {
      const frame = document.createElement('canvas');
      frame.width = FRAME_WIDTH;
      frame.height = FRAME_HEIGHT;
      const extractor = extractorFor(src);
      pending = (extractor ? extractor.request(frame, time) : Promise.resolve()).then(() => {
        frameCache.set(key, frame);
        if (frameCache.size > FRAME_CACHE_LIMIT) {
          const oldest = frameCache.keys().next().value;
          frameCache.delete(oldest);
        }
      });
      framePending.set(key, pending);
    }
    pending.then(() => {
      const frame = frameCache.get(key);
      if (frame) {
        blitFrame(frame, canvas);
      } else if (canvas.isConnected) {
        requestFrame(src, time, canvas);
      }
    });
  }

  function drawCurrentFrame(canvas) {
    if (el.preview.readyState >= 2) {
      drawCover(el.preview, canvas.getContext('2d'), canvas.width, canvas.height);
      return;
    }
    const data = state.data;
    if (!data || !data.clips.length) return;
    const loc = locate(data.currentTime);
    if (!loc) return;
    const extractor = extractorFor(loc.clip.src);
    if (extractor) extractor.request(canvas, loc.clip.start + loc.offset);
  }

  /* ------------------------------------------------------------------ */
  /* 渲染                                                               */
  /* ------------------------------------------------------------------ */

  function onState(next) {
    state.data = next;
    const signature = clipListSignature(next.clips);
    const needsClips = signature !== state.clipSignature || state.layoutDirty;
    if (needsClips) {
      state.clipSignature = signature;
      state.layoutDirty = false;
      rebuildRuler(next);
      rebuildClips(next);
    }
    renderTime(next);
    renderTransport(next);
    renderTimedTracks(next);
    renderCover(next, needsClips);
    renderEmptyState(next);
    renderMute();
    syncBackgroundMedia(next);
  }

  function renderTime(next) {
    const position = el.projectPosition;
    position.max = next.duration;
    position.value = next.currentTime;
    position.disabled = !next.duration;
    position.style.setProperty('--project-progress', (next.duration ? next.currentTime / next.duration * 100 : 0) + '%');
    position.setAttribute('aria-valuetext', fmtTime(next.currentTime) + ' / ' + fmtTime(next.duration));
    el.timeCurrent.textContent = fmtTime(next.currentTime);
    el.timeTotal.textContent = fmtTime(next.duration);
  }

  function renderTransport(next) {
    el.playIcon.setAttribute('href', next.playing ? '#i-pause' : '#i-play');
    el.play.setAttribute('aria-label', next.playing ? '暂停' : '播放');
    el.undo.classList.toggle('is-off', !next.canUndo);
    el.redo.classList.toggle('is-off', !next.canRedo);
    el.undo.setAttribute('aria-disabled', String(!next.canUndo));
    el.redo.setAttribute('aria-disabled', String(!next.canRedo));
  }

  function renderTimeline(next) {
    for (const clip of el.clips.children) {
      const selected = !state.selectedTimed && Number(clip.dataset.clipId) === next.selectedClipId;
      clip.classList.toggle('is-selected', selected);
      clip.setAttribute('aria-pressed', String(selected));
    }
    const x = state.playheadX - next.currentTime * state.pps;
    el.timelineContent.style.transform = `translate3d(${x}px, 0, 0)`;
  }

  function rebuildRuler(next) {
    el.ruler.replaceChildren();
    if (!(next.duration > 0)) return;
    const duration = next.duration;
    const step = duration > 180 ? 30 : duration > 90 ? 10 : duration > 40 ? 5 : 2;
    const fragment = document.createDocumentFragment();
    for (let second = 0; second <= duration + 1e-6; second += 1) {
      const x = second * state.pps;
      if (Math.round(second) % step === 0) {
        const label = make('span', 'tick-label', fmtTime(second));
        label.style.left = `${x}px`;
        fragment.appendChild(label);
      } else {
        const dot = make('span', 'tick-dot');
        dot.style.left = `${x}px`;
        fragment.appendChild(dot);
      }
    }
    el.ruler.appendChild(fragment);
  }

  function rebuildClips(next) {
    const hadFocus = document.activeElement && document.activeElement.classList.contains('clip');
    el.clips.replaceChildren();
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    for (const clip of next.clips) {
      const width = (clip.end - clip.start) * state.pps;
      if (!(width > 0.4)) continue;
      const node = make('button', 'clip');
      node.type = 'button';
      node.dataset.clipId = String(clip.id);
      node.style.width = `${width}px`;
      node.setAttribute('aria-label', `片段 ${next.clips.indexOf(clip) + 1}`);
      node.title = clip.name ? `${clip.name}` : `片段 ${next.clips.indexOf(clip) + 1}`;
      const count = clamp(Math.ceil(width / TILE_WIDTH), 1, 80);
      const tileWidth = width / count;
      for (let i = 0; i < count; i++) {
        const canvas = make('canvas', 'thumb');
        const scale = Math.min(dpr, 260 / Math.max(tileWidth, 1));
        canvas.width = Math.max(2, Math.round(tileWidth * scale));
        canvas.height = Math.max(2, Math.round(60 * scale));
        canvas.style.width = `${tileWidth}px`;
        const time = clip.start + ((i + 0.5) * tileWidth) / state.pps;
        requestFrame(clip.src, Math.min(time, clip.end - 0.001), canvas);
        node.appendChild(canvas);
      }
      el.clips.appendChild(node);
    }
    if (hadFocus) {
      const selected = el.clips.querySelector(`[data-clip-id="${next.selectedClipId}"]`);
      if (selected) selected.focus({ preventScroll: true });
    }
  }

  function renderCover(next, rebuild) {
    if (!next.clips.length) {
      state.coverTime = null;
      state.coverSrc = null;
      state.coverKey = '';
      el.cover.classList.add('is-empty');
      return;
    }
    el.cover.classList.remove('is-empty');
    if (state.coverTime === null) {
      const first = next.clips[0];
      state.coverTime = first.start;
      state.coverSrc = first.src;
    }
    if (!state.coverSrc) state.coverSrc = next.clips[0].src;
    const key = `${state.coverSrc}|${state.coverTime.toFixed(2)}`;
    if (rebuild || state.coverKey !== key) {
      state.coverKey = key;
      requestFrame(state.coverSrc, state.coverTime, el.coverCanvas);
    }
  }

  function renderTimedTracks(next) {
    renderTimeline(next);
    const hasVideo = next.clips.length > 0;
    const origin = state.playheadX - next.currentTime * state.pps;
    const left = Math.max(0, origin);
    el.mute.hidden = !hasVideo;
    el.cover.hidden = !hasVideo;
    el.audioRow.hidden = !hasVideo || Boolean(state.audio?.track);
    el.audioRow.style.left = left + 'px';
    el.audioRow.style.width = Math.max(0, el.timeline.clientWidth - left) + 'px';
    const overlays = [...state.texts, ...state.stickers, state.pip, state.effectItem].filter(Boolean);
    el.timeline.classList.toggle('has-extra-tracks', overlays.length > 0);
    const items = [state.audio, ...overlays];
    const activeLanes = ['audio', 'text', 'sticker', 'pip', 'effect'].filter(kind =>
      kind === 'audio' || overlays.some(item => item.kind === kind));
    for (const item of items) {
      if (!item?.track) continue;
      const end = Math.min(item.end, next.duration);
      const visible = hasVideo && end > item.start;
      item.track.hidden = !visible;
      item.track.style.left = (origin + item.start * state.pps) + 'px';
      item.track.style.width = Math.max(0, (end - item.start) * state.pps) + 'px';
      item.track.style.setProperty('--timed-lane', activeLanes.indexOf(item.kind));
      const selected = item === state.selectedTimed;
      item.track.classList.toggle('is-selected', selected);
      item.node?.classList.toggle('is-overlay-selected', selected);
      item.track.querySelector('.timed-label').setAttribute('aria-pressed', String(selected));
      for (const handle of item.track.querySelectorAll('.timed-handle')) handle.hidden = !selected;
      const active = visible && next.currentTime >= item.start && next.currentTime < end;
      if (item.node) item.node.hidden = !active;
      if (item.kind === 'effect') el.preview.style.filter = active ? item.filter : '';
    }
  }

  function timedBounds(item) {
    const min = Math.max(0, item.minStart ?? item.anchor ?? 0);
    const max = Math.min(state.data.duration, item.limit ?? Infinity);
    return { min, max, minimumLength: Math.min(0.2, Math.max(0, max - min)) };
  }

  function setTimedRange(item, start, end) {
    item.start = start;
    item.end = end;
    renderTimedTracks(state.data);
    syncBackgroundMedia(state.data);
  }

  function addTimedTrack(item, kind, label) {
    const track = make('div', 'timed-clip timed-' + kind);
    const select = make('button', 'timed-label', label);
    select.type = 'button';
    select.addEventListener('click', () => {
      state.selectedTimed = item;
      renderTimedTracks(state.data);
    });
    track.appendChild(select);
    for (const edge of ['start', 'end']) {
      const handle = make('button', 'timed-handle timed-' + edge, '⋮');
      handle.type = 'button';
      handle.setAttribute('aria-label', edge === 'start' ? '调整开始时间' : '调整结束时间');
      handle.hidden = true;
      let drag = null;

      function trim(value) {
        const { min, max, minimumLength } = timedBounds(item);
        if (edge === 'start') {
          setTimedRange(item, clamp(value, min, Math.max(min, Math.min(item.end, max) - minimumLength)), item.end);
        } else {
          setTimedRange(item, item.start, clamp(value, Math.min(max, item.start + minimumLength), max));
        }
      }

      handle.addEventListener('pointerdown', event => {
        if (!event.isPrimary || event.button !== 0) return;
        event.stopPropagation();
        if (state.data.playing) editor.togglePlayback();
        drag = { id: event.pointerId, x: event.clientX, time: item[edge], pps: state.pps };
        handle.setPointerCapture(event.pointerId);
      });
      function updateDrag(event) {
        if (drag?.id === event.pointerId) trim(drag.time + (event.clientX - drag.x) / drag.pps);
      }
      handle.addEventListener('pointermove', updateDrag);
      handle.addEventListener('pointerup', updateDrag);
      handle.addEventListener('lostpointercapture', () => { drag = null; });
      handle.addEventListener('keydown', event => {
        if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
        event.preventDefault();
        event.stopPropagation();
        trim(item[edge] + (event.key === 'ArrowRight' ? 0.1 : -0.1));
      });
      track.appendChild(handle);
    }
    Object.assign(item, { kind, track });
    el.timedTracks.appendChild(track);
    state.selectedTimed = item;
    renderTimedTracks(state.data);
  }

  function removeTimedTrack(item) {
    item?.track?.remove();
    if (state.selectedTimed === item) state.selectedTimed = null;
  }

  function overlayRange() {
    const duration = state.data?.duration || 0;
    const start = Math.min(state.data?.currentTime || 0, Math.max(0, duration - 0.2));
    return { start, end: Math.min(duration, start + 3) };
  }
  function renderMute() {
    const muted = state.data ? state.data.muted : state.muted;
    el.mute.classList.toggle('is-muted', muted);
    el.mute.setAttribute('aria-pressed', String(muted));
    el.mute.setAttribute('aria-label', muted ? '开启原声' : '关闭原声');
    el.muteLabel.textContent = muted ? '开启原声' : '关闭原声';
    el.muteIcon.setAttribute('href', muted ? '#i-mute' : '#i-volume');
  }

  function renderEmptyState(next) {
    const hasClips = Boolean(next && next.clips.length);
    const hasError = Boolean(next && next.error);
    if (hasError) {
      el.stageMessage.hidden = false;
      el.stageMessage.textContent = next.error;
      el.stageLoader.hidden = true;
      return;
    }
    if (hasClips) {
      el.stageMessage.hidden = true;
      el.stageLoader.hidden = true;
      return;
    }
    const waited = performance.now() - state.bootAt > 350;
    el.stageLoader.hidden = state.videoReady || !waited;
    el.stageMessage.hidden = !state.videoReady;
    el.stageMessage.textContent = '还没有视频片段\n点击右下角的 + 添加视频';
    el.stageMessage.style.whiteSpace = 'pre-line';
  }

  /* ------------------------------------------------------------------ */
  /* 预览、音频、画中画同步                                             */
  /* ------------------------------------------------------------------ */

  function syncBackgroundMedia(next) {
    syncAudio(next);
    const item = state.pip;
    if (!item?.track || item.el.readyState < 1) return;
    const video = item.el;
    const active = next.currentTime >= item.start && next.currentTime < Math.min(next.duration, item.end);
    const target = clamp(next.currentTime - item.anchor, 0, video.duration);
    if (Math.abs(video.currentTime - target) > (next.playing ? 0.3 : 0.04)) video.currentTime = target;
    if (active && next.playing) {
      if (video.paused) video.play().catch(() => {});
    } else if (!video.paused) {
      video.pause();
    }
  }
  function syncAudio(next) {
    const item = state.audio;
    if (!item?.track || item.el.readyState < 1) return;
    const audio = item.el;
    const elapsed = next.currentTime - item.start;
    const remaining = Math.min(next.duration, item.end) - next.currentTime;
    const fade = Math.min(item.fade || 0, (item.end - item.start) / 2);
    audio.volume = item.volume * (fade ? clamp(Math.min(elapsed, remaining) / fade, 0, 1) : 1);
    const active = next.playing && next.currentTime >= item.start &&
      next.currentTime < Math.min(item.end, next.duration);
    const target = clamp(next.currentTime - item.anchor, 0, item.duration);
    if (!active) {
      if (!audio.paused) audio.pause();
      if (Math.abs(audio.currentTime - target) > 0.08) audio.currentTime = target;
      return;
    }
    if (audio.paused) {
      audio.currentTime = target;
      audio.play().catch(() => {});
    } else if (performance.now() - state.lastAudioSync > 500) {
      state.lastAudioSync = performance.now();
      if (Math.abs(audio.currentTime - target) > 0.25) audio.currentTime = target;
    }
  }

  /* ------------------------------------------------------------------ */
  /* 交互：播放 / 分割 / 撤销 / 静音 / 全屏                             */
  /* ------------------------------------------------------------------ */

  function toast(message, duration = 1900) {
    el.toast.textContent = message;
    if (!el.sheetRoot.hidden) {
      const appTop = el.app.getBoundingClientRect().top;
      const sheetTop = el.sheet.getBoundingClientRect().top;
      el.toast.style.bottom = `${Math.max(96, el.app.clientHeight - (sheetTop - appTop) + 18)}px`;
    } else {
      el.toast.style.bottom = '';
    }
    el.toast.classList.add('show');
    clearTimeout(state.toastTimer);
    state.toastTimer = setTimeout(() => el.toast.classList.remove('show'), duration);
  }

  function togglePlayback() {
    const data = state.data;
    if (!data || !data.clips.length) {
      toast('先添加一段视频');
      return;
    }
    editor.togglePlayback();
  }

  function doSplit() {
    const data = state.data;
    if (!data || !data.clips.length) {
      toast('还没有可分割的片段');
      return;
    }
    if (!data.canSplit) {
      toast('把白色播放头移到片段中间再分割');
      return;
    }
    if (editor.splitAtPlayhead()) {
      toast('已在播放头处分割');
      refreshSheet();
    }
  }

  function doDelete() {
    const data = state.data;
    if (!data || !data.clips.length) {
      toast('还没有视频片段');
      return;
    }
    if (data.selectedClipId === null) {
      toast('请先把播放头移到要删除的片段上');
      return;
    }
    editor.deleteClip(data.selectedClipId);
    toast('已删除当前片段');
    refreshSheet();
  }

  function doDuplicate() {
    const data = state.data;
    if (!data || !data.clips.length) {
      toast('还没有视频片段');
      return;
    }
    if (data.selectedClipId === null) {
      toast('请先把播放头移到要复制的片段上');
      return;
    }
    if (editor.duplicateClip(data.selectedClipId)) toast('已复制当前片段');
    refreshSheet();
  }

  function doUndo() {
    if (!state.data || !state.data.canUndo) {
      toast('没有可撤销的操作');
      return;
    }
    if (editor.undo()) {
      toast('已撤销');
      refreshSheet();
    }
  }

  function doRedo() {
    if (!state.data || !state.data.canRedo) {
      toast('没有可重做的操作');
      return;
    }
    if (editor.redo()) {
      toast('已重做');
      refreshSheet();
    }
  }

  function toggleMute() {
    editor.toggleMute();
    toast(state.data && state.data.muted ? '已关闭原声' : '已开启原声');
  }

  function inPreviewMode() {
    return el.app.classList.contains('preview-mode');
  }

  async function enterPreviewMode() {
    el.app.classList.add('preview-mode');
    el.previewExit.hidden = false;
    if (state.sheet) closeSheet();
    if (!el.modalRoot.hidden) closeModal();
    try {
      if (el.app.requestFullscreen && !document.fullscreenElement) {
        await el.app.requestFullscreen({ navigationUI: 'hide' });
      }
    } catch {
      /* 浏览器不允许全屏时，使用页面内的预览模式 */
    }
    updateFullscreenIcon();
  }

  async function exitPreviewMode() {
    el.app.classList.remove('preview-mode');
    el.previewExit.hidden = true;
    if (document.fullscreenElement) {
      try {
        await document.exitFullscreen();
      } catch {
        /* ignore */
      }
    }
    updateFullscreenIcon();
  }

  function toggleFullscreen() {
    if (inPreviewMode()) exitPreviewMode();
    else enterPreviewMode();
  }

  function updateFullscreenIcon() {
    const active = Boolean(document.fullscreenElement) || inPreviewMode();
    el.fullscreenIcon.setAttribute('href', active ? '#i-collapse' : '#i-expand');
    el.fullscreen.setAttribute('aria-label', active ? '退出全屏' : '全屏预览');
  }

  /* ------------------------------------------------------------------ */
  /* 顶部：清晰度 / 导出 / 关闭                                         */
  /* ------------------------------------------------------------------ */

  function closeQualityMenu() {
    el.qualityMenu.hidden = true;
    el.quality.setAttribute('aria-expanded', 'false');
  }

  function toggleQualityMenu() {
    const willOpen = el.qualityMenu.hidden;
    el.qualityMenu.hidden = !willOpen;
    el.quality.setAttribute('aria-expanded', String(willOpen));
  }

  function setQuality(value) {
    const label = RES_LABEL[value] || '1080p';
    state.quality = label;
    el.qualityLabel.textContent = label;
    $$('#quality-menu button').forEach(button => {
      button.setAttribute('aria-checked', String(button.dataset.quality === value));
    });
    closeQualityMenu();
  }

  function openExitModal() {
    el.modalCard.innerHTML = `
      <h2>退出剪辑？</h2>
      <p class="modal-sub">当前项目不会被保存，已添加的片段、音频、文字都会丢失。</p>
      <div class="modal-actions">
        <button class="btn ghost" type="button" data-act="cancel">继续编辑</button>
        <button class="btn primary" type="button" data-act="exit">退出</button>
      </div>`;
    el.modalCard.querySelector('[data-act="cancel"]').addEventListener('click', closeModal);
    el.modalCard.querySelector('[data-act="exit"]').addEventListener('click', () => {
      closeModal();
      closeSheet();
      if (state.data && state.data.playing) editor.togglePlayback();
      el.closedScreen.hidden = false;
      if (state.audio) state.audio.el.pause();
      if (state.pip) state.pip.el.pause();
    });
    showModal();
  }

  function openCoverModal() {
    el.modalCard.innerHTML = `
      <h2>设置封面</h2>
      <p class="modal-sub">使用白色播放头所在的画面作为项目封面。</p>
      <div class="modal-preview"></div>
      <div class="modal-actions">
        <button class="btn ghost" type="button" data-act="cancel">取消</button>
        <button class="btn primary" type="button" data-act="set">设为封面</button>
      </div>`;
    const holder = el.modalCard.querySelector('.modal-preview');
    const canvas = make('canvas');
    canvas.width = 480;
    canvas.height = 270;
    holder.appendChild(canvas);
    if (state.data && state.data.clips.length) drawCurrentFrame(canvas);
    el.modalCard.querySelector('[data-act="cancel"]').addEventListener('click', closeModal);
    el.modalCard.querySelector('[data-act="set"]').addEventListener('click', () => {
      const data = state.data;
      if (!data || !data.clips.length) {
        toast('还没有可设置封面的画面');
        return;
      }
      const loc = locate(data.currentTime);
      if (!loc) return;
      state.coverTime = loc.clip.start + loc.offset;
      state.coverSrc = loc.clip.src;
      state.coverKey = '';
      renderCover(data, true);
      closeModal();
      toast('封面已更新');
    });
    showModal();
  }

  function showExportSuccess() {
    el.modalCard.replaceChildren();
    const wrap = make('div', 'export-success');
    wrap.innerHTML = `
      <div class="success-mark">
        <svg class="icon icon-24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4.8 12.6l4.6 4.6L19.4 6.8"/></svg>
      </div>
      <strong>导出成功</strong>
      <span>已保存到相册 · 演示模式</span>`;
    const actions = make('div', 'modal-actions');
    const done = make('button', 'btn primary', '完成');
    done.type = 'button';
    done.addEventListener('click', closeModal);
    actions.appendChild(done);
    el.modalCard.append(wrap, actions);
    toast('导出完成（演示）', 2400);
  }

  function openExportModal() {
    const data = state.data;
    const duration = data ? data.duration : 0;
    if (!data || !data.clips.length) {
      toast('还没有可以导出的内容');
      return;
    }
    el.modalCard.innerHTML = `
      <h2>导出视频</h2>
      <p class="modal-sub">演示模式下不会生成真实文件，进度条仅用于展示界面。</p>
      <div class="export-row">
        <div class="export-thumb"></div>
        <div>
          <div class="export-title">视频剪辑</div>
          <div class="export-meta">时长 ${fmtTime(duration)} · ${state.quality} · 30fps<br>MP4 · 预计 ${estimateSize(duration)} MB</div>
        </div>
      </div>
      <div class="export-progress" hidden>
        <div class="progress"><i></i></div>
        <div class="progress-label"><span>正在导出…</span><span class="pct">0%</span></div>
      </div>
      <div class="modal-actions">
        <button class="btn ghost" type="button" data-act="cancel">取消</button>
        <button class="btn primary" type="button" data-act="start">开始导出</button>
      </div>`;

    const thumb = el.modalCard.querySelector('.export-thumb');
    const canvas = make('canvas');
    canvas.width = 196;
    canvas.height = 110;
    thumb.appendChild(canvas);
    drawCurrentFrame(canvas);

    el.modalCard.querySelector('[data-act="cancel"]').addEventListener('click', closeModal);
    el.modalCard.querySelector('[data-act="start"]').addEventListener('click', () => {
      const progress = el.modalCard.querySelector('.export-progress');
      const actions = el.modalCard.querySelector('.modal-actions');
      const bar = el.modalCard.querySelector('.progress i');
      const pct = el.modalCard.querySelector('.pct');
      const status = el.modalCard.querySelector('.progress-label span');
      progress.hidden = false;
      actions.hidden = true;
      state.modalBusy = true;
      let value = 0;
      state.exportTimer = setInterval(() => {
        value = Math.min(100, value + 2 + Math.random() * 7);
        bar.style.width = `${value}%`;
        pct.textContent = `${Math.round(value)}%`;
        if (value >= 100) {
          clearInterval(state.exportTimer);
          state.exportTimer = null;
          status.textContent = '处理完成';
          setTimeout(() => {
            if (state.modalBusy) {
              state.modalBusy = false;
              showExportSuccess();
            }
          }, 320);
        }
      }, 90);
    });
    showModal();
  }

  function showModal() {
    el.modalRoot.hidden = false;
  }

  function closeModal() {
    state.modalBusy = false;
    if (state.exportTimer) {
      clearInterval(state.exportTimer);
      state.exportTimer = null;
    }
    el.modalRoot.hidden = true;
    el.modalCard.replaceChildren();
  }

  /* ------------------------------------------------------------------ */
  /* 底部工具面板                                                       */
  /* ------------------------------------------------------------------ */

  function optionButton({ label, icon, emoji, onClick, className = '' }) {
    const button = make('button', `option ${className}`.trim());
    button.type = 'button';
    if (icon) {
      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.setAttribute('class', 'icon');
      const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
      use.setAttribute('href', `#${icon}`);
      svg.appendChild(use);
      button.appendChild(svg);
    } else if (emoji) {
      button.appendChild(make('span', 'emoji', emoji));
    }
    button.appendChild(make('span', 'option-label', label));
    button.addEventListener('click', onClick);
    return button;
  }

  function optionGrid(items, extraClass = '') {
    const grid = make('div', `option-grid ${extraClass}`.trim());
    grid.append(...items);
    return grid;
  }

  function miniRow({ icon, name, sub }) {
    const row = make('div', 'mini-row');
    const iconBox = make('div', 'mini-icon');
    iconBox.innerHTML = `<svg class="icon icon-20"><use href="#${icon}"></use></svg>`;
    const main = make('div', 'mini-main');
    main.append(make('div', 'mini-name', name), make('div', 'mini-sub', sub));
    row.append(iconBox, main);
    return row;
  }

  function note(text) {
    return make('p', 'sheet-note', text);
  }

  function controlRange(label, min, max, value, onInput, unit = '') {
    const row = make('label', 'sheet-range');
    const slider = make('input');
    slider.type = 'range';
    slider.min = min;
    slider.max = max;
    slider.value = value;
    const result = make('output');
    const show = () => { result.value = slider.value + unit; };
    slider.addEventListener('input', () => { show(); onInput(slider.valueAsNumber); });
    slider.addEventListener('keydown', event => event.stopPropagation());
    show();
    row.append(make('span', '', label), slider, result);
    return row;
  }

  function audioControls(item) {
    return [
      controlRange('音量', 0, 100, item.volume * 100, value => {
        item.volume = value / 100;
        syncAudio(state.data);
      }, '%'),
      controlRange('淡入淡出', 0, 20, (item.fade || 0) * 10, value => {
        item.fade = value / 10;
        syncAudio(state.data);
      }, ' × 0.1 秒')
    ];
  }

  function pipSizeControl(item) {
    return controlRange('画中画大小', 15, 75, parseFloat(item.node.style.width) || 34, value => {
      item.node.style.width = value + '%';
    }, '%');
  }

  function textStyles(current, change) {
    const group = make('div', 'text-styles');
    group.setAttribute('role', 'group');
    group.setAttribute('aria-label', '文字样式');
    for (const [value, label] of [['plain', '白色'], ['outline', '描边'], ['highlight', '黄色']]) {
      const button = make('button', 'chip', label);
      button.type = 'button';
      button.setAttribute('aria-pressed', String(value === current));
      button.addEventListener('click', () => {
        change(value);
        for (const choice of group.children) choice.setAttribute('aria-pressed', String(choice === button));
      });
      group.appendChild(button);
    }
    return group;
  }

  async function addClipAudio() {
    if (!state.data?.duration) { toast('请先添加视频'); return; }
    const selected = locate(state.data.currentTime);
    if (!selected) { toast('请先添加视频'); return; }
    const { clip, index } = selected;
    const projectStart = startOfClip(index);
    try {
      const blob = clip.src.startsWith('blob:') ? await (await fetch(clip.src)).blob() : null;
      addAudio(blob, { clip, projectStart, index });
    } catch {
      toast('无法读取当前视频的声音');
    }
  }

  function timedRangeForm(item) {
    const form = make('form', 'timed-range-form');
    const fields = ['开始（秒）', '结束（秒）'].map((caption, index) => {
      const label = make('label', '', caption);
      const input = make('input', 'text-input');
      input.type = 'number';
      input.step = 'any';
      input.min = '0';
      input.required = true;
      input.value = (index ? Math.min(item.end, state.data.duration) : item.start).toFixed(3);
      label.appendChild(input);
      form.appendChild(label);
      return input;
    });
    const save = make('button', 'btn primary', '应用时间');
    save.type = 'submit';
    form.appendChild(save);
    form.addEventListener('submit', event => {
      event.preventDefault();
      const [start, end] = fields.map(input => input.valueAsNumber);
      const { min, max, minimumLength } = timedBounds(item);
      if (!Number.isFinite(start) || !Number.isFinite(end) || start < min || end > max + 0.0005 || end - start < minimumLength - 0.0005 || start >= end) {
        toast('请在项目时长内设置起止时间，片段至少保留 0.2 秒');
        return;
      }
      const boundedEnd = Math.min(end, max);
      if (state.data.playing) editor.togglePlayback();
      setTimedRange(item, Math.max(min, Math.min(start, boundedEnd - minimumLength)), boundedEnd);
      editor.seek(item.start);
      closeSheet();
      toast('已更新时间');
    });
    return form;
  }

  function buildTimedEditSheet(item) {
    const kind = { text: '文字', sticker: '贴纸', audio: '音频', pip: '画中画', effect: '特效' }[item.kind];
    const label = item.text ?? item.name;
    const nodes = [note('当前选中：' + kind + ' · ' + label)];
    if (item.kind === 'text') {
      const form = make('form', 'text-form');
      const input = make('input', 'text-input');
      input.value = item.text;
      input.maxLength = 30;
      input.required = true;
      input.setAttribute('aria-label', '编辑选中文字');
      const save = make('button', 'btn primary', '保存文字');
      save.type = 'submit';
      form.append(input, save);
      form.addEventListener('submit', event => {
        event.preventDefault();
        const value = input.value.trim();
        if (!value) return;
        item.text = value;
        item.node.querySelector('.overlay-text-content').textContent = value;
        item.node.setAttribute('aria-label', '移动文字：' + value);
        item.track.querySelector('.timed-label').textContent = value;
        closeSheet();
      });
      const split = optionButton({ label: '分割', icon: 'i-split', onClick: () => splitTextAtPlayhead(item) });
      const at = state.data.currentTime;
      split.disabled = at - item.start < 0.1 || Math.min(item.end, state.data.duration) - at < 0.1;
      nodes.push(form, textStyles(item.node.dataset.textStyle, value => { item.node.dataset.textStyle = value; }), optionGrid([split]));
    }
    if (item.kind === 'sticker') {
      nodes.push(controlRange('贴纸大小', 20, 90, parseFloat(getComputedStyle(item.node).fontSize), value => {
        item.node.style.fontSize = value + 'px';
        item.node.style.width = item.node.style.height = (value + 8) + 'px';
      }));
      nodes.push(controlRange('贴纸透明度', 10, 100, Number(item.node.style.opacity || 1) * 100,
        value => { item.node.style.opacity = value / 100; }, '%'));
    }
    if (item.kind === 'text' || item.kind === 'sticker') nodes.push(timedRangeForm(item));
    if (item.kind === 'audio') nodes.push(...audioControls(item));
    if (item.kind === 'pip') nodes.push(pipSizeControl(item));
    nodes.push(optionGrid([
      optionButton({ label: '删除' + kind, icon: 'i-trash', onClick: () => {
        if (item.kind === 'audio') removeAudio();
        else if (item.kind === 'pip') removePip();
        else if (item.kind === 'effect') applyEffect('original');
        else item.node.querySelector('.ov-remove').click();
        closeSheet();
      } })
    ]), note('拖动轨道片段两端可调整起止时间。'));
    return nodes;
  }

  function buildEditSheet() {
    if (state.selectedTimed) return buildTimedEditSheet(state.selectedTimed);
    const data = state.data;
    const selectedIndex = data && data.selectedClipId !== null
      ? data.clips.findIndex(clip => clip.id === data.selectedClipId)
      : -1;
    const grid = optionGrid([
      optionButton({ label: '分割', icon: 'i-split', onClick: doSplit }),
      optionButton({ label: '删除', icon: 'i-trash', onClick: doDelete }),
      optionButton({ label: '复制', icon: 'i-copy', onClick: doDuplicate }),
      optionButton({ label: '撤销', icon: 'i-undo', onClick: doUndo }),
      optionButton({ label: '重做', icon: 'i-redo', onClick: doRedo }),
    ], 'cols-5');
    let info = '当前没有选中的片段，请把播放头移到片段上。';
    if (selectedIndex >= 0) {
      const clip = data.clips[selectedIndex];
      info = `当前片段：片段 ${selectedIndex + 1} · ${fmtTime(startOfClip(selectedIndex))} - ${fmtTime(startOfClip(selectedIndex) + (clip.end - clip.start))}`;
    }
    return [grid, note(`${info} 分割以白色播放头为准。`)];
  }

  function buildAudioSheet() {
    const nodes = [];
    if (state.audio) {
      nodes.push(miniRow({
        icon: 'i-music',
        name: state.audio.name,
        sub: '已添加到时间轴，会跟随播放头播放',
      }));
      nodes.push(...audioControls(state.audio));
      nodes.push(optionGrid([
        optionButton({ label: '更换音频', icon: 'i-music', onClick: () => el.fileAudio.click() }),
        optionButton({ label: '移除音频', icon: 'i-trash', onClick: removeAudioFromUI }),
      ], 'cols-2'));
    } else {
      nodes.push(optionGrid([
        optionButton({ label: '本地音频', icon: 'i-music', onClick: () => el.fileAudio.click() }),
        optionButton({ label: '提取音频', icon: 'i-audio-file', onClick: addClipAudio }),
      ], 'cols-3'));
      nodes.push(note('导入音频，或把白线所在视频片段的原声加入音轨。需要单独听音轨时，可以关闭视频原声。'));
    }
    return nodes;
  }

  function buildTextSheet() {
    const form = make('div', 'text-form');
    const input = make('input', 'text-input');
    input.type = 'text';
    input.placeholder = '输入文字，例如：新的一天';
    input.maxLength = 30;
    input.setAttribute('aria-label', '输入文字');
    const add = make('button', 'btn primary', '添加');
    add.type = 'button';
    let textStyle = 'highlight';
    const draft = make('div', 'text-overlay text-draft');
    draft.setAttribute('aria-hidden', 'true');
    draft.style.pointerEvents = 'none';
    el.textStack.appendChild(draft);
    state.textDraft = draft;
    function refreshDraft() {
      positionNewText(draft);
      draft.dataset.textStyle = textStyle;
      draft.textContent = input.value.trim() || '输入文字…';
      draft.hidden = !state.data?.duration;
    }
    const styles = textStyles(textStyle, value => {
      textStyle = value;
      refreshDraft();
    });
    input.addEventListener('input', refreshDraft);
    refreshDraft();
    const submit = () => {
      const text = input.value.trim();
      if (!text) {
        toast('请输入文字');
        input.focus();
        return;
      }
      if (!state.data?.duration) { toast('请先添加视频'); return; }
      addTextOverlay(text, textStyle);
      closeSheet();
      toast('文字已添加到画面');
    };
    add.addEventListener('click', submit);
    input.addEventListener('keydown', event => {
      if (event.key === 'Enter' && !event.isComposing) {
        event.preventDefault();
        submit();
      }
    });
    form.append(input, add);

    const presets = make('div', 'text-presets');
    for (const preset of ['你好', '新的一天', '记录生活', '周末愉快', '2026', '获奖时刻']) {
      const chip = make('button', 'chip', preset);
      chip.type = 'button';
      chip.addEventListener('click', () => {
        input.value = preset;
        refreshDraft();
        input.focus();
      });
      presets.appendChild(chip);
    }

    const nodes = [form, styles, presets];
    if (state.texts.length) {
      nodes.push(note(`画面中已有 ${state.texts.length} 段文字，点击文字右上角的 × 可以删除。`));
    } else {
      nodes.push(note('添加后可在预览画面中拖动文字。'));
    }
    return nodes;
  }

  function buildStickerSheet() {
    const grid = make('div', 'sticker-grid');
    for (const emoji of STICKERS) {
      const button = make('button', 'sticker-option', emoji);
      button.type = 'button';
      button.setAttribute('aria-label', `添加贴纸 ${emoji}`);
      button.addEventListener('click', () => {
        if (!state.data?.duration) { toast('请先添加视频'); return; }
        addSticker(emoji);
        if (!state.stickerHintShown) {
          state.stickerHintShown = true;
          toast('拖动贴纸可移动，点 × 可删除');
        }
      });
      grid.appendChild(button);
    }
    const importButton = make('button', 'btn primary', '导入图片贴纸');
    importButton.type = 'button';
    importButton.addEventListener('click', () => {
      if (!state.data?.duration) { toast('请先添加视频'); return; }
      el.fileSticker.click();
    });
    return [importButton, grid, note('贴纸可在预览中拖动，点右上角的 × 可删除。')];
  }

  function buildPipSheet() {
    const nodes = [];
    if (state.pip) {
      nodes.push(miniRow({
        icon: 'i-pip',
        name: '画中画 1',
        sub: '拖动画面可改变位置，拖动轨道手柄可调整时间',
      }));
      nodes.push(pipSizeControl(state.pip));
      nodes.push(optionGrid([
        optionButton({ label: '更换画面', icon: 'i-image', onClick: () => el.filePip.click() }),
        optionButton({ label: '移除画中画', icon: 'i-trash', onClick: removePipFromUI }),
      ], 'cols-2'));
    } else {
      nodes.push(optionGrid([
        optionButton({ label: '选择视频', icon: 'i-image', onClick: () => el.filePip.click() }),
      ], 'cols-1'));
      nodes.push(note('画中画从白线处开始，可在预览中拖动位置。'));
    }
    return nodes;
  }

  function buildEffectSheet() {
    const grid = make('div', 'effect-grid');
    for (const effect of EFFECTS) {
      const button = make('button', `effect-option${state.effect === effect.id ? ' is-active' : ''}`);
      button.type = 'button';
      button.dataset.effect = effect.id;
      const swatch = make('span', 'effect-swatch');
      const canvas = make('canvas');
      canvas.width = 180;
      canvas.height = 112;
      canvas.style.cssText = 'width:100%;height:100%;display:block';
      if (el.preview.readyState >= 2) {
        drawCover(el.preview, canvas.getContext('2d'), canvas.width, canvas.height);
      } else {
        swatch.style.background = effect.swatch;
      }
      canvas.style.filter = effect.filter;
      swatch.appendChild(canvas);
      button.append(swatch, make('span', 'effect-name', effect.name));
      button.addEventListener('click', () => {
        applyEffect(effect.id);
        $$('.effect-option', grid).forEach(node => {
          node.classList.toggle('is-active', node.dataset.effect === effect.id);
        });
        toast(`已应用特效：${effect.name}`);
      });
      grid.appendChild(button);
    }
    return [grid, note('特效默认从白线开始，拖动特效轨道可调整位置和时长。')];
  }

  function buildMaterialSheet() {
    const grid = optionGrid([
      optionButton({ label: '本地视频', icon: 'i-plus', onClick: () => el.fileVideo.click() }),
      optionButton({ label: '添加文本', icon: 'i-text', onClick: () => openSheet('text') }),
      optionButton({ label: '添加贴纸', icon: 'i-sticker', onClick: () => openSheet('sticker') }),
      optionButton({ label: '添加音频', icon: 'i-music', onClick: () => openSheet('audio') }),
    ]);
    return [grid, note('添加的视频会插入到当前片段之后，可继续分割和编辑。')];
  }

  const SHEETS = {
    edit: { title: '剪辑', build: buildEditSheet },
    audio: { title: '音频', build: buildAudioSheet },
    text: { title: '文本', build: buildTextSheet },
    sticker: { title: '贴纸', build: buildStickerSheet },
    pip: { title: '画中画', build: buildPipSheet },
    effect: { title: '特效', build: buildEffectSheet },
    material: { title: '素材', build: buildMaterialSheet },
  };

  function updateActiveTool() {
    $$('.tool').forEach(button => {
      button.classList.toggle('is-active', button.dataset.tool === state.sheet);
    });
  }

  function clearTextDraft() {
    state.textDraft?.remove();
    state.textDraft = null;
  }

  function openSheet(tool) {
    const definition = SHEETS[tool];
    if (!definition) return;
    const wasOpen = !el.sheetRoot.hidden && state.sheet !== null;
    clearTextDraft();
    state.sheet = tool;
    el.sheetTitle.textContent = definition.title;
    el.sheetBody.replaceChildren(...definition.build());
    el.sheetBody.scrollTop = 0;
    updateActiveTool();
    closeQualityMenu();
    el.toast.classList.remove('show');
    if (wasOpen) return;
    el.sheetRoot.hidden = false;
    el.sheetRoot.getBoundingClientRect();
    requestAnimationFrame(() => el.sheetRoot.classList.add('open'));
    if (state.data && state.data.playing) editor.togglePlayback();
  }

  function refreshSheet() {
    if (!state.sheet || el.sheetRoot.hidden) return;
    const definition = SHEETS[state.sheet];
    if (!definition) return;
    clearTextDraft();
    el.sheetBody.replaceChildren(...definition.build());
  }

  function closeSheet() {
    if (el.sheetRoot.hidden) return;
    clearTextDraft();
    el.sheetRoot.classList.remove('open');
    el.toast.style.bottom = '';
    state.sheet = null;
    updateActiveTool();
    setTimeout(() => {
      if (!state.sheet) el.sheetRoot.hidden = true;
    }, 300);
  }

  /* ------------------------------------------------------------------ */
  /* 文字 / 贴纸 / 特效 / 画中画 / 音频                                 */
  /* ------------------------------------------------------------------ */

  function enableOverlayDrag(node, layer) {
    let drag = null;
    function moveTo(left, top) {
      const { width, height } = layer.getBoundingClientRect();
      if (!width || !height) return;
      const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
      const x = Math.min(50, node.offsetWidth / width * 50);
      const y = Math.min(50, node.offsetHeight / height * 50);
      node.style.left = clamp(left, x, Math.max(x, 100 - x - 16 / width * 100)) + '%';
      node.style.top = clamp(top, Math.min(50, y + 12 / height * 100), 100 - y) + '%';
    }

    node.tabIndex = 0;
    node.addEventListener('keydown', event => {
      if (event.target !== node) return;
      const steps = { ArrowLeft: [-2, 0], ArrowRight: [2, 0], ArrowUp: [0, -2], ArrowDown: [0, 2] };
      const step = steps[event.key];
      if (!step) return;
      event.preventDefault();
      event.stopPropagation();
      moveTo(parseFloat(node.style.left) + step[0], parseFloat(node.style.top) + step[1]);
    });

    node.addEventListener('pointerdown', event => {
      if (!event.isPrimary || event.button !== 0 || event.target.closest('.ov-remove, .ov-scale, .pip-remove')) return;
      drag = {
        id: event.pointerId,
        x: event.clientX,
        y: event.clientY,
        left: parseFloat(node.style.left),
        top: parseFloat(node.style.top)
      };
      node.setPointerCapture(event.pointerId);
    });
    node.addEventListener('pointermove', event => {
      if (!drag || drag.id !== event.pointerId) return;
      const dx = event.clientX - drag.x;
      const dy = event.clientY - drag.y;
      if (!drag.started && Math.hypot(dx, dy) < 5) return;
      drag.started = true;
      const { width, height } = layer.getBoundingClientRect();
      if (width && height) moveTo(drag.left + dx / width * 100, drag.top + dy / height * 100);
    });
    node.addEventListener('lostpointercapture', () => { drag = null; });
  }

  function splitTextAtPlayhead(item) {
    const at = state.data.currentTime;
    if (at - item.start < 0.1 || Math.min(item.end, state.data.duration) - at < 0.1) return;
    const end = item.end;
    item.end = at;
    addTextOverlay(item.text, item.node.dataset.textStyle, { start: at, end, source: item });
    closeSheet();
    toast('已在白线处分割文字');
  }

  function positionNewText(node) {
    node.style.left = '50%';
    node.style.top = Math.min(82, 48 + state.texts.length * 9) + '%';
  }

  function addTextOverlay(text, textStyle, split) {
    const node = make('div', 'text-overlay');
    node.setAttribute('aria-label', '移动文字：' + text);
    node.dataset.textStyle = textStyle;
    positionNewText(node);
    if (split) {
      node.style.cssText = split.source.node.style.cssText;
      node.classList.toggle('is-resized', split.source.node.classList.contains('is-resized'));
    }
    enableOverlayDrag(node, el.textStack);
    const glyph = make('span', 'overlay-text-content', text);
    node.appendChild(glyph);
    const remove = make('button', 'ov-remove', '×');
    remove.type = 'button';
    remove.setAttribute('aria-label', '删除这段文字');
    remove.addEventListener('click', event => {
      event.stopPropagation();
      node.remove();
      removeTimedTrack(state.texts.find(item => item.node === node));
      state.texts = state.texts.filter(item => item.node !== node);
      renderTimedTracks(state.data);
      toast('已删除文字');
      updateTextSheetNote();
    });
    node.appendChild(remove);
    el.textStack.appendChild(node);
    const range = split ? { start: split.start, end: split.end } : overlayRange();
    const item = { node, text, ...range, rotation: split?.source.rotation || 0 };
    state.texts.push(item);
    addTimedTrack(item, 'text', text);
    if (!split) node.classList.remove('is-overlay-selected');
    node.addEventListener('pointerdown', event => {
      if (event.target.closest('.ov-remove, .ov-scale, .pip-remove')) return;
      state.selectedTimed = item;
      renderTimedTracks(state.data);
    });
    node.addEventListener('focus', () => {
      state.selectedTimed = item;
      renderTimedTracks(state.data);
    });
    for (const [dx, dy, label] of [
      [-1, -1, '左上角'], [0, -1, '上边'], [1, -1, '右上角'],
      [-1, 0, '左边'], [1, 0, '右边'],
      [-1, 1, '左下角'], [0, 1, '下边'], [1, 1, '右下角']
    ]) {
      const handle = make('button', 'ov-scale');
      handle.type = 'button';
      handle.setAttribute('aria-label', label + '缩放文字');
      handle.style.left = (dx + 1) * 50 + '%';
      handle.style.top = (dy + 1) * 50 + '%';
      handle.style.cursor = !dx ? 'ns-resize' : !dy ? 'ew-resize' :
        dx === dy ? 'nwse-resize' : 'nesw-resize';
      node.appendChild(handle);

      let drag;
      function resize(width, height, fontSize, x, y) {
        const maxWidth = el.textStack.clientWidth;
        const maxHeight = el.textStack.clientHeight;
        if (!width || !height || !maxWidth || !maxHeight) return;
        node.classList.add('is-resized');
        let newWidth = width;
        let newHeight = height;
        if (dx && dy) {
          const factor = 1 + (dx * x * width + dy * y * height) / (width ** 2 + height ** 2);
          const max = Math.min(maxWidth / width, maxHeight / height);
          const min = Math.min(max, Math.max(18 / width, 14 / height));
          const scale = clamp(factor, min, max);
          newWidth *= scale;
          newHeight *= scale;
          node.style.fontSize = fontSize * scale + 'px';
        } else if (dx) {
          newWidth = clamp(width + dx * x, Math.min(maxWidth, Math.max(18, fontSize * 1.05)), maxWidth);
        } else {
          newHeight = clamp(height + dy * y, 14, maxHeight);
        }
        node.style.width = newWidth + 'px';
        node.style.height = newHeight + 'px';
        if (dx && !dy) {
          node.style.height = Math.min(maxHeight, Math.max(height, glyph.scrollHeight)) + 'px';
        }
      }

      handle.addEventListener('pointerdown', event => {
        if (!event.isPrimary || event.button !== 0) return;
        event.stopPropagation();
        drag = { id: event.pointerId, x: event.clientX, y: event.clientY,
          width: node.offsetWidth, height: node.offsetHeight,
          fontSize: parseFloat(getComputedStyle(node).fontSize) };
        handle.setPointerCapture(event.pointerId);
      });
      function followPointer(event) {
        if (drag?.id !== event.pointerId) return;
        const deltaX = (event.clientX - drag.x) * 2;
        const deltaY = (event.clientY - drag.y) * 2;
        const angle = item.rotation || 0;
        const x = deltaX * Math.cos(angle) + deltaY * Math.sin(angle);
        const y = -deltaX * Math.sin(angle) + deltaY * Math.cos(angle);
        if (x || y) resize(drag.width, drag.height, drag.fontSize, x, y);
      }
      handle.addEventListener('pointermove', followPointer);
      handle.addEventListener('pointerup', followPointer);
      handle.addEventListener('lostpointercapture', () => { drag = null; });
      handle.addEventListener('keydown', event => {
        const increase = event.key === 'ArrowRight' || event.key === 'ArrowUp';
        if (!increase && !['ArrowLeft', 'ArrowDown'].includes(event.key)) return;
        event.preventDefault();
        event.stopPropagation();
        const step = increase ? 4 : -4;
        const { offsetWidth: width, offsetHeight: height } = node;
        resize(width, height, parseFloat(getComputedStyle(node).fontSize), dx * step, dy * step);
      });
    }
    updateTextSheetNote();
  }

  function updateTextSheetNote() {
    if (state.sheet !== 'text') return;
    const noteEl = el.sheetBody.querySelector('.sheet-note');
    if (!noteEl) return;
    noteEl.textContent = state.texts.length
      ? `画面中已有 ${state.texts.length} 段文字，点击文字右上角的 × 可以删除。`
      : '添加后可在预览画面中拖动文字。';
  }

  function addSticker(label, image) {
    const node = make('div', 'sticker', image ? undefined : label);
    if (image) node.appendChild(image);
    node.setAttribute('aria-label', '移动贴纸：' + label);
    const spot = STICKER_SPOTS[state.stickers.length % STICKER_SPOTS.length];
    node.style.left = `${spot[0]}%`;
    node.style.top = `${spot[1]}%`;
    const remove = make('button', 'ov-remove', '×');
    remove.type = 'button';
    remove.setAttribute('aria-label', '删除贴纸');
    remove.addEventListener('click', event => {
      event.stopPropagation();
      node.remove();
      if (image) URL.revokeObjectURL(image.src);
      removeTimedTrack(state.stickers.find(item => item.node === node));
      state.stickers = state.stickers.filter(item => item.node !== node);
      renderTimedTracks(state.data);
      toast('已移除贴纸');
    });
    node.appendChild(remove);
    enableOverlayDrag(node, el.stickerLayer);
    el.stickerLayer.appendChild(node);
    const item = { node, name: label, ...overlayRange() };
    state.stickers.push(item);
    addTimedTrack(item, 'sticker', label);
  }

  async function importSticker(file) {
    const image = make('img', 'sticker-image');
    image.alt = '';
    image.draggable = false;
    image.src = URL.createObjectURL(file);
    try {
      await image.decode();
    } catch {
      URL.revokeObjectURL(image.src);
      toast('无法读取这张图片');
      return;
    }
    if (!state.data?.duration) {
      URL.revokeObjectURL(image.src);
      toast('请先添加视频');
      return;
    }
    addSticker(file.name, image);
    closeSheet();
  }

  function applyEffect(id) {
    const effect = EFFECTS.find(item => item.id === id) || EFFECTS[0];
    if (effect.id !== 'original' && !state.data?.duration) { toast('请先添加视频'); return; }
    removeTimedTrack(state.effectItem);
    state.effectItem = null;
    state.effect = effect.id;
    el.preview.style.filter = '';
    if (effect.id !== 'original') {
      const item = { name: effect.name, filter: effect.filter, ...overlayRange() };
      state.effectItem = item;
      addTimedTrack(item, 'effect', effect.name);
    } else {
      renderTimedTracks(state.data);
    }
  }
  function addPip(file) {
    if (!state.data?.duration) { toast('请先添加视频'); return; }
    removePip(false);
    const url = URL.createObjectURL(file);
    const wrap = make('div', 'pip-wrap');
    wrap.style.left = '79%';
    wrap.style.top = '76%';
    wrap.style.width = '34%';
    enableOverlayDrag(wrap, el.pipSlot);
    const video = make('video');
    video.src = url;
    video.muted = true;

    video.playsInline = true;
    video.preload = 'auto';
    video.setAttribute('playsinline', '');
    wrap.appendChild(video);
    const remove = make('button', 'pip-remove', '×');
    remove.type = 'button';
    remove.setAttribute('aria-label', '移除画中画');
    remove.addEventListener('click', event => {
      event.stopPropagation();
      removePip();
    });
    wrap.appendChild(remove);
    el.pipSlot.appendChild(wrap);
    const start = overlayRange().start;
    const item = { wrap, node: wrap, el: video, url, name: file.name, anchor: start, start };
    state.pip = item;
    video.addEventListener('loadedmetadata', () => {
      if (state.pip !== item || !Number.isFinite(video.duration) || video.duration <= 0) return;
      item.limit = start + video.duration;
      item.end = Math.min(item.limit, state.data.duration);
      addTimedTrack(item, 'pip', item.name);
      syncBackgroundMedia(state.data);
      refreshSheet();
      toast('已添加画中画');
    }, { once: true });
    video.addEventListener('error', () => {
      if (state.pip !== item) return;
      removePip(false);
      toast('无法读取画中画视频');
    }, { once: true });
    wrap.hidden = true;
  }

  function removePip(showToast = true) {
    if (!state.pip) return;
    state.pip.el.pause();
    state.pip.wrap.remove();
    URL.revokeObjectURL(state.pip.url);
    removeTimedTrack(state.pip);
    state.pip = null;
    renderTimedTracks(state.data);
    if (showToast) toast('已移除画中画');
    refreshSheet();
  }

  function removePipFromUI() {
    removePip();
  }

  function addAudio(file, source) {
    if (!state.data?.duration) { toast('请先添加视频'); return; }
    removeAudio(false);
    const url = file ? URL.createObjectURL(file) : null;
    const audio = new Audio(url || source.clip.src);
    audio.preload = 'auto';
    audio.volume = 0.9;
    const start = overlayRange().start;
    const audioStart = source?.projectStart ?? start;
    const offset = source?.clip.start || 0;
    const name = source ? '视频原声 · 片段 ' + (source.index + 1) : file.name;
    const item = { name, url, el: audio, anchor: audioStart - offset,
      start: audioStart, minStart: audioStart, duration: 0, volume: 0.9, fade: 0 };
    state.audio = item;
    audio.addEventListener('loadedmetadata', () => {
      if (state.audio !== item || !Number.isFinite(audio.duration) || audio.duration <= 0) return;
      item.duration = audio.duration;
      item.limit = item.anchor + Math.min(audio.duration, source?.clip.end ?? audio.duration);
      item.end = Math.min(item.limit, state.data.duration);
      addTimedTrack(item, 'audio', item.name);
      toast('已添加音频');
      syncBackgroundMedia(state.data);
    }, { once: true });
    audio.addEventListener('error', () => {
      if (state.audio !== item) return;
      removeAudio(false);
      refreshSheet();
      toast('无法读取这个音频文件');
    }, { once: true });
    toast('正在读取音频…');
    if (state.data) renderTimedTracks(state.data);
    refreshSheet();
  }

  function removeAudio(showToast = true) {
    if (!state.audio) return;
    state.audio.el.pause();
    if (state.audio.url) URL.revokeObjectURL(state.audio.url);
    removeTimedTrack(state.audio);
    state.audio = null;
    if (state.data) renderTimedTracks(state.data);
    if (showToast) toast('已移除音频');
  }

  function removeAudioFromUI() {
    removeAudio();
    refreshSheet();
  }

  /* ------------------------------------------------------------------ */
  /* 导入视频                                                           */
  /* ------------------------------------------------------------------ */

  async function importVideo(file) {
    if (!file) return;
    if (state.importing) {
      toast('正在读取上一个视频，请稍候');
      return;
    }
    state.importing = true;
    toast('正在读取视频…', 5000);
    try {
      await editor.insertVideo(file);
      toast(`已添加片段「${file.name}」`, 2400);
      refreshSheet();
    } catch (error) {
      toast(error && error.message ? error.message : '无法读取这个视频');
    } finally {
      state.importing = false;
    }
  }

  /* ------------------------------------------------------------------ */
  /* 时间轴手势                                                         */
  /* ------------------------------------------------------------------ */

  function timeAtScreenX(clientX) {
    if (!state.data) return 0;
    return clamp(
      state.data.currentTime + (clientX - state.playheadX) / state.pps,
      0,
      state.data.duration
    );
  }

  function beginPan(event) {
    if (!state.data || state.pan || !event.isPrimary || event.button !== 0) return;
    if (event.target.closest('button:not(.clip):not(.timed-label)')) return;
    const clip = event.target.closest('.clip');
    const track = event.target.closest('.timed-clip');
    const item = track && [state.audio, state.pip, state.effectItem, ...state.texts, ...state.stickers]
      .find(entry => entry?.track === track);
    const pan = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      startTime: state.data.currentTime,
      item, clip,
      lastSeek: 0
    };
    state.pan = pan;
    el.timeline.classList.add('is-panning');
    el.timeline.setPointerCapture(event.pointerId);
    if (state.data.playing) editor.togglePlayback();
    if (clip || item) {
      pan.timer = setTimeout(() => {
        pan.dragging = true;
        pan.node = clip || track;
        pan.node.classList.add('is-lifted');
        if (item) {
          state.selectedTimed = item;
          pan.itemStart = item.start;
          pan.itemEnd = item.end;
          pan.anchor = item.anchor;
          pan.limit = item.limit;
          pan.minStart = item.minStart;
          renderTimedTracks(state.data);
        } else {
          pan.clipId = Number(clip.dataset.clipId);
          state.selectedTimed = null;
          renderTimedTracks(state.data);
        }
        navigator.vibrate?.(25);
      }, 420);
    }
    event.preventDefault();
  }

  function dragTimelineItem(pan, delta) {
    if (pan.item) {
      const item = pan.item;
      const length = pan.itemEnd - pan.itemStart;
      const start = clamp(pan.itemStart + delta / state.pps, 0, Math.max(0, state.data.duration - length));
      const offset = start - pan.itemStart;
      item.start = start;
      item.end = start + length;
      if (pan.anchor !== undefined) {
        item.anchor = pan.anchor + offset;
        item.limit = pan.limit + offset;
        if (pan.minStart !== undefined) item.minStart = pan.minStart + offset;
      }
      renderTimedTracks(state.data);
      syncBackgroundMedia(state.data);
      return;
    }

    pan.node.style.translate = delta + 'px';
    const center = pan.node.getBoundingClientRect();
    const time = timeAtScreenX(center.left + center.width / 2);
    const original = state.data.clips.findIndex(clip => clip.id === pan.clipId);
    let destination = original;
    let start = 0;
    for (const [index, clip] of state.data.clips.entries()) {
      const length = clip.end - clip.start;
      const midpoint = start + length / 2;
      if (index < original && time < midpoint) destination = Math.min(destination, index);
      if (index > original && time >= midpoint) destination = index;
      start += length;
    }
    pan.destination = destination;
    pan.target?.classList.remove('is-drop-target');
    pan.target = el.clips.children[destination];
    if (pan.target !== pan.node) pan.target?.classList.add('is-drop-target');
  }

  function movePan(event) {
    const pan = state.pan;
    if (!pan || event.pointerId !== pan.pointerId) return;
    const delta = event.clientX - pan.startX;
    if (pan.dragging) {
      dragTimelineItem(pan, delta);
      return;
    }
    if (!pan.moved && Math.hypot(delta, event.clientY - pan.startY) > 7) {
      clearTimeout(pan.timer);
      pan.moved = true;
    }
    if (!pan.moved) return;
    const now = performance.now();
    if (now - pan.lastSeek < 30) return;
    pan.lastSeek = now;
    editor.seek(clamp(pan.startTime - delta / state.pps, 0, state.data.duration));
    event.preventDefault();
  }

  function endPan(event) {
    const pan = state.pan;
    if (!pan || event.pointerId !== pan.pointerId) return;
    state.pan = null;
    clearTimeout(pan.timer);
    el.timeline.classList.remove('is-panning');
    const committed = event.type === 'pointerup';
    if (pan.dragging) {
      if (committed && (pan.item || pan.destination !== undefined)) {
        dragTimelineItem(pan, event.clientX - pan.startX);
      } else if (pan.item) {
        Object.assign(pan.item, { start: pan.itemStart, end: pan.itemEnd, anchor: pan.anchor, limit: pan.limit, minStart: pan.minStart });
        renderTimedTracks(state.data);
        syncBackgroundMedia(state.data);
      }
      pan.node.classList.remove('is-lifted');
      pan.node.style.translate = '';
      pan.target?.classList.remove('is-drop-target');
      if (committed && pan.clipId !== undefined) {
        if (pan.destination !== undefined) editor.moveClip(pan.clipId, pan.destination);
        editor.selectClip(pan.clipId);
      }
      return;
    }
    if (!committed || !state.data) return;
    if (!pan.moved) {
      if (pan.item) {
        state.selectedTimed = pan.item;
        renderTimedTracks(state.data);
      } else if (pan.clip?.dataset.clipId) {
        state.selectedTimed = null;
        editor.selectClip(Number(pan.clip.dataset.clipId));
      } else {
        editor.seek(timeAtScreenX(event.clientX));
      }
      return;
    }
    editor.seek(clamp(pan.startTime - (event.clientX - pan.startX) / state.pps, 0, state.data.duration));
  }
  function onWheel(event) {
    if (!state.data) return;
    const amount = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
    if (!amount) return;
    event.preventDefault();
    const now = performance.now();
    if (now - state.wheelAt < 40) return;
    state.wheelAt = now;
    editor.seek(clamp(state.data.currentTime + amount / state.pps, 0, state.data.duration));
  }

  /* ------------------------------------------------------------------ */
  /* 启动                                                               */
  /* ------------------------------------------------------------------ */

  function bindTextRotation() {
    const canvas = make('canvas', 'rotation-cursor');
    canvas.setAttribute('aria-hidden', 'true');
    canvas.hidden = true;
    el.frame.appendChild(canvas);
    const ctx = canvas.getContext('2d');
    let drag = null;
    let consumeClick = false;

    function geometry(node, event) {
      const box = node.getBoundingClientRect();
      const x = box.left + box.width / 2;
      const y = box.top + box.height / 2;
      const px = event.clientX - x;
      const py = event.clientY - y;
      return { x, y, radius: Math.hypot(px, py), angle: Math.atan2(py, px) };
    }

    function targetAt(event) {
      const item = state.selectedTimed;
      const node = item?.kind === 'text' && item.node;
      if (!node || node.hidden || event.target.closest('.text-overlay, .sticker, .pip-wrap')) return null;
      return item;
    }

    function hide() {
      canvas.hidden = true;
      el.frame.classList.remove('is-rotating-text');
    }

    function draw(item, event) {
      const { x, y, radius, angle } = geometry(item.node, event);
      const frame = el.frame.getBoundingClientRect();
      if (!ctx || !radius || !frame.width || !frame.height) return;
      const ratio = window.devicePixelRatio || 1;
      const width = Math.round(frame.width * ratio);
      const height = Math.round(frame.height * ratio);
      if (canvas.width !== width) canvas.width = width;
      if (canvas.height !== height) canvas.height = height;
      canvas.hidden = false;
      el.frame.classList.add('is-rotating-text');
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, frame.width, frame.height);
      const cx = x - frame.left;
      const cy = y - frame.top;
      const half = Math.min(0.55, 13 / radius);
      ctx.beginPath();
      ctx.arc(cx, cy, radius, angle - half, angle + half);
      for (const end of [-1, 1]) {
        const a = angle + end * half;
        const px = cx + Math.cos(a) * radius;
        const py = cy + Math.sin(a) * radius;
        const tangent = a + end * Math.PI / 2;
        ctx.moveTo(px - 6 * Math.cos(tangent - 0.6), py - 6 * Math.sin(tangent - 0.6));
        ctx.lineTo(px, py);
        ctx.lineTo(px - 6 * Math.cos(tangent + 0.6), py - 6 * Math.sin(tangent + 0.6));
      }
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.strokeStyle = '#231a30';
      ctx.lineWidth = 4;
      ctx.stroke();
      ctx.strokeStyle = '#fff';
      ctx.lineWidth = 2;
      ctx.stroke();
    }

    el.frame.addEventListener('pointermove', event => {
      if (drag?.id === event.pointerId) {
        const { angle } = geometry(drag.item.node, event);
        const delta = angle - drag.previousAngle;
        drag.previousAngle = angle;
        drag.item.rotation = (drag.item.rotation || 0) + Math.atan2(Math.sin(delta), Math.cos(delta));
        drag.item.node.style.setProperty('--text-rotation', drag.item.rotation + 'rad');
        draw(drag.item, event);
      } else {
        const item = targetAt(event);
        if (item) draw(item, event);
        else hide();
      }
    });
    el.frame.addEventListener('pointerdown', event => {
      consumeClick = false;
      const item = targetAt(event);
      if (!item || !event.isPrimary || event.button !== 0) return;
      event.preventDefault();
      consumeClick = true;
      drag = { item, id: event.pointerId, previousAngle: geometry(item.node, event).angle };
      if (state.data.playing) editor.togglePlayback();
      el.frame.setPointerCapture(event.pointerId);
      draw(item, event);
    });
    el.frame.addEventListener('lostpointercapture', () => { drag = null; hide(); });
    el.frame.addEventListener('pointerleave', () => { if (!drag) hide(); });
    el.frame.addEventListener('click', event => {
      if (!consumeClick) return;
      consumeClick = false;
      event.stopImmediatePropagation();
    }, true);
  }

  function bindToolbarScroll() {
    const toolbar = el.toolbar;
    let gesture = null;
    let suppressClick = false;

    toolbar.addEventListener('pointerdown', event => {
      if (!event.isPrimary || event.button !== 0) return;
      suppressClick = false;
      if (toolbar.scrollWidth <= toolbar.clientWidth) return;
      const press = {
        id: event.pointerId,
        x: event.clientX,
        left: toolbar.scrollLeft,
        active: false
      };
      gesture = press;
      press.timer = setTimeout(() => activate(press), 420);
    });

    function activate(press) {
      clearTimeout(press.timer);
      press.active = true;
      suppressClick = true;
      toolbar.classList.add('is-dragging');
      toolbar.setPointerCapture(press.id);
    }

    toolbar.addEventListener('pointermove', event => {
      if (gesture?.id !== event.pointerId) return;
      const delta = event.clientX - gesture.x;
      if (!gesture.active && Math.abs(delta) >= 7) activate(gesture);
      if (gesture.active) toolbar.scrollLeft = gesture.left - delta;
    });

    function finish(event) {
      if (gesture?.id !== event.pointerId) return;
      if (event.type === 'lostpointercapture' && event.target !== toolbar) return;
      clearTimeout(gesture.timer);
      gesture = null;
      toolbar.classList.remove('is-dragging');
    }

    for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
      toolbar.addEventListener(type, finish);
    }
    toolbar.addEventListener('pointerleave', event => {
      if (!gesture?.active) finish(event);
    });
    toolbar.addEventListener('contextmenu', event => event.preventDefault());
    toolbar.addEventListener('click', event => {
      if (suppressClick && event.detail > 0) {
        suppressClick = false;
        return;
      }
      const button = event.target.closest('.tool');
      if (button) openSheet(button.dataset.tool);
    });
  }

  function bindEvents() {
    bindTextRotation();
    el.projectPosition.addEventListener('input', () => {
      if (!state.data?.duration) return;
      const target = el.projectPosition.valueAsNumber;
      if (state.data.playing) editor.togglePlayback();
      editor.seek(target);
    });
    el.projectPosition.addEventListener('keydown', event => event.stopPropagation());
    el.play.addEventListener('click', togglePlayback);
    el.undo.addEventListener('click', doUndo);
    el.redo.addEventListener('click', doRedo);
    el.fullscreen.addEventListener('click', toggleFullscreen);
    el.previewExit.addEventListener('click', event => {
      event.stopPropagation();
      exitPreviewMode();
    });
    el.mute.addEventListener('click', toggleMute);
    el.close.addEventListener('click', openExitModal);
    el.exportBtn.addEventListener('click', openExportModal);
    el.quality.addEventListener('click', event => {
      event.stopPropagation();
      toggleQualityMenu();
    });
    el.qualityMenu.addEventListener('click', event => {
      const button = event.target.closest('button[data-quality]');
      if (!button) return;
      setQuality(button.dataset.quality);
    });
    document.addEventListener('click', event => {
      if (!el.qualityMenu.hidden && !event.target.closest('#quality-menu, #btn-quality')) {
        closeQualityMenu();
      }
    });

    el.addMedia.addEventListener('click', () => el.fileVideo.click());
    el.audioAdd.addEventListener('click', () => openSheet('audio'));
    el.cover.addEventListener('click', openCoverModal);
    bindToolbarScroll();
    el.sheetDone.addEventListener('click', closeSheet);
    el.sheetScrim.addEventListener('click', closeSheet);
    el.modalScrim.addEventListener('click', () => {
      if (!state.modalBusy) closeModal();
    });
    el.reenter.addEventListener('click', () => window.location.reload());

    el.frame.addEventListener('click', event => {
      if (event.target.closest('.text-overlay, .sticker, .pip-wrap, .ov-remove, .pip-remove')) return;
      togglePlayback();
    });

    el.clips.addEventListener('click', event => {
      const clip = event.target.closest('.clip');
      if (!clip || event.detail) return;
      state.selectedTimed = null;
      editor.selectClip(Number(clip.dataset.clipId));
    });
    el.timeline.addEventListener('pointerdown', beginPan);
    el.timeline.addEventListener('pointermove', movePan);
    for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
      el.timeline.addEventListener(type, endPan);
    }
    el.timeline.addEventListener('wheel', onWheel, { passive: false });
    el.timeline.addEventListener('contextmenu', event => event.preventDefault());

    el.fileVideo.addEventListener('change', () => {
      const file = el.fileVideo.files && el.fileVideo.files[0];
      el.fileVideo.value = '';
      importVideo(file);
    });
    el.fileAudio.addEventListener('change', () => {
      const file = el.fileAudio.files && el.fileAudio.files[0];
      el.fileAudio.value = '';
      if (file) addAudio(file);
    });
    el.fileSticker.addEventListener('change', () => {
      const file = el.fileSticker.files[0];
      el.fileSticker.value = '';
      if (file) importSticker(file);
    });
    el.filePip.addEventListener('change', () => {
      const file = el.filePip.files && el.filePip.files[0];
      el.filePip.value = '';
      if (file) addPip(file);
    });

    document.addEventListener('fullscreenchange', () => {
      if (!document.fullscreenElement && inPreviewMode()) {
        el.app.classList.remove('preview-mode');
        el.previewExit.hidden = true;
      }
      updateFullscreenIcon();
    });
    document.addEventListener('keydown', event => {
      const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement && document.activeElement.tagName);
      if (event.key === 'Escape') {
        if (!el.modalRoot.hidden) closeModal();
        else if (!el.qualityMenu.hidden) closeQualityMenu();
        else if (!el.sheetRoot.hidden) closeSheet();
        else if (inPreviewMode()) exitPreviewMode();
        return;
      }
      if (typing) return;
      if (event.code === 'Space') {
        event.preventDefault();
        togglePlayback();
      } else if (event.key === 'ArrowLeft' && state.data) {
        editor.seek(clamp(state.data.currentTime - 1, 0, state.data.duration));
      } else if (event.key === 'ArrowRight' && state.data) {
        editor.seek(clamp(state.data.currentTime + 1, 0, state.data.duration));
      } else if (event.key.toLowerCase() === 's') {
        doSplit();
      } else if (event.key.toLowerCase() === 'm') {
        toggleMute();
      } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') {
        event.preventDefault();
        if (event.shiftKey) doRedo();
        else doUndo();
      }
    });

    window.addEventListener('resize', () => {
      clearTimeout(state.resizeTimer);
      state.resizeTimer = setTimeout(() => {
        measure();
        state.layoutDirty = true;
        if (state.data) onState(state.data);
        renderTimedTracks(state.data || { clips: [], currentTime: 0 });
        renderEmptyState(state.data);
      }, 120);
    });

    el.preview.addEventListener('loadedmetadata', () => {
      state.videoReady = true;
      renderEmptyState(state.data);
      renderCover(state.data || { clips: [] }, true);
      renderTimedTracks(state.data || { clips: [], currentTime: 0 });
    });
    el.preview.addEventListener('loadeddata', () => {
      state.videoReady = true;
      renderEmptyState(state.data);
    });
  }

  function boot() {
    measure();
    state.bootAt = performance.now();
    el.statusTime.textContent = clockLabel();
    state.clockTimer = setInterval(() => {
      el.statusTime.textContent = clockLabel();
    }, 20000);
    bindEvents();
    updateFullscreenIcon();
    editor.subscribe(onState);
    renderEmptyState(state.data);
    // 首屏抽帧可能稍慢，之后再补一次封面
    setTimeout(() => {
      if (state.data && state.data.clips.length) renderCover(state.data, true);
    }, 700);
  }

  boot();

  // 方便调试与自动化检查
  window.__demo = {
    editor,
    getState: () => state.data,
    getPps: () => state.pps,
    getAudio: () => state.audio && {
      name: state.audio.name,
      paused: state.audio.el.paused,
      time: state.audio.el.currentTime,
      duration: state.audio.duration,
    },
    getTexts: () => state.texts.map(item => item.text),
    getEffect: () => state.effect,
  };
})();
