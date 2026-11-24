// ==UserScript==
// @name         YouTube 下载命令生成器（yt-dlp）
// @namespace    ytdlp-command-generator
// @version      1.4.4
// @description  缩略图下载按钮优先拦截点击并打开六种复制命令选项，不跳转视频页面
// @match        https://www.youtube.com/*
// @match        https://m.youtube.com/*
// @match        https://music.youtube.com/*
// @grant        GM_setClipboard
// @grant        GM_getValue
// @grant        GM_setValue
// @run-at       document-start
// @noframes
// @license      MIT
// ==/UserScript==

/*
 * 用法：打开任意 YouTube 视频（含 Shorts），页面会出现「生成下载命令」悬浮按钮。
 *       可拖动按钮到任意位置，松手后自动吸附到左/右边缘；按钮会延时收起，悬停/点击可唤回。
 *       吸边位置会保存在脚本管理器/本地存储中，刷新后尽可能恢复。
 *       每个视频缩略图左上角也会出现 8mm × 8mm 下载按钮，点击后直接打开该视频的六选项复制面板，不跳转视频详情页。
 *       面板有 6 个独立复制按钮：MP4 1080p、MP4 最高画质、MP3，每种格式都分「手机」和「电脑」两个版本：
 *       手机版粘贴到 Termux 运行，电脑版粘贴到 cmd 运行。
 * 保存位置：手机存到 /storage/emulated/0/snaptube，电脑存到 D:/snaptube，
 *       文件夹不存在会自动创建。想换位置，改下面的 SAVE_DIRS。
 * 复制：同时用三种方式写入剪贴板，手机浏览器上也能可靠复制。
 * 依赖：电脑需要 yt-dlp、ffmpeg、Deno；手机 Termux 需要 yt-dlp、ffmpeg，并运行过 termux-setup-storage。
 */

