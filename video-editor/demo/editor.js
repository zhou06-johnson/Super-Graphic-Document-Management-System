(() => {
  function createEditor(video) {
    const listeners = new Set();
    const sampleSource = video.getAttribute('src');
    let source = sampleSource;
    let clips = [];
    let currentTime = 0;
    let selectedClipId = null;
    let nextId = 1;
    let playing = false;
    let pendingTime = null;
    let error = '';
    const undoStack = [];
    const redoStack = [];
    const importedSources = new Set();
    const HISTORY_LIMIT = 60;

    const length = clip => clip.end - clip.start;
    const duration = () => clips.reduce((total, clip) => total + length(clip), 0);
    const startOf = index => clips.slice(0, index).reduce((total, clip) => total + length(clip), 0);

    function clipAt(seconds) {
      let projectStart = 0;
      for (const [index, clip] of clips.entries()) {
        if (seconds < projectStart + length(clip) || index === clips.length - 1) {
          return { clip, index, offset: seconds - projectStart, projectStart };
        }
        projectStart += length(clip);
      }
      return null;
    }

    function capture() {
      return {
        clips: clips.map(clip => ({ ...clip })),
        currentTime,
        selectedClipId
      };
    }

    function record() {
      undoStack.push(capture());
      if (undoStack.length > HISTORY_LIMIT) undoStack.shift();
      redoStack.length = 0;
      releaseUnusedSources();
    }

    function releaseUnusedSources() {
      const retained = new Set();
      for (const clip of clips) retained.add(clip.src);
      for (const entry of [...undoStack, ...redoStack]) {
        for (const clip of entry.clips) retained.add(clip.src);
      }
      for (const src of importedSources) {
        if (retained.has(src)) continue;
        URL.revokeObjectURL(src);
        importedSources.delete(src);
      }
    }

    function applyCapture(entry) {
      clips = entry.clips.map(clip => ({ ...clip }));
      currentTime = Math.max(0, Math.min(entry.currentTime, duration()));
      selectedClipId = clips.some(clip => clip.id === entry.selectedClipId)
        ? entry.selectedClipId
        : (clipAt(currentTime) ? clipAt(currentTime).clip.id : null);
      playing = false;
      pendingTime = null;
      error = '';
      video.pause();
      showPosition();
    }

    function undo() {
      if (!undoStack.length) return false;
      redoStack.push(capture());
      applyCapture(undoStack.pop());
      return true;
    }

    function redo() {
      if (!redoStack.length) return false;
      undoStack.push(capture());
      applyCapture(redoStack.pop());
      return true;
    }

    function snapshot() {
      const position = clipAt(currentTime);
      return {
        clips: clips.map(clip => ({ ...clip })),
        currentTime,
        duration: duration(),
        selectedClipId,
        playing,
        muted: video.muted,
        error,
        canSplit: Boolean(position && position.clip.id === selectedClipId &&
          position.offset > 0.01 && length(position.clip) - position.offset > 0.01),
        canUndo: undoStack.length > 0,
        canRedo: redoStack.length > 0
      };
    }

    function publish() {
      const state = snapshot();
      for (const listener of listeners) listener(state);
    }

    function subscribe(listener) {
      listeners.add(listener);
      listener(snapshot());
      return () => listeners.delete(listener);
    }

    function fail(message) {
      playing = false;
      video.pause();
      error = message;
      publish();
    }

    function resume() {
      if (!playing || pendingTime !== null || video.seeking) return;
      const requestedSource = source;
      video.play().catch(reason => {
        if (playing && source === requestedSource && reason.name !== 'AbortError') {
          fail('无法播放此视频。');
        }
      });
    }

    function applyPendingTime() {
      if (pendingTime === null || video.readyState < 1) return;
      const target = pendingTime;
      pendingTime = null;
      if (Math.abs(video.currentTime - target) > 0.0001) video.currentTime = target;
      resume();
    }

    function showPosition() {
      const position = clipAt(currentTime);
      if (!position) {
        playing = false;
        pendingTime = null;
        source = null;
        video.removeAttribute('src');
        video.load();
        publish();
        return;
      }

      pendingTime = position.clip.start + position.offset;
      if (source !== position.clip.src) {
        source = position.clip.src;
        video.src = source;
      } else {
        applyPendingTime();
      }
      publish();
    }

    function seek(seconds) {
      if (!Number.isFinite(seconds) || !clips.length) return;
      error = '';
      currentTime = Math.max(0, Math.min(seconds, duration()));
      selectedClipId = clipAt(currentTime).clip.id;
      showPosition();
    }

    function selectClip(clipId) {
      const index = clips.findIndex(clip => clip.id === clipId);
      if (index < 0) return;
      if (clipAt(currentTime).clip.id === clipId) {
        selectedClipId = clipId;
        publish();
      } else {
        seek(startOf(index));
      }
    }

    function splitAtPlayhead() {
      if (!snapshot().canSplit) return false;
      const { clip, index, offset } = clipAt(currentTime);
      const cut = clip.start + offset;
      const right = { ...clip, id: nextId++, start: cut };
      record();
      clips.splice(index, 1, { ...clip, end: cut }, right);
      selectedClipId = right.id;
      publish();
      return true;
    }

    function deleteClip(clipId) {
      const index = clips.findIndex(clip => clip.id === clipId);
      if (index < 0) return;
      record();
      const position = clipAt(currentTime);
      const nextTime = position.index === index
        ? startOf(index)
        : currentTime - (position.index > index ? length(clips[index]) : 0);
      clips.splice(index, 1);
      if (clips.length) {
        seek(nextTime);
      } else {
        currentTime = 0;
        selectedClipId = null;
        showPosition();
      }
    }

    function duplicateClip(clipId) {
      const index = clips.findIndex(clip => clip.id === clipId);
      if (index < 0) return false;
      record();
      clips.splice(index + 1, 0, { ...clips[index], id: nextId++ });
      seek(startOf(index + 1));
      return true;
    }

    function moveClip(clipId, toIndex) {
      const fromIndex = clips.findIndex(clip => clip.id === clipId);
      if (fromIndex < 0 || !Number.isInteger(toIndex) || toIndex < 0 ||
          toIndex >= clips.length || fromIndex === toIndex) return;
      record();
      const position = clipAt(currentTime);
      const [clip] = clips.splice(fromIndex, 1);
      clips.splice(toIndex, 0, clip);
      seek(startOf(clips.indexOf(position.clip)) + position.offset);
    }

    async function insertVideo(file) {
      const src = URL.createObjectURL(file);
      const probe = document.createElement('video');
      probe.preload = 'metadata';
      let end;
      try {
        end = await new Promise((resolve, reject) => {
          probe.onloadedmetadata = () => resolve(probe.duration);
          probe.onerror = () => reject(new Error('无法读取此视频，请尝试浏览器支持的格式。'));
          probe.src = src;
        });
        if (!Number.isFinite(end) || end <= 0) throw new Error('无法读取视频时长。');
      } catch (reason) {
        URL.revokeObjectURL(src);
        throw reason;
      } finally {
        probe.removeAttribute('src');
        probe.load();
      }
      const position = clipAt(currentTime);
      const index = position ? position.index + 1 : 0;
      record();
      importedSources.add(src);
      clips.splice(index, 0, { id: nextId++, src, start: 0, end, name: file.name });
      seek(startOf(index));
    }

    function toggleMute() {
      video.muted = !video.muted;
      publish();
    }

    function togglePlayback() {
      if (!clips.length) return;
      playing = !playing;
      if (!playing) {
        video.pause();
      } else if (currentTime >= duration()) {
        seek(0);
      } else {
        resume();
      }
      publish();
    }

    function updatePlayback() {
      if (!playing || pendingTime !== null || video.seeking || video.readyState < 2) return;
      const position = clipAt(currentTime);
      if (!position) return;
      if (video.currentTime >= position.clip.end || video.ended) {
        if (position.index === clips.length - 1) {
          playing = false;
          video.pause();
          seek(duration());
        } else {
          seek(position.projectStart + length(position.clip));
        }
        return;
      }
      currentTime = position.projectStart + Math.max(0, video.currentTime - position.clip.start);
      publish();
    }

    let samplePending = true;
    function loadMetadata() {
      if (samplePending && source === sampleSource) {
        samplePending = false;
        if (Number.isFinite(video.duration) && video.duration > 0) {
          clips.unshift({ id: nextId++, src: source, start: 0, end: video.duration, name: '示例视频' });
          seek(0);
        }
      }
      applyPendingTime();
    }

    video.addEventListener('loadedmetadata', loadMetadata);
    video.addEventListener('seeked', resume);
    video.addEventListener('ended', updatePlayback);
    video.addEventListener('timeupdate', updatePlayback);
    video.addEventListener('error', () => {
      if (source === sampleSource) samplePending = false;
      if (source) fail('无法加载预览视频。');
    });

    function tick() {
      if (!video.paused) updatePlayback();
      requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
    if (video.readyState >= 1) loadMetadata();

    return {
      subscribe, seek, selectClip, splitAtPlayhead, deleteClip, duplicateClip,
      moveClip, insertVideo, togglePlayback, toggleMute, undo, redo
    };
  }

  window.createEditor = createEditor;
})();

