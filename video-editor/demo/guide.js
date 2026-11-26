(() => {
  const steps = [
    ['#stage', '预览画面', '在这里查看当前画面。拖动时间轴后，预览会跳到对应位置。'],
    ['#btn-play', '播放和暂停', '点一下播放当前作品，再点一下就能暂停。'],
    ['#timeline', '在时间轴上定位', '左右滑动画面轨道，让想剪的位置对准白线。轻点片段可以选中，长按拖动可以排序。'],
    ['#btn-undo', '撤销剪辑', '剪错了可以撤销上一次片段编辑，右侧按钮可重做。'],
    ['[data-tool="material"]', '添加素材', '打开素材工具，可以继续添加本地视频。'],
    ['[data-tool="text"]', '添加文字', '输入文字并选择样式。添加后，可以在预览画面上拖动它。'],
    ['#btn-export', '查看导出流程', '这里可以体验导出界面。当前演示版只模拟导出流程。']
  ];

  const app = document.querySelector('#app');
  const trigger = document.querySelector('#btn-guide');
  const guide = document.querySelector('#guide');
  const spotlight = guide.querySelector('.guide-spotlight');
  const card = guide.querySelector('.guide-card');
  const title = guide.querySelector('#guide-title');
  const description = guide.querySelector('#guide-description');
  const count = guide.querySelector('.guide-count');
  const next = guide.querySelector('#guide-next');
  const skip = guide.querySelector('#guide-skip');
  let index = 0;
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));

  function position() {
    if (guide.hidden) return;
    const target = document.querySelector(steps[index][0]);
    const bounds = target.getBoundingClientRect();
    const viewport = guide.getBoundingClientRect();
    const gap = 14;
    const left = clamp(bounds.left - viewport.left - 5, 1, viewport.width - 2);
    const right = clamp(bounds.right - viewport.left + 5, left + 1, viewport.width - 1);
    const top = clamp(bounds.top - viewport.top - 5, 1, viewport.height - 2);
    const bottom = clamp(bounds.bottom - viewport.top + 5, top + 1, viewport.height - 1);
    Object.assign(spotlight.style, {
      left: left + 'px', top: top + 'px',
      width: (right - left) + 'px', height: (bottom - top) + 'px'
    });

    const center = (left + right) / 2;
    const width = card.offsetWidth;
    const height = card.offsetHeight;
    const x = clamp(center - width / 2, 12, viewport.width - width - 12);
    const below = viewport.height - bottom >= height + gap + 12 ||
      viewport.height - bottom > top;
    const y = clamp(below ? bottom + gap : top - height - gap, 12, viewport.height - height - 12);
    card.dataset.side = below ? 'below' : 'above';
    card.style.left = x + 'px';
    card.style.top = y + 'px';
    card.style.setProperty('--guide-arrow-x', clamp(center - x, 18, width - 18) + 'px');
  }

  function renderStep() {
    const [selector, heading, body] = steps[index];
    count.textContent = (index + 1) + ' / ' + steps.length;
    title.textContent = heading;
    description.textContent = body;
    next.textContent = index === steps.length - 1 ? '完成' : '下一步';
    document.querySelector(selector).scrollIntoView({ block: 'nearest', inline: 'nearest' });
    position();
    title.focus({ preventScroll: true });
  }

  function start() {
    if (!guide.hidden) return;
    const editor = window.__demo?.editor;
    if (window.__demo?.getState()?.playing) editor.togglePlayback();
    index = 0;
    guide.hidden = false;
    app.inert = true;
    renderStep();
  }

  function finish() {
    guide.hidden = true;
    app.inert = false;
    trigger.focus({ preventScroll: true });
  }

  trigger.addEventListener('click', start);
  next.addEventListener('click', () => {
    if (index === steps.length - 1) finish();
    else {
      index += 1;
      renderStep();
    }
  });
  skip.addEventListener('click', finish);
  guide.addEventListener('keydown', event => {
    if (event.key === 'Escape') finish();
    if (event.key !== 'Tab') return;
    event.preventDefault();
    const focused = document.activeElement;
    const target = focused === next ? skip : focused === skip ? next : event.shiftKey ? next : skip;
    target.focus();
  });
  window.addEventListener('resize', position);
  window.addEventListener('scroll', position, true);

  if (document.readyState === 'complete') start();
  else window.addEventListener('load', start, { once: true });
})();