(function () {
  'use strict';

  /* ───────────── 命令配置 ───────────── */

  // 保存位置（文件夹不存在会自动创建）
  const SAVE_DIRS = {
    phone: '/storage/emulated/0/snaptube',
    pc: 'D:/snaptube',
  };

  // 每种格式下的按钮顺序：手机在上，电脑在下
  const DEVICES = [
    { key: 'phone', name: '手机', icon: 'phone' },
    { key: 'pc', name: '电脑', icon: 'desktop' },
  ];

  // 视频文件名带上分辨率，同一个视频下两种画质不会互相覆盖
  const VIDEO_NAME = '%(title)s [%(resolution)s].%(ext)s';
  const AUDIO_NAME = '%(title)s.%(ext)s';

  // 格式顺序：1080p → 最高画质 → MP3
  const PRESETS = [
    {
      kind: 'video',
      name: 'MP4 1080p',
      hint: '优先 H.264 编码，几乎所有设备都能直接播放',
      args: ['-S', q('res:1080,vcodec:h264,acodec:aac'),
        '--merge-output-format', 'mp4', '-o', q(VIDEO_NAME)],
    },
    {
      kind: 'video',
      name: 'MP4 最高画质',
      hint: '原始最高分辨率，可达 4K/8K；多为 VP9/AV1 编码，旧播放器可能打不开',
      args: ['-f', q('bv*+ba[ext=m4a]/bv*+ba/b'),
        '--merge-output-format', 'mp4', '-o', q(VIDEO_NAME)],
    },
    {
      kind: 'audio',
      name: 'MP3 音频',
      hint: '最高音质，自动嵌入封面和标题信息',
      args: ['-x', '--audio-format', 'mp3', '--audio-quality', '0',
        '--embed-thumbnail', '--embed-metadata', '-o', q(AUDIO_NAME)],
    },
  ];

  const HOST_ID = 'ytdlp-cmd-host';
  const STORE_SHOW_CMD = 'showCommands';
  const STORE_FAB_POSITION = 'fabPosition';
  const FAB_PEEK = 44; // 吸边隐藏时露出的可点击宽度（像素）
  const SITE = /^music\./.test(location.hostname) ? 'music'
    : /^m\./.test(location.hostname) ? 'mobile' : 'desktop';

  // 视频卡片缩略图下载按钮：一个视频卡片对应一个按钮。
  const THUMB_BUTTON_CLASS = 'ytdlp-thumb-download';
  const THUMB_HOST_CLASS = 'ytdlp-thumb-host';
  const THUMB_STYLE_ID = 'ytdlp-thumb-download-style';
  const THUMBNAIL_SELECTOR = [
    'a#thumbnail[href]',
    'ytd-thumbnail a[href]',
    'a[href*="/watch?v="]',
    'a[href*="/live/"]',
    'yt-thumbnail-view-model a[href]',
    'a.yt-lockup-view-model__content-image[href]',
    '.yt-lockup-view-model__content-image-container a[href]',
    'a[href*="/shorts/"]',
  ].join(',');

  // 在 document-start 阶段先注册捕获监听，尽量早于 YouTube 的卡片事件处理器。
  // 面板初始化后再绑定实际动作；按钮出现前不会有匹配事件。
  let thumbnailButtonAction = null;

  function getEventPoint(event) {
    // MouseEvent / PointerEvent 使用 clientX/Y；TouchEvent 使用 touches 或 changedTouches。
    if (Number.isFinite(event.clientX) && Number.isFinite(event.clientY)) {
      return { x: event.clientX, y: event.clientY };
    }
    const touches = event.changedTouches && event.changedTouches.length
      ? event.changedTouches
      : event.touches;
    if (touches && touches.length) {
      return { x: touches[0].clientX, y: touches[0].clientY };
    }
    return null;
  }

  function getThumbnailButtonFromEvent(event) {
    const path = typeof event.composedPath === 'function' ? event.composedPath() : [];
    for (const node of path) {
      if (node && node.nodeType === 1 && node.classList && node.classList.contains(THUMB_BUTTON_CLASS)) {
        return node;
      }
    }

    const target = event.target;
    const direct = target && typeof target.closest === 'function'
      ? target.closest('.' + THUMB_BUTTON_CLASS)
      : null;
    if (direct) return direct;

    // 某些 YouTube 卡片会建立自己的层叠上下文：图标看得见，但命中目标仍可能是缩略图链接。
    // 再按点击坐标检查按钮实际矩形，确保点在图标区域时仍按下载按钮处理。
    const point = getEventPoint(event);
    if (!point || !document.querySelectorAll) return null;
    const buttons = document.querySelectorAll('.' + THUMB_BUTTON_CLASS);
    for (let i = buttons.length - 1; i >= 0; i--) {
      const button = buttons[i];
      if (!button || !button.isConnected) continue;
      const rect = button.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0 &&
          point.x >= rect.left && point.x <= rect.right &&
          point.y >= rect.top && point.y <= rect.bottom) {
        return button;
      }
    }
    return null;
  }

  function handleThumbnailButtonEvent(event) {
    const button = getThumbnailButtonFromEvent(event);
    if (!button) return;

    if (event.type === 'click') {
      // 在 window 捕获阶段取消缩略图链接导航，并阻断 YouTube 卡片的点击处理。
      if (event.cancelable) event.preventDefault();
      event.stopPropagation();
      if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
      if (thumbnailButtonAction) thumbnailButtonAction(button);
      return;
    }

    // 不取消 pointer/touch 的默认行为，确保浏览器仍会生成 click；
    // 只阻断 YouTube 后续收到这些事件，避免卡片误判为播放/快捷键操作。
    if ((event.type === 'auxclick' || event.type === 'contextmenu') && event.cancelable) event.preventDefault();
    event.stopPropagation();
    if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
  }

  function installThumbnailButtonGuards() {
    const eventNames = [
      'pointerdown', 'pointerup', 'pointercancel', 'mousedown', 'mouseup',
      'touchstart', 'touchend', 'touchcancel',
      'keydown', 'keypress', 'keyup',
      'click', 'dblclick', 'auxclick', 'contextmenu',
    ];
    for (const eventName of eventNames) {
      window.addEventListener(eventName, handleThumbnailButtonEvent, true);
    }
  }

  installThumbnailButtonGuards();

  /* ───────────── 命令拼装 ───────────── */

  function q(s) { return '"' + s + '"'; }

  function canonicalUrl(id) { return 'https://www.youtube.com/watch?v=' + id; }

  // 从当前地址取视频 ID；生成的链接不带 list/t 参数，避免 yt-dlp 把整个播放列表都下载下来
  function getVideoId() {
    let u;
    try { u = new URL(location.href); } catch (_) { return null; }
    let id = null;
    if (u.pathname === '/watch') {
      id = u.searchParams.get('v');
    } else {
      const m = u.pathname.match(/^\/(?:shorts|live|embed|v)\/([\w-]{11})(?:\/|$)/);
      if (m) id = m[1];
    }
    return id && /^[\w-]{11}$/.test(id) ? id : null;
  }

  // 从视频卡片链接提取 ID；不依赖卡片标题文本，兼容 watch、Shorts 和直播链接。
  function getVideoIdFromHref(href) {
    let u;
    try { u = new URL(href, location.href); } catch (_) { return null; }
    let id = null;
    if (u.pathname === '/watch') {
      id = u.searchParams.get('v');
    } else {
      const m = u.pathname.match(/^\/(?:shorts|live|embed|v)\/([\w-]{11})(?:\/|$)/);
      if (m) id = m[1];
    }
    return id && /^[\w-]{11}$/.test(id) ? id : null;
  }

  // 过滤掉标题、频道头像等普通链接，只给真正的视频缩略图添加按钮。
  function isThumbnailAnchor(anchor) {
    if (!anchor || anchor.tagName !== 'A') return false;
    if (anchor.id === 'thumbnail') return true;
    if (anchor.matches('a.yt-lockup-view-model__content-image')) return true;
    if (anchor.closest('ytd-thumbnail, yt-thumbnail-view-model, .yt-lockup-view-model__content-image-container')) return true;
    const card = anchor.closest([
      'ytd-rich-item-renderer', 'ytd-video-renderer', 'ytd-grid-video-renderer',
      'ytd-compact-video-renderer', 'ytd-playlist-video-renderer',
      'ytd-playlist-panel-video-renderer', 'ytd-reel-item-renderer', 'yt-lockup-view-model',
    ].join(','));
    return !!card && !!anchor.querySelector('img, yt-image, yt-img-shadow');
  }

  // 按钮必须放在视频链接 <a> 外面，绝不退回到 anchor 本身。
  // 新版 YouTube 卡片结构不固定，因此依次尝试标准缩略图容器、父容器和祖父容器。
  function getThumbnailHost(anchor) {
    const card = anchor.closest([
      'ytd-rich-item-renderer', 'ytd-video-renderer', 'ytd-grid-video-renderer',
      'ytd-compact-video-renderer', 'ytd-playlist-video-renderer',
      'ytd-playlist-panel-video-renderer', 'ytd-reel-item-renderer', 'yt-lockup-view-model',
    ].join(','));
    const knownHost = anchor.closest('ytd-thumbnail, yt-thumbnail-view-model, .yt-lockup-view-model__content-image-container');
    // 如果缩略图被 YouTube 放进外层链接，按钮放到该链接的父级，避免把 button 嵌套进 a。
    const outerInteractive = anchor.parentElement && anchor.parentElement.closest('a, button');
    const candidates = [
      knownHost,
      anchor.parentElement,
      anchor.parentElement && anchor.parentElement.parentElement,
      card,
      outerInteractive && outerInteractive.parentElement,
    ];
    for (const candidate of candidates) {
      if (!candidate || candidate === document.body || candidate === document.documentElement) continue;
      if (candidate.tagName === 'A' || candidate.tagName === 'BUTTON') continue;
      if (typeof candidate.contains !== 'function' || !candidate.contains(anchor)) continue;
      // 容器本身或其祖先仍是链接/按钮时，也不能把交互按钮插进去。
      if (candidate.closest('a, button')) continue;
      const rect = candidate.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) return candidate;
    }
    return null;
  }

  // 清理保存目录：去掉外层引号；去掉末尾斜杠（Windows 下 \" 会把引号转义掉，导致命令出错）
  function normalizeDir(raw) {
    let p = String(raw || '').trim().replace(/^["']+|["']+$/g, '').replace(/"/g, '').trim();
    if (!p) return '';
    p = p.replace(/[\\/]+$/, '');
    if (!p) return '/';
    if (/^[A-Za-z]:$/.test(p)) return p + '/';
    return p;
  }

  // -P 指定保存文件夹，复制时和命令一起复制出来
  function buildTokens(preset, id, dir) {
    return ['yt-dlp'].concat(preset.args, ['-P', q(dir), q(canonicalUrl(id))]);
  }

  function tokenClass(tok, i, all) {
    if (i === 0) return 'tk-cmd';
    if (i === all.length - 1) return 'tk-url';
    if (tok[0] === '"') return 'tk-str';
    if (tok[0] === '-') return 'tk-flag';
    return 'tk-val';
  }

  /* ───────────── 存储 ───────────── */

  const store = {
    get(key, fallback) {
      try { if (typeof GM_getValue === 'function') return GM_getValue(key, fallback); } catch (_) { /* 用下面的备选 */ }
      try {
        const v = localStorage.getItem('ytdlp-cmd:' + key);
        return v === null ? fallback : v;
      } catch (_) { return fallback; }
    },
    set(key, value) {
      try { if (typeof GM_setValue === 'function') { GM_setValue(key, value); return; } } catch (_) { /* 用下面的备选 */ }
      try { localStorage.setItem('ytdlp-cmd:' + key, value); } catch (_) { /* 忽略 */ }
    },
  };

  /* ───────────── 剪贴板：强制写入 ───────────── */

  // 方式一：选中隐藏的文本框再执行「复制」。必须在点击的同一瞬间同步执行；
  // 手机浏览器（包括 Via、X 浏览器这类自带脚本功能的浏览器）基本都支持这种方式。
  function execCopy(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', ''); // 只读，手机上不会弹出键盘
    ta.setAttribute('aria-hidden', 'true');
    ta.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;margin:0;padding:0;border:0;opacity:0;pointer-events:none;';
    // 复制时直接指定剪贴板内容，防止网页自己的复制处理改动内容
    ta.addEventListener('copy', (e) => {
      try {
        if (e.clipboardData) {
          e.clipboardData.setData('text/plain', text);
          e.preventDefault();
        }
      } catch (_) { /* 忽略 */ }
      e.stopPropagation();
    });
    (document.body || document.documentElement).appendChild(ta);
    let ok = false;
    try {
      ta.focus({ preventScroll: true });
      ta.select();
      ta.setSelectionRange(0, text.length);
      ok = document.execCommand('copy');
    } catch (_) {
      ok = false;
    }
    ta.remove();
    try { window.getSelection().removeAllRanges(); } catch (_) { /* 忽略 */ }
    return !!ok;
  }

  // 三种方式全部执行一遍（写入的是同一段内容），任何一种成功就算复制成功
  function copyText(text) {
    const execOk = execCopy(text);

    let gmOk = false; // 方式二：脚本管理器的剪贴板接口
    if (typeof GM_setClipboard === 'function') {
      try { GM_setClipboard(text, 'text'); gmOk = true; } catch (_) { /* 忽略 */ }
    }

    let apiDone = Promise.resolve(false); // 方式三：浏览器标准剪贴板接口
    try {
      if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
        apiDone = navigator.clipboard.writeText(text).then(() => true, () => false);
      }
    } catch (_) { /* 忽略 */ }

    if (execOk || gmOk) return Promise.resolve(true);
    // 前两种都不行时等标准接口的结果，最多等 1.5 秒，防止个别浏览器一直不返回
    return Promise.race([apiDone, new Promise((resolve) => setTimeout(() => resolve(false), 1500))]);
  }

  /* ───────────── 视频标题（仅用于显示，命令里由 yt-dlp 自己取标题） ───────────── */

  const titleCache = new Map();

  function pageTitle() {
    if (SITE === 'music') {
      const el = document.querySelector('ytmusic-player-bar .title');
      if (el && el.textContent.trim()) return el.textContent.trim();
    }
    const t = document.title
      .replace(/^\(\d+\+?\)\s*/, '')
      .replace(/\s+-\s+YouTube(?:\s+Music)?\s*$/i, '')
      .trim();
    return /^YouTube(?: Music)?$/i.test(t) ? '' : t;
  }

  function fetchTitle(id) {
    if (titleCache.has(id)) return titleCache.get(id);
    let p;
    try {
      p = fetch('/oembed?format=json&url=' + encodeURIComponent(canonicalUrl(id)), { credentials: 'omit' })
        .then((r) => (r.ok ? r.json() : null))
        .then((d) => (d && typeof d.title === 'string' ? d.title.trim() : ''));
    } catch (_) {
      p = Promise.resolve('');
    }
    p = p.catch(() => '');
    titleCache.set(id, p);
    return p;
  }

  /* ───────────── DOM 小工具（不用 innerHTML，YouTube 开了 Trusted Types） ───────────── */

  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    if (props) {
      for (const key of Object.keys(props)) {
        const val = props[key];
        if (val == null) continue;
        if (key === 'class') el.className = val;
        else if (key === 'text') el.textContent = val;
        else el.setAttribute(key, String(val));
      }
    }
    for (const child of children.flat(Infinity)) {
      if (child != null) el.append(child);
    }
    return el;
  }

  const SVG_NS = 'http://www.w3.org/2000/svg';
  const ICONS = {
    download: [['path', { d: 'M12 4v10.5' }], ['path', { d: 'M7.5 10.5 12 15l4.5-4.5' }], ['path', { d: 'M5 19.5h14' }]],
    copy: [
      ['rect', { x: 8.5, y: 8.5, width: 11, height: 11, rx: 2.5 }],
      ['path', { d: 'M15.5 8.5V6A1.5 1.5 0 0 0 14 4.5H6A1.5 1.5 0 0 0 4.5 6v8A1.5 1.5 0 0 0 6 15.5h2.5' }],
    ],
    check: [['path', { d: 'm5 12.5 4.5 4.5L19 7.5' }]],
    close: [['path', { d: 'm6.5 6.5 11 11' }], ['path', { d: 'm17.5 6.5-11 11' }]],
    audio: [['path', { d: 'M9 17.5V6l10-2v11.5' }], ['circle', { cx: 6.5, cy: 17.5, r: 2.5 }], ['circle', { cx: 16.5, cy: 15.5, r: 2.5 }]],
    video: [['rect', { x: 3, y: 5.5, width: 18, height: 13, rx: 3 }], ['path', { d: 'M10.5 9.5v5l4-2.5z', fill: 'currentColor' }]],
    phone: [['rect', { x: 7, y: 2.5, width: 10, height: 19, rx: 2.5 }], ['path', { d: 'M11 18.5h2' }]],
    desktop: [['rect', { x: 3, y: 4, width: 18, height: 12.5, rx: 2 }], ['path', { d: 'M12 16.5V20' }], ['path', { d: 'M8.5 20h7' }]],
  };

  function icon(name, size) {
    const svg = document.createElementNS(SVG_NS, 'svg');
    const attrs = {
      viewBox: '0 0 24 24', width: size, height: size, fill: 'none', stroke: 'currentColor',
      'stroke-width': 1.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
      'aria-hidden': 'true', focusable: 'false',
    };
    for (const k of Object.keys(attrs)) svg.setAttribute(k, String(attrs[k]));
    for (const [tag, a] of ICONS[name]) {
      const el = document.createElementNS(SVG_NS, tag);
      for (const k of Object.keys(a)) el.setAttribute(k, String(a[k]));
      svg.appendChild(el);
    }
    return svg;
  }

  function setIcon(slot, name, size) {
    slot.textContent = '';
    slot.appendChild(icon(name, size));
  }

  function selectNode(node) {
    try {
      const range = document.createRange();
      range.selectNodeContents(node);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    } catch (_) { /* 忽略 */ }
  }

  /* ───────────── 样式（放在 Shadow DOM 里，和 YouTube 的样式互不影响） ───────────── */

  const CSS = `
:host { all: initial; }
*, *::before, *::after { box-sizing: border-box; }

.root {
  --surface: #ffffff;
  --surface-2: #f2f2f2;
  --ink: #0f0f0f;
  --ink-2: #606060;
  --ink-3: #909090;
  --line: rgba(0, 0, 0, 0.1);
  --line-2: rgba(0, 0, 0, 0.16);
  --shadow: 0 18px 50px rgba(0, 0, 0, 0.16), 0 2px 8px rgba(0, 0, 0, 0.08);
  --audio: #b26a00;
  --video: #2a5bd7;
  --danger: #d93025;
  --term: #1b1e24;
  --term-ink: #e7e9ee;
  --select: rgba(61, 126, 255, 0.45);
  --focus: #3d7eff;
  --ui: Roboto, system-ui, -apple-system, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans SC", sans-serif;
  --mono: ui-monospace, "Cascadia Mono", "SF Mono", Menlo, Consolas, "Roboto Mono", "Liberation Mono", monospace;
  font: 400 13px/1.5 var(--ui);
  color: var(--ink);
  -webkit-font-smoothing: antialiased;
}
.root[data-theme="dark"] {
  --surface: #212121;
  --surface-2: #303030;
  --ink: #f1f1f1;
  --ink-2: #aaaaaa;
  --ink-3: #7c7c7c;
  --line: rgba(255, 255, 255, 0.1);
  --line-2: rgba(255, 255, 255, 0.18);
  --shadow: 0 18px 50px rgba(0, 0, 0, 0.6), 0 2px 8px rgba(0, 0, 0, 0.4);
  --audio: #f0b44c;
  --video: #8aaeff;
  --danger: #f28b82;
  --term: #141619;
}

button { font: inherit; }
button:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }

/* 悬浮按钮：支持鼠标/触屏拖动，吸边后只露出可点击的图标区域 */
.fab {
  position: fixed;
  left: auto;
  top: auto;
  right: 24px;
  bottom: 24px;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  height: 40px;
  padding: 0 16px 0 12px;
  border: 1px solid var(--line-2);
  border-radius: 20px;
  background: var(--surface);
  color: var(--ink);
  font: 500 14px/1 var(--ui);
  box-shadow: var(--shadow);
  cursor: grab;
  touch-action: none;
  user-select: none;
  -webkit-user-select: none;
  -webkit-tap-highlight-color: transparent;
  transition: left 0.22s ease, top 0.22s ease, right 0.22s ease, bottom 0.22s ease,
    background-color 0.15s ease, transform 0.15s ease, opacity 0.18s ease;
}
.fab svg { flex: none; color: var(--video); }
.fab:hover, .fab[aria-expanded="true"] { background: var(--surface-2); }
.fab:active { transform: scale(0.97); }
.fab.is-dragging, .fab.is-dragging:active { cursor: grabbing; transition: none !important; transform: none; opacity: 1; box-shadow: 0 14px 36px rgba(0, 0, 0, 0.24); }
.fab.is-hidden { opacity: 0.92; }
/* 左侧隐藏时把图标放在可见的右端；右侧隐藏时图标本来就在左端 */
.fab.is-hidden[data-dock="left"] { flex-direction: row-reverse; border-top-left-radius: 0; border-bottom-left-radius: 0; }
.fab.is-hidden[data-dock="right"] { border-top-right-radius: 0; border-bottom-right-radius: 0; }
.fab:focus-visible { outline: 2px solid var(--focus); outline-offset: 3px; }

/* 面板 */
.panel {
  position: fixed;
  right: 24px;
  bottom: 76px;
  width: 420px;
  max-width: calc(100vw - 32px);
  max-height: calc(100vh - 96px);
  max-height: calc(100dvh - 96px);
  overflow-y: auto;
  overscroll-behavior: contain;
  scrollbar-width: thin;
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 14px;
  box-shadow: var(--shadow);
  transform-origin: 100% 100%;
  opacity: 0;
  transform: translateY(8px) scale(0.98);
  visibility: hidden;
  transition: opacity 0.16s ease, transform 0.16s ease, visibility 0s linear 0.16s;
}
.panel.open {
  opacity: 1;
  transform: none;
  visibility: visible;
  transition: opacity 0.16s ease, transform 0.16s ease;
}

.head {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: 14px 10px 12px 16px;
  border-bottom: 1px solid var(--line);
}
.head-text { flex: 1; min-width: 0; }
.head h2 { margin: 0 0 6px; font: 600 15px/1.3 "YouTube Sans", var(--ui); color: var(--ink); }
.v-title {
  font-size: 13px;
  line-height: 1.45;
  color: var(--ink);
  overflow: hidden;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow-wrap: anywhere;
}
.v-url { margin-top: 2px; font-size: 12px; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.icon-btn {
  flex: none;
  display: grid;
  place-items: center;
  width: 32px;
  height: 32px;
  margin-top: -4px;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: transparent;
  color: var(--ink-2);
  cursor: pointer;
}
.icon-btn:hover { background: var(--surface-2); color: var(--ink); }

/* 每种格式一组：标题，下面是手机、电脑两个复制按钮 */
.group { padding: 14px 16px 16px; }
.group + .group { border-top: 1px solid var(--line); }
.group-head {
  display: grid;
  grid-template-columns: 20px minmax(0, 1fr);
  column-gap: 10px;
  align-items: start;
  margin-bottom: 10px;
}
.kind { display: grid; place-items: center; height: 20px; }
.group[data-kind="audio"] .kind { color: var(--audio); }
.group[data-kind="video"] .kind { color: var(--video); }
.name { display: block; font: 600 14px/20px var(--ui); color: var(--ink); }
.hint { display: block; margin-top: 2px; font-size: 12px; line-height: 1.45; color: var(--ink-2); }
.targets { display: grid; gap: 8px; }

/* 整行就是一个复制按钮，手机上好点 */
.copy {
  position: relative;
  display: grid;
  grid-template-columns: 20px minmax(0, 1fr) auto;
  column-gap: 10px;
  align-items: center;
  width: 100%;
  min-height: 52px;
  margin: 0;
  padding: 8px 14px 8px 12px;
  border: 1px solid var(--line-2);
  border-radius: 10px;
  background: var(--surface);
  color: var(--ink);
  text-align: left;
  overflow: hidden;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: background-color 0.15s ease, border-color 0.15s ease, color 0.15s ease;
}
.copy:hover { background: var(--surface-2); }
.dev-icon { display: grid; place-items: center; color: var(--ink-2); }
.dev-text { min-width: 0; }
.dev-name { display: block; font: 600 14px/1.3 var(--ui); }
.dev-path {
  display: block;
  margin-top: 2px;
  font: 11.5px/1.35 var(--mono);
  color: var(--ink-2);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.copy-state { display: inline-flex; align-items: center; gap: 6px; font: 500 13px/1 var(--ui); white-space: nowrap; }
.state-icon { display: grid; }
.copy.is-done { background: var(--ink); border-color: var(--ink); color: var(--surface); }
.copy.is-done .dev-icon, .copy.is-done .dev-path { color: inherit; opacity: 0.75; }
.target.is-fail .copy { border-color: var(--danger); }
.target.is-fail .copy-state { color: var(--danger); }
/* 复制成功时，一道「选中」高光扫过按钮 */
.copy::after {
  content: "";
  position: absolute;
  inset: 0;
  background: var(--select);
  transform: scaleX(0);
  transform-origin: 0 50%;
  opacity: 0;
  pointer-events: none;
}
.copy.is-done::after { animation: sweep 0.6s cubic-bezier(0.3, 0.7, 0.2, 1) both; }
@keyframes sweep {
  0% { transform: scaleX(0); opacity: 1; }
  55% { transform: scaleX(1); opacity: 1; }
  100% { transform: scaleX(1); opacity: 0; }
}

.fail-hint { display: none; margin: 6px 2px 0; font-size: 12px; line-height: 1.45; color: var(--danger); }
.target.is-fail .fail-hint { display: block; }

/* 完整命令：默认收起，点底部「查看命令」展开；复制失败时自动展开 */
.term {
  display: none;
  margin-top: 6px;
  padding: 10px 12px 11px;
  border-radius: 8px;
  background: var(--term);
  color: var(--term-ink);
  font: 12px/1.65 var(--mono);
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  user-select: text;
  -webkit-user-select: text;
  cursor: text;
}
.root.show-cmd .term, .target.is-fail .term { display: block; }
.term::before { content: "$ "; color: #6b7280; }
/* 只在参数之间换行，不把 --merge-output-format 这种参数从中间断开 */
.term span { display: inline-block; max-width: 100%; overflow-wrap: anywhere; }
.tk-cmd { color: #ffffff; font-weight: 600; }
.tk-flag { color: #93a4bd; }
.tk-str { color: #f2c97d; }
.tk-url { color: #8b93a1; }

/* 底部 */
.foot {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 16px 14px;
  border-top: 1px solid var(--line);
}
.note { flex: 1; min-width: 0; margin: 0; font-size: 12px; line-height: 1.5; color: var(--ink-2); }
.pill {
  flex: none;
  height: 30px;
  padding: 0 12px;
  border: 1px solid var(--line-2);
  border-radius: 15px;
  background: var(--surface);
  color: var(--ink);
  font: 500 12.5px/1 var(--ui);
  cursor: pointer;
}
.pill:hover, .pill[aria-pressed="true"] { background: var(--surface-2); }

/* 窄屏 / YouTube Music 底部播放条 / 手机版 */
@media (max-width: 560px) {
  .fab { right: 12px; bottom: 12px; }
  .panel {
    left: 8px;
    right: 8px;
    bottom: 62px;
    width: auto;
    max-width: none;
    max-height: calc(100vh - 76px);
    max-height: calc(100dvh - 76px);
  }
}
.root[data-site="music"] .fab { bottom: 96px; }
.root[data-site="music"] .panel { bottom: 148px; max-height: calc(100vh - 168px); max-height: calc(100dvh - 168px); }
.root[data-site="mobile"] .fab { bottom: 72px; }
.root[data-site="mobile"] .panel { bottom: 124px; max-height: calc(100vh - 144px); max-height: calc(100dvh - 144px); }

@media (prefers-reduced-motion: reduce) {
  .fab, .panel, .panel.open, .copy { transition: none; }
  .copy.is-done::after { animation: none; }
}
`;

  /* ───────────── 界面 ───────────── */

  function init() {
    if (document.getElementById(HOST_ID)) return; // 防止重复注入

    const host = document.createElement('div');
    host.id = HOST_ID;
    host.style.cssText = 'position:fixed;top:0;left:0;width:0;height:0;z-index:2147483000;display:none;';
    const shadow = host.attachShadow({ mode: 'open' });

    const style = document.createElement('style');
    style.textContent = CSS;

    const root = h('div', { class: 'root', 'data-site': SITE, 'data-theme': 'light' });

    const fab = h('button', {
      class: 'fab', type: 'button',
      'aria-haspopup': 'dialog', 'aria-expanded': 'false', 'aria-controls': 'ytdlp-panel',
      'aria-label': '生成下载命令，可拖动到屏幕边缘',
      title: '点击打开下载命令；拖动可移动位置，松手后自动吸边',
    }, icon('download', 18), h('span', { class: 'fab-label', text: '生成下载命令' }));

    const titleEl = h('div', { class: 'v-title' });
    const urlEl = h('div', { class: 'v-url' });
    const closeBtn = h('button', { class: 'icon-btn', type: 'button', 'aria-label': '关闭', title: '关闭（Esc）' }, icon('close', 18));

    // 3 种格式 × 2 个设备 = 6 个复制按钮
    const groups = PRESETS.map((preset) => {
      const targets = DEVICES.map((dev) => {
        const stateIcon = h('span', { class: 'state-icon' }, icon('copy', 15));
        const stateText = h('span', { text: '复制' });
        const btn = h('button', {
          class: 'copy', type: 'button',
          'aria-label': '复制' + preset.name + '（' + dev.name + '）下载命令',
        },
          h('span', { class: 'dev-icon' }, icon(dev.icon, 18)),
          h('span', { class: 'dev-text' },
            h('span', { class: 'dev-name', text: dev.name }),
            h('span', { class: 'dev-path', text: normalizeDir(SAVE_DIRS[dev.key]) })),
          h('span', { class: 'copy-state' }, stateIcon, stateText));
        const failHint = h('p', { class: 'fail-hint', text: '没能自动复制：长按下面的命令，全选后复制。' });
        const term = h('code', { class: 'term' });
        const el = h('div', { class: 'target' }, btn, failHint, term);
        const t = { preset, dev, el, btn, stateIcon, stateText, term, command: '', timer: 0 };
        btn.addEventListener('click', (e) => onCopy(t, e.detail === 0)); // detail 为 0 表示用键盘按的
        return t;
      });
      const el = h('section', { class: 'group', 'data-kind': preset.kind },
        h('div', { class: 'group-head' },
          h('span', { class: 'kind' }, icon(preset.kind, 20)),
          h('div', { class: 'label' },
            h('span', { class: 'name', text: preset.name }),
            h('span', { class: 'hint', text: preset.hint }))),
        h('div', { class: 'targets' }, targets.map((t) => t.el)));
      return { el, targets };
    });
    const targets = [].concat(...groups.map((g) => g.targets));

    const cmdToggle = h('button', { class: 'pill', type: 'button', 'aria-pressed': 'false' });

    const panel = h('section', { class: 'panel', id: 'ytdlp-panel', role: 'dialog', 'aria-label': 'yt-dlp 下载命令' },
      h('header', { class: 'head' },
        h('div', { class: 'head-text' },
          h('h2', { text: 'yt-dlp 下载命令' }),
          titleEl,
          urlEl),
        closeBtn),
      groups.map((g) => g.el),
      h('footer', { class: 'foot' },
        h('p', { class: 'note', text: '手机版粘贴到 Termux 运行，电脑版粘贴到 cmd 运行' }),
        cmdToggle));

    root.append(panel, fab);
    shadow.append(style, root);
    document.body.appendChild(host);

    /* ── 状态 ── */

    // routeId 只追踪地址栏中的视频；currentId 还可以暂时指向列表里选中的视频卡片。
    let routeId = getVideoId();
    let currentId = routeId;
    let isOpen = false;
    let showCmd = store.get(STORE_SHOW_CMD, '0') === '1';
    let dockSide = null;
    let dockYRatio = 0.78;
    let dockNeedsApply = false;
    let isDragging = false;
    let dragState = null;
    let suppressClickUntil = 0;
    let autoHideTimer = 0;

    function readDockPosition() {
      let raw = store.get(STORE_FAB_POSITION, '');
      if (!raw) return null;
      try {
        if (typeof raw === 'string') raw = JSON.parse(raw);
        if (!raw || (raw.side !== 'left' && raw.side !== 'right')) return null;
        const ratio = Number(raw.yRatio);
        return { side: raw.side, yRatio: Number.isFinite(ratio) ? Math.max(0, Math.min(1, ratio)) : 0.78 };
      } catch (_) { return null; }
    }

    function saveDockPosition() {
      if (!dockSide) return;
      store.set(STORE_FAB_POSITION, JSON.stringify({ side: dockSide, yRatio: dockYRatio }));
    }

    function clamp(value, min, max) {
      return Math.min(Math.max(value, min), Math.max(min, max));
    }

    function applyDockPosition(hidden) {
      if (!dockSide || isDragging) return;
      fab.dataset.dock = dockSide;
      fab.classList.toggle('is-hidden', !!hidden && !isOpen);
      fab.style.right = 'auto';
      fab.style.bottom = 'auto';
      const width = fab.getBoundingClientRect().width || fab.offsetWidth || 176;
      const height = fab.getBoundingClientRect().height || fab.offsetHeight || 40;
      const vw = window.innerWidth || document.documentElement.clientWidth;
      const vh = window.innerHeight || document.documentElement.clientHeight;
      const top = clamp(dockYRatio * Math.max(1, vh - height), 8, vh - height - 8);
      const left = fab.classList.contains('is-hidden')
        ? (dockSide === 'left' ? -Math.max(0, width - FAB_PEEK) : vw - FAB_PEEK)
        : (dockSide === 'left' ? 8 : vw - width - 8);
      fab.style.left = left + 'px';
      fab.style.top = top + 'px';
    }

    function revealFab() {
      if (autoHideTimer) clearTimeout(autoHideTimer);
      autoHideTimer = 0;
      if (dockSide) applyDockPosition(false);
      else fab.classList.remove('is-hidden');
    }

    function scheduleAutoHide(delay = 1000) {
      if (autoHideTimer) clearTimeout(autoHideTimer);
      autoHideTimer = 0;
      if (!dockSide || isOpen || isDragging) return;
      autoHideTimer = setTimeout(() => {
        autoHideTimer = 0;
        if (isOpen || isDragging || !dockSide) return;
        // 键盘用户正在使用焦点时不自动把控件藏起来。
        try { if (fab.matches(':focus-visible')) return; } catch (_) { /* 旧浏览器忽略 */ }
        applyDockPosition(true);
      }, delay);
    }

    function positionPanel() {
      if (!currentId) return;
      const vw = window.innerWidth || document.documentElement.clientWidth;
      const vh = window.innerHeight || document.documentElement.clientHeight;
      const narrow = vw <= 560;
      const width = Math.max(1, Math.min(narrow ? vw - 16 : 420, vw - 16));
      const fabRect = fab.getBoundingClientRect();

      panel.style.width = width + 'px';
      panel.style.maxWidth = Math.max(1, vw - 16) + 'px';
      panel.style.maxHeight = Math.max(120, vh - 24) + 'px';
      panel.style.left = '8px';
      panel.style.right = 'auto';
      panel.style.top = '8px';
      panel.style.bottom = 'auto';

      // 面板虽不可见，但仍参与布局测量；测量后再决定最终位置。
      const measured = panel.getBoundingClientRect();
      const panelHeight = Math.max(100, Math.min(panel.offsetHeight || measured.height || panel.scrollHeight || 300, vh - 24));
      let left = 8;
      let top = 8;

      if (narrow) {
        const above = fabRect.top - 20;
        const below = vh - fabRect.bottom - 20;
        if (panelHeight <= above) top = fabRect.top - panelHeight - 12;
        else if (panelHeight <= below) top = fabRect.bottom + 12;
        else top = above >= below ? 8 : Math.max(8, vh - panelHeight - 8);
        left = 8;
      } else {
        if (dockSide === 'left') left = fabRect.right + 12;
        else if (dockSide === 'right') left = fabRect.left - width - 12;
        else left = fabRect.right - width;

        if (left + width > vw - 8) left = fabRect.left - width - 12;
        if (left < 8) left = fabRect.right + 12;
        left = clamp(left, 8, vw - width - 8);
        top = clamp(fabRect.top + (fabRect.height - panelHeight) / 2, 8, vh - panelHeight - 8);
      }

      panel.style.left = left + 'px';
      panel.style.top = top + 'px';
      panel.style.transformOrigin = narrow ? (top < fabRect.top ? '50% 100%' : '50% 0%')
        : (left >= fabRect.left ? '0% 50%' : '100% 50%');
    }

    function handleViewportChange() {
      if (dockSide && !isDragging) applyDockPosition(fab.classList.contains('is-hidden') && !isOpen);
      if (isOpen) positionPanel();
    }

    const savedDock = readDockPosition();
    if (savedDock) {
      dockSide = savedDock.side;
      dockYRatio = savedDock.yRatio;
      fab.dataset.dock = dockSide;
      dockNeedsApply = true;
    }

    function applyShowCmd() {
      root.classList.toggle('show-cmd', showCmd);
      cmdToggle.setAttribute('aria-pressed', String(showCmd));
      cmdToggle.textContent = showCmd ? '收起命令' : '查看命令';
    }

    function resetTarget(t) {
      clearTimeout(t.timer);
      t.el.classList.remove('is-fail');
      t.btn.classList.remove('is-done');
      setIcon(t.stateIcon, 'copy', 15);
      t.stateText.textContent = '复制';
    }

    function renderCommands() {
      if (!currentId) return;
      urlEl.textContent = canonicalUrl(currentId).replace(/^https:\/\/www\./, '');
      for (const t of targets) {
        const tokens = buildTokens(t.preset, currentId, normalizeDir(SAVE_DIRS[t.dev.key]));
        t.command = tokens.join(' ');
        t.term.textContent = '';
        tokens.forEach((tok, i) => {
          if (i > 0) t.term.append(' ');
          t.term.append(h('span', { class: tokenClass(tok, i, tokens), text: tok }));
        });
        resetTarget(t);
      }
    }

    function renderTitle() {
      const id = currentId;
      const routeTitle = id === routeId ? pageTitle() : '';
      titleEl.textContent = routeTitle || '正在读取标题…';
      fetchTitle(id).then((t) => {
        if (id !== currentId) return;
        titleEl.textContent = t || (id === routeId ? pageTitle() : '') || '未能读取标题（不影响下载）';
        if (isOpen) positionPanel();
      });
    }

    function pageIsDark() {
      const html = document.documentElement;
      if (html.hasAttribute('dark')) return true;
      for (const el of [document.body, html]) {
        if (!el) continue;
        const nums = (getComputedStyle(el).backgroundColor || '').match(/[\d.]+/g);
        if (!nums || nums.length < 3) continue;
        const [r, g, b, a = 1] = nums.map(Number);
        if (a === 0) continue;
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128;
      }
      return SITE === 'music';
    }

    function syncTheme() {
      const theme = pageIsDark() ? 'dark' : 'light';
      if (root.getAttribute('data-theme') !== theme) root.setAttribute('data-theme', theme);
    }

    let thumbnailScanTimer = 0;
    let thumbnailButtonSequence = 0;

    function positionThumbnailButton(button, anchor, thumbHost) {
      const anchorRect = anchor.getBoundingClientRect();
      const hostRect = thumbHost.getBoundingClientRect();
      if (!anchorRect.width || !anchorRect.height || !hostRect.width || !hostRect.height) return;
      // 按钮在容器内与缩略图左上角对齐，即使新版卡片外层还包含标题/元数据也不会跑位。
      const top = Math.max(0, anchorRect.top - hostRect.top + (thumbHost.clientTop || 0) + 4);
      const left = Math.max(0, anchorRect.left - hostRect.left + (thumbHost.clientLeft || 0) + 4);
      button.style.setProperty('--ytdlp-thumb-top', top + 'px');
      button.style.setProperty('--ytdlp-thumb-left', left + 'px');
    }

    function addThumbnailButtonStyles() {
      if (document.getElementById(THUMB_STYLE_ID)) return;
      const style = document.createElement('style');
      style.id = THUMB_STYLE_ID;
      style.textContent = `
.${THUMB_HOST_CLASS} { position: relative !important; isolation: isolate !important; }
.${THUMB_BUTTON_CLASS} {
  appearance: none !important;
  -webkit-appearance: none !important;
  position: absolute !important;
  top: var(--ytdlp-thumb-top, 4px) !important;
  left: var(--ytdlp-thumb-left, 4px) !important;
  z-index: 2147483000 !important;
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
  box-sizing: border-box !important;
  width: 8mm !important;
  height: 8mm !important;
  min-width: 8mm !important;
  min-height: 8mm !important;
  max-width: 8mm !important;
  max-height: 8mm !important;
  margin: 0 !important;
  padding: 0 !important;
  border: 1px solid rgba(255,255,255,.72) !important;
  border-radius: 6px !important;
  background: rgba(18,18,18,.90) !important;
  color: #fff !important;
  line-height: 1 !important;
  cursor: pointer !important;
  pointer-events: auto !important;
  opacity: .96 !important;
  box-shadow: 0 2px 7px rgba(0,0,0,.38) !important;
  touch-action: manipulation !important;
  user-select: none !important;
  -webkit-user-select: none !important;
  -webkit-tap-highlight-color: transparent !important;
}
.${THUMB_BUTTON_CLASS}:hover {
  background: #e62117 !important;
  opacity: 1 !important;
  transform: scale(1.04);
}
.${THUMB_BUTTON_CLASS}:active { transform: scale(.94); }
.${THUMB_BUTTON_CLASS}:focus-visible { outline: 2px solid #fff !important; outline-offset: 2px !important; }
.${THUMB_BUTTON_CLASS} svg {
  display: block !important;
  width: 16px !important;
  height: 16px !important;
  flex: none !important;
  pointer-events: none !important;
}
`;
      (document.head || document.documentElement).appendChild(style);
    }

    // 缩略图按钮只切换当前视频并打开六选项面板；不自动复制、不猜测设备类型。
    function selectThumbnailVideo(id) {
      if (!id || !/^[\w-]{11}$/.test(id)) return;
      currentId = id;
      host.style.display = 'block';
      syncTheme();
      if (isOpen) {
        revealFab();
        renderCommands();
        renderTitle();
        positionPanel();
      } else {
        openPanel();
      }
    }

    thumbnailButtonAction = (button) => selectThumbnailVideo(button.getAttribute('data-video-id'));

    function refreshThumbnailButtons() {
      if (!document.body) return;
      addThumbnailButtonStyles();
      const activeButtons = new Set();
      const anchors = document.querySelectorAll(THUMBNAIL_SELECTOR);
      for (const anchor of anchors) {
        if (!isThumbnailAnchor(anchor)) continue;
        const id = getVideoIdFromHref(anchor.getAttribute('href') || anchor.href);
        if (!id) continue;

        const thumbHost = getThumbnailHost(anchor);
        if (!thumbHost || !thumbHost.isConnected) continue;
        thumbHost.classList.add(THUMB_HOST_CLASS);

        // 每个缩略图锚点拥有独立按钮，避免同一卡片容器中多个视频链接共用一个按钮。
        let anchorKey = anchor.getAttribute('data-ytdlp-thumb-key');
        if (!anchorKey) {
          anchorKey = 'thumb-' + (++thumbnailButtonSequence);
          anchor.setAttribute('data-ytdlp-thumb-key', anchorKey);
        }

        let button = Array.from(thumbHost.children).find((child) =>
          child.classList && child.classList.contains(THUMB_BUTTON_CLASS) &&
          child.getAttribute('data-anchor-key') === anchorKey);
        if (!button) {
          button = h('button', {
            class: THUMB_BUTTON_CLASS,
            type: 'button',
            'aria-label': '显示此视频的复制命令选项（不打开视频）',
            title: '显示复制命令选项（不打开视频）',
            'data-video-id': id,
            'data-anchor-key': anchorKey,
          }, icon('download', 16));
          thumbHost.appendChild(button);
        } else if (button.getAttribute('data-video-id') !== id) {
          button.setAttribute('data-video-id', id);
        }

        positionThumbnailButton(button, anchor, thumbHost);
        activeButtons.add(button);
      }

      // 清理 YouTube 重建卡片后遗留的孤立按钮。
      document.querySelectorAll('.' + THUMB_BUTTON_CLASS).forEach((button) => {
        if (!activeButtons.has(button)) button.remove();
      });
    }

    function scheduleThumbnailScan(delay = 120) {
      // 合并短时间内的大量 DOM 变化，避免 YouTube 连续更新卡片时反复全页扫描。
      if (thumbnailScanTimer) return;
      thumbnailScanTimer = setTimeout(() => {
        thumbnailScanTimer = 0;
        refreshThumbnailButtons();
      }, delay);
    }

    function openPanel() {
      if (!currentId) return;
      revealFab();
      isOpen = true;
      syncTheme();
      renderCommands();
      renderTitle();
      positionPanel();
      panel.classList.add('open');
      fab.setAttribute('aria-expanded', 'true');
    }

    function closePanel() {
      if (!isOpen) return;
      isOpen = false;
      panel.classList.remove('open');
      fab.setAttribute('aria-expanded', 'false');
      scheduleAutoHide(900);
    }

    async function onCopy(t, fromKeyboard) {
      // copyText 的第一步是同步执行的，所以要直接在点击事件里调用
      const ok = await copyText(t.command);
      // 键盘操作时把焦点还给按钮；手指点按时不用，免得按钮上出现一圈焦点框
      if (fromKeyboard) { try { t.btn.focus({ preventScroll: true }); } catch (_) { /* 忽略 */ } }
      resetTarget(t);
      void t.btn.offsetWidth; // 让高光动画可以重复播放
      if (ok) {
        t.btn.classList.add('is-done');
        setIcon(t.stateIcon, 'check', 15);
        t.stateText.textContent = '已复制';
        t.timer = setTimeout(() => resetTarget(t), 1600);
      } else {
        t.el.classList.add('is-fail'); // 展开这条命令，方便长按手动复制
        t.stateText.textContent = '复制失败';
        selectNode(t.term);
      }
      if (isOpen) positionPanel();
    }

    // YouTube 是单页应用，切换视频不刷新页面，所以定时检查地址变化
    function sync() {
      if (!host.isConnected && document.body) document.body.appendChild(host);
      const id = getVideoId();
      if (id !== routeId) {
        routeId = id;
        currentId = id;
        if (!id) closePanel();
        else {
          syncTheme();
          if (isOpen) { renderCommands(); renderTitle(); }
        }
      }
      const fullscreen = document.fullscreenElement || document.webkitFullscreenElement;
      const display = currentId && !fullscreen ? 'block' : 'none';
      if (host.style.display !== display) host.style.display = display;
      if (display === 'block' && dockNeedsApply) {
        applyDockPosition(true);
        dockNeedsApply = false;
      }
    }

    /* ── 事件 ── */

    applyShowCmd();

    // 拖动交互：小于 6px 的移动仍视为点击，避免普通点按被误判为拖动。
    fab.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 && e.pointerType !== 'touch' && e.pointerType !== 'pen') return;
      if (autoHideTimer) clearTimeout(autoHideTimer);
      autoHideTimer = 0;
      const rect = fab.getBoundingClientRect();
      dragState = {
        pointerId: e.pointerId,
        startX: e.clientX,
        startY: e.clientY,
        startLeft: rect.left,
        startTop: rect.top,
        dragged: false,
        baseLeft: rect.left,
        baseTop: rect.top,
      };
      try { fab.setPointerCapture(e.pointerId); } catch (_) { /* 某些旧版移动浏览器不支持 */ }
    });

    fab.addEventListener('pointermove', (e) => {
      if (!dragState || e.pointerId !== dragState.pointerId) return;
      const dx = e.clientX - dragState.startX;
      const dy = e.clientY - dragState.startY;
      if (!dragState.dragged && Math.hypot(dx, dy) < 6) return;

      if (!dragState.dragged) {
        dragState.dragged = true;
        isDragging = true;
        if (isOpen) {
          isOpen = false;
          panel.classList.remove('open');
          fab.setAttribute('aria-expanded', 'false');
        }
        fab.classList.remove('is-hidden');
        fab.classList.add('is-dragging');
        fab.dataset.dock = 'dragging';
        fab.style.right = 'auto';
        fab.style.bottom = 'auto';
        const rect = fab.getBoundingClientRect();
        // 从已隐藏的按钮开始拖动时，先在同一侧完整展开，再跟随手指/鼠标移动。
        dragState.baseLeft = dockSide === 'left' ? 8
          : dockSide === 'right' ? window.innerWidth - rect.width - 8
            : dragState.startLeft;
        dragState.baseTop = clamp(dragState.startTop, 8, window.innerHeight - rect.height - 8);
        fab.style.left = dragState.baseLeft + 'px';
        fab.style.top = dragState.baseTop + 'px';
      }

      const rect = fab.getBoundingClientRect();
      const maxLeft = Math.max(8, window.innerWidth - rect.width - 8);
      const maxTop = Math.max(8, window.innerHeight - rect.height - 8);
      fab.style.left = clamp(dragState.baseLeft + dx, 8, maxLeft) + 'px';
      fab.style.top = clamp(dragState.baseTop + dy, 8, maxTop) + 'px';
      e.preventDefault();
    });

    function finishDrag(e) {
      if (!dragState || e.pointerId !== dragState.pointerId) return;
      const state = dragState;
      dragState = null;
      try { if (fab.hasPointerCapture(e.pointerId)) fab.releasePointerCapture(e.pointerId); } catch (_) { /* 忽略 */ }
      if (!state.dragged) return;

      isDragging = false;
      fab.classList.remove('is-dragging', 'is-hidden');
      const rect = fab.getBoundingClientRect();
      const vw = window.innerWidth || document.documentElement.clientWidth;
      const vh = window.innerHeight || document.documentElement.clientHeight;
      dockSide = rect.left + rect.width / 2 < vw / 2 ? 'left' : 'right';
      dockYRatio = clamp(rect.top / Math.max(1, vh - rect.height), 0, 1);
      fab.dataset.dock = dockSide;
      saveDockPosition();
      applyDockPosition(false);
      suppressClickUntil = Date.now() + 500;
      scheduleAutoHide(1000);
    }

    fab.addEventListener('pointerup', finishDrag);
    fab.addEventListener('pointercancel', finishDrag);
    fab.addEventListener('pointerenter', (e) => {
      if (e.pointerType === 'mouse' && dockSide && fab.classList.contains('is-hidden')) revealFab();
    });
    fab.addEventListener('pointerleave', (e) => {
      if (e.pointerType === 'mouse' && dockSide && !isOpen && !isDragging) scheduleAutoHide(700);
    });
    fab.addEventListener('focus', () => {
      if (dockSide) {
        revealFab();
        if (!isOpen) scheduleAutoHide(1200);
      }
    });
    fab.addEventListener('blur', () => scheduleAutoHide(900));
    fab.addEventListener('click', (e) => {
      if (Date.now() < suppressClickUntil) {
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      if (isOpen) closePanel();
      else openPanel();
    });

    closeBtn.addEventListener('click', () => { closePanel(); fab.focus(); });
    cmdToggle.addEventListener('click', () => {
      showCmd = !showCmd;
      store.set(STORE_SHOW_CMD, showCmd ? '1' : '0');
      applyShowCmd();
      if (isOpen) positionPanel();
    });

    // 面板内的鼠标/触屏事件也不冒泡给 YouTube，避免与播放器/卡片事件冲突。
    // 使用冒泡阶段，确保复制按钮自己的 click 处理先执行。
    for (const type of [
      'pointerdown', 'pointerup', 'pointercancel', 'mousedown', 'mouseup',
      'touchstart', 'touchend', 'touchcancel', 'click', 'dblclick', 'auxclick', 'contextmenu',
    ]) {
      root.addEventListener(type, (e) => {
        e.stopPropagation();
        if (type === 'auxclick' || type === 'contextmenu') e.preventDefault();
      });
    }

    // 面板里的按键不冒泡给 YouTube，否则会触发播放、全屏等快捷键
    for (const type of ['keydown', 'keypress', 'keyup']) {
      root.addEventListener(type, (e) => {
        e.stopPropagation();
        if (type === 'keydown' && e.key === 'Escape' && isOpen) { closePanel(); fab.focus(); }
      });
    }
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && isOpen) closePanel(); });

    // 点击面板外部时收起
    document.addEventListener('pointerdown', (e) => {
      if (!isOpen) return;
      const path = typeof e.composedPath === 'function' ? e.composedPath() : [];
      // 在面板打开时点另一张缩略图按钮，应切换面板内容而不是先关闭再重开。
      if (path.some((node) => node && node.classList && node.classList.contains(THUMB_BUTTON_CLASS))) return;
      if (!path.includes(host)) closePanel();
    }, true);

    window.addEventListener('resize', handleViewportChange, { passive: true });
    window.addEventListener('orientationchange', handleViewportChange, { passive: true });
    if (window.visualViewport) window.visualViewport.addEventListener('resize', handleViewportChange, { passive: true });

    for (const ev of ['yt-navigate-finish', 'yt-page-data-updated', 'popstate']) {
      window.addEventListener(ev, sync, true);
      window.addEventListener(ev, () => scheduleThumbnailScan(100), true);
    }
    document.addEventListener('fullscreenchange', sync);
    document.addEventListener('webkitfullscreenchange', sync);
    new MutationObserver(syncTheme).observe(document.documentElement, { attributes: true, attributeFilter: ['dark'] });

    // YouTube 首页、搜索结果、侧栏和订阅页会持续动态插入/复用视频卡片。
    const thumbnailObserver = new MutationObserver(() => scheduleThumbnailScan(140));
    thumbnailObserver.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['href'],
    });

    setInterval(sync, 500);
    sync();
    scheduleThumbnailScan(0);
  }

  if (document.body) init();
  else document.addEventListener('DOMContentLoaded', init, { once: true });
})();
