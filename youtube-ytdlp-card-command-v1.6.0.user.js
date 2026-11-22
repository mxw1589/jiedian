// ==UserScript==
// @name         YouTube 下载命令生成器（yt-dlp）
// @namespace    ytdlp-command-generator
// @version      1.6.0
// @description  YouTube 多视频卡片下载按钮：无需打开视频页，按卡片生成 yt-dlp 命令；保留原有下载面板与设备配置
// @match        https://www.youtube.com/*
// @match        https://youtube.com/*
// @match        https://m.youtube.com/*
// @match        https://music.youtube.com/*
// @grant        GM_setClipboard
// @grant        GM_getValue
// @grant        GM_setValue
// @run-at       document-idle
// @noframes
// @license      MIT
// ==/UserScript==

/*
 * 用法：YouTube 首页/搜索/订阅/播放列表等视频卡片上显示 21×21px（约 5.6mm）的下载按钮；点击即可针对该视频生成 yt-dlp 命令，无需打开视频页。
 *       打开任意视频页（含 Shorts）仍可使用「生成下载命令」悬浮按钮。
 *       可拖动按钮到任意位置，松手后自动吸附到左/右边缘；按钮会延时收起，悬停/点击可唤回。
 *       吸边位置会保存在脚本管理器/本地存储中，刷新后尽可能恢复。
 *       点开后有多种下载格式，每种格式都分「手机」和「电脑」两个版本：
 *       手机命令使用 Bash 单引号转义；电脑命令使用 Windows CMD 双引号转义。
 * 保存位置：手机存到 /storage/emulated/0/snaptube，电脑存到 D:\snaptube，
 *       文件夹不存在时由 yt-dlp 创建；也可在面板中分别修改手机/电脑保存目录。
 * 复制：同时用三种方式写入剪贴板，手机浏览器上也能可靠复制。
 * 认证：电脑可读取浏览器 Cookie（支持自定义 Profile Path）或 cookies.txt；手机 Termux 使用导出的 cookies.txt。
 * 防限流：支持平衡/保守请求节奏、指数退避重试；可选启用已安装的 PO Token Provider。
 * 新增：多视频卡片下载按钮、按卡片 videoId 独立生成命令；自定义保存目录、下载历史、720p、原始音频与字幕下载；Windows CMD / Termux 分别转义。
 * 依赖：电脑需要 yt-dlp、ffmpeg 和可用的 JavaScript 运行时；手机 Termux 需要 yt-dlp、ffmpeg，并运行过 termux-setup-storage。
 */

(function () {
  'use strict';

  /* ───────────── 命令配置 ───────────── */

  // 保存位置（文件夹不存在会自动创建）
  const DEFAULT_SAVE_DIRS = {
    phone: '/storage/emulated/0/snaptube',
    pc: 'D:\\snaptube',
  };

  // 每种格式下的按钮顺序：手机在上，电脑在下
  const DEVICES = [
    { key: 'phone', name: '手机', icon: 'phone' },
    { key: 'pc', name: '电脑', icon: 'desktop' },
  ];

  // 视频文件名带上分辨率，同一个视频下两种画质不会互相覆盖
  const VIDEO_NAME = '%(title)s [%(resolution)s].%(ext)s';
  const AUDIO_NAME = '%(title)s.%(ext)s';

  // 格式顺序：1080p → 720p → 最高画质 → MP3 → 原始音频 → 字幕
  // args 保存原始参数；最终根据目标终端（CMD / Bash）分别转义。
  const PRESETS = [
    {
      key: 'mp4-1080', kind: 'video', name: 'MP4 1080p',
      hint: '最高不超过 1080p，优先 H.264/AAC；合并时优先 MP4，需要 FFmpeg',
      args: ['-S', 'res:1080,vcodec:h264,acodec:aac', '--merge-output-format', 'mp4', '-o', VIDEO_NAME],
    },
    {
      key: 'mp4-720', kind: 'video', name: 'MP4 720p',
      hint: '最高不超过 720p，文件较小，优先 H.264/AAC 与 MP4',
      args: ['-S', 'res:720,vcodec:h264,acodec:aac', '--merge-output-format', 'mp4', '-o', VIDEO_NAME],
    },
    {
      key: 'mp4-best', kind: 'video', name: '最高画质（MP4 优先）',
      hint: '优先最高分辨率/码率；合并时优先 MP4，可能使用 VP9/AV1',
      args: ['-f', 'bv*+ba/b', '--merge-output-format', 'mp4', '-o', VIDEO_NAME],
    },
    {
      key: 'mp3', kind: 'audio', name: 'MP3 音频',
      hint: '最高质量 VBR MP3，自动嵌入封面与元数据；需要 FFmpeg',
      args: ['-x', '--audio-format', 'mp3', '--audio-quality', '0', '--embed-thumbnail', '--embed-metadata', '-o', AUDIO_NAME],
    },
    {
      key: 'audio-original', kind: 'audio', name: '原始音频',
      hint: '下载最佳音频流，不转码；可能是 M4A、Opus 或 WebM',
      args: ['-f', 'ba', '-o', AUDIO_NAME],
    },
    {
      key: 'subtitles', kind: 'subtitle', name: '字幕（SRT 优先）',
      hint: '下载人工字幕与自动字幕，不下载视频；可获取语言由视频决定',
      args: ['--write-subs', '--write-auto-subs', '--sub-langs', 'all,-live_chat', '--sub-format', 'srt/best', '--skip-download', '-o', '%(title)s.%(ext)s'],
    },
  ];

  const HOST_ID = 'ytdlp-cmd-host';
  const STORE_SHOW_CMD = 'showCommands';
  const STORE_FAB_POSITION = 'fabPosition';
  const STORE_SAVE_PC = 'saveDirPc';
  const STORE_SAVE_PHONE = 'saveDirPhone';
  const STORE_UA_PC = 'userAgentPc';
  const STORE_UA_PHONE = 'userAgentPhone';
  const STORE_RATE_MODE = 'rateMode';
  const STORE_ARCHIVE_MODE = 'archiveMode';
  const STORE_AUTH_PC_MODE = 'authPcMode';
  const STORE_AUTH_PC_COOKIE = 'authPcCookiePath';
  const STORE_AUTH_PC_PROFILE = 'authPcProfilePath';
  const STORE_AUTH_PHONE_MODE = 'authPhoneMode';
  const STORE_AUTH_PHONE_COOKIE = 'authPhoneCookiePath';
  const STORE_POT_MODE = 'potMode';
  const FAB_PEEK = 44; // 吸边隐藏时露出的可点击宽度（像素）
  const SITE = /^music\./.test(location.hostname) ? 'music'
    : /^m\./.test(location.hostname) ? 'mobile' : 'desktop';
  const IS_MOBILE_DEVICE = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent || '') || SITE === 'mobile';

  /* ───────────── 命令拼装 ───────────── */

  // Windows CMD 和 Termux Bash 的引号规则不同，不能把同一条命令原样用于两种终端。
  // 路径输入会拒绝双引号/换行，避免产生不可预测的 shell 解析结果。
  function quoteArg(value, shell) {
    const text = String(value == null ? '' : value);
    if (shell === 'bash') return "'" + text.replace(/'/g, "'\\''") + "'";
    return '"' + text.replace(/"/g, '') + '"';
  }

  function serializeTokens(tokens, shell) {
    return tokens.map((token, index) => {
      if (index === 0 || String(token).startsWith('-')) return String(token);
      return quoteArg(token, shell);
    }).join(' ');
  }

  function detectBrowser() {
    const ua = navigator.userAgent || '';
    if (/EdgA?\//i.test(ua)) return 'edge';
    if (/Firefox\//i.test(ua)) return 'firefox';
    if (/Vivaldi\//i.test(ua)) return 'vivaldi';
    if (/OPR\//i.test(ua)) return 'opera';
    // Brave 通常主动隐藏 UA 品牌标记，需在界面中手动选择 Brave。
    return 'chrome';
  }

  function normalizeSaveDir(raw, fallback) {
    const value = String(raw == null ? '' : raw).trim().replace(/^['"]+|['"]+$/g, '');
    if (!value || /["\r\n]/.test(value)) return fallback;
    return normalizeDir(value) || fallback;
  }

  // Windows 保存路径统一输出反斜杠；兼容迁移旧版保存的 D:/snaptube。
  function normalizePcSaveDir(raw) {
    return normalizeSaveDir(raw, DEFAULT_SAVE_DIRS.pc).replace(/\//g, '\\');
  }

  // Profile Path 应是 Chrome/Edge 版本页显示的完整配置目录（例如 ...\User Data\Default）。
  function normalizeProfilePath(raw) {
    const value = String(raw == null ? '' : raw).trim().replace(/^['"]+|['"]+$/g, '');
    if (!value || /["\r\n]/.test(value)) return '';
    return value;
  }

  function joinPath(dir, filename) {
    const clean = String(dir || '').replace(/[\\/]+$/, '');
    return clean + '/' + filename;
  }

  function getRateProfile(mode) {
    return mode === 'balanced'
      ? { requestDelay: '1', minDelay: '5', maxDelay: '10', httpRetry: '5:60' }
      : { requestDelay: '2', minDelay: '8', maxDelay: '15', httpRetry: '10:120' };
  }

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

  // 解析卡片链接：支持 watch、Shorts、直播、embed、youtu.be，以及相对 URL。
  function extractVideoIdFromUrl(raw) {
    if (!raw) return null;
    let u;
    try { u = new URL(String(raw), location.origin || 'https://www.youtube.com'); } catch (_) { return null; }
    const host = (u.hostname || '').toLowerCase().replace(/^www\./, '');
    const allowedHost = host === 'youtu.be' || host === 'youtube.com' || host.endsWith('.youtube.com') || host === 'youtube-nocookie.com';
    if (!allowedHost) return null;
    let id = null;
    if (host === 'youtu.be') {
      id = u.pathname.split('/').filter(Boolean)[0] || null;
    } else if (u.pathname === '/watch') {
      id = u.searchParams.get('v');
    } else {
      const m = u.pathname.match(/^\/(?:shorts|live|embed|v)\/([\w-]{11})(?:\/|$)/);
      if (m) id = m[1];
    }
    return id && /^[\w-]{11}$/.test(id) ? id : null;
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

  // 生成原始参数，最后按目标终端转义。保守节奏适合近期遇到 429 的情况。
  function buildTokens(preset, id, dir, dev, settings) {
    const shell = dev.key === 'phone' ? 'bash' : 'cmd';
    const rate = getRateProfile(settings.rateMode);
    const tokens = [
      'yt-dlp',
      '--no-playlist',
      '--socket-timeout', '30',
      '--sleep-requests', rate.requestDelay,
      '--sleep-interval', rate.minDelay,
      '--max-sleep-interval', rate.maxDelay,
      '--retries', '5',
      '--extractor-retries', '3',
      '--fragment-retries', '10',
      '--file-access-retries', '3',
      '--retry-sleep', 'http:exp=' + rate.httpRetry,
      '--retry-sleep', 'fragment:exp=1:20',
      '--concurrent-fragments', '1',
    ];

    if (dev.key === 'pc') tokens.push('--windows-filenames', '--trim-filenames', '180');
    if (preset.kind === 'subtitle') tokens.push('--sleep-subtitles', '2');
    const userAgent = dev.key === 'phone' ? settings.phoneUserAgent : settings.pcUserAgent;
    if (userAgent) tokens.push('--user-agent', userAgent);

    const mode = dev.key === 'phone' ? settings.phoneMode : settings.pcMode;
    const cookiePath = dev.key === 'phone' ? settings.phoneCookiePath : settings.pcCookiePath;
    if (mode === 'file' && cookiePath) {
      tokens.push('--cookies', cookiePath);
    } else if (mode && mode !== 'none' && mode !== 'file') {
      const profilePath = dev.key === 'pc' ? settings.pcProfilePath : '';
      const browserSpec = profilePath ? mode + ':' + profilePath : mode;
      tokens.push('--cookies-from-browser', browserSpec);
    }

    // 仅在目标设备已安装并正确运行 PO Token Provider 时启用。
    if (settings.potMode) tokens.push('--extractor-args', 'youtube:player_client=mweb');

    if (settings.archiveMode) {
      const archiveName = '.yt-dlp-archive-' + preset.key + '.txt';
      tokens.push('--download-archive', joinPath(dir, archiveName));
    }

    return tokens.concat(preset.args, ['-P', dir, canonicalUrl(id)]);
  }

  function tokenClass(tok, i, all) {
    if (i === 0) return 'tk-cmd';
    if (i === all.length - 1) return 'tk-url';
    if (tok[0] === '"' || tok[0] === "'") return 'tk-str';
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
    subtitle: [['rect', { x: 3, y: 5, width: 18, height: 14, rx: 2 }], ['path', { d: 'M7 10h4M13 10h4M7 14h3M12 14h5' }]],
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

/* 认证与限流设置 */
.auth {
  margin: 10px 16px 0;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--surface);
}
.auth summary {
  padding: 9px 11px;
  color: var(--ink);
  font: 600 12.5px/1.4 var(--ui);
  cursor: pointer;
  user-select: none;
}
.auth[open] summary { border-bottom: 1px solid var(--line); }
.auth-body { padding: 9px 11px 11px; }
.auth-row {
  display: grid;
  grid-template-columns: 62px minmax(0, 1fr);
  align-items: center;
  gap: 8px;
  margin-top: 8px;
}
.auth-row:first-child { margin-top: 0; }
.auth-label { color: var(--ink-2); font-size: 12px; }
.auth-select, .auth-input {
  width: 100%;
  min-width: 0;
  min-height: 34px;
  padding: 6px 9px;
  border: 1px solid var(--line-2);
  border-radius: 7px;
  background: var(--surface-2);
  color: var(--ink);
  font: 12px/1.4 var(--ui);
}
.auth-path-wrap { grid-column: 2; min-width: 0; }
.auth-input { font-family: var(--mono); }
.auth-check {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  margin-top: 10px;
  color: var(--ink);
  font-size: 12px;
  line-height: 1.45;
}
.auth-check input { margin: 2px 0 0; flex: none; }
.auth-hint {
  margin: 8px 0 0;
  color: var(--ink-2);
  font-size: 11.5px;
  line-height: 1.5;
}
.auth-warning { color: var(--danger); }
.auth-section-label { margin: 12px 0 5px; color: var(--ink); font-size: 12px; font-weight: 600; }
.auth-inline { display: flex; align-items: center; gap: 8px; margin-top: 9px; color: var(--ink); font-size: 12px; }
.auth-inline input { margin: 0; flex: none; }
.group[data-kind="subtitle"] .kind { color: #7b61c9; }

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
  flex-wrap: wrap;
  gap: 8px;
  padding: 12px 16px 14px;
  border-top: 1px solid var(--line);
}
.note { flex: 1 1 100%; min-width: 0; margin: 0; font-size: 12px; line-height: 1.5; color: var(--ink-2); }
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

  /* ───────────── 多视频卡片下载按钮 ───────────── */

  // 21 CSS px ≈ 5.56 mm（按 96 dpi 换算），宽高均小于用户要求的 6 mm。
  const CARD_BUTTON_SIZE = 21;
  const CARD_SELECTOR = [
    'ytd-rich-item-renderer', 'ytd-rich-grid-media', 'ytd-video-renderer',
    'ytd-grid-video-renderer', 'ytd-compact-video-renderer', 'ytd-playlist-video-renderer',
    'ytd-playlist-panel-video-renderer', 'ytd-reel-item-renderer', 'ytd-reel-video-renderer',
    'yt-lockup-view-model', 'yt-shorts-lockup-view-model', 'ytm-video-with-context-renderer',
    'ytm-compact-video-renderer', 'ytm-rich-item-renderer', 'ytm-reel-item-renderer',
    'ytm-shorts-lockup-view-model', 'ytmusic-responsive-list-item-renderer',
    'ytmusic-two-row-item-renderer'
  ].join(',');
  const CARD_ANCHOR_SELECTOR = [
    'a#thumbnail[href]', 'a.yt-lockup-view-model__content-image[href]',
    'a[href*="/watch?"]', 'a[href*="/shorts/"]', 'a[href*="/live/"]'
  ].join(',');
  const CARD_STYLE_ID = 'ytdlp-card-download-style';
  const CARD_STYLE = `
.ytdlp-card-download-anchor { position: relative !important; }
.ytdlp-card-download-btn {
  position: absolute !important; top: 5px !important; right: 5px !important; z-index: 99999 !important;
  display: grid !important; place-items: center !important;
  width: ${CARD_BUTTON_SIZE}px !important; height: ${CARD_BUTTON_SIZE}px !important;
  min-width: ${CARD_BUTTON_SIZE}px !important; min-height: ${CARD_BUTTON_SIZE}px !important;
  max-width: ${CARD_BUTTON_SIZE}px !important; max-height: ${CARD_BUTTON_SIZE}px !important;
  margin: 0 !important; padding: 0 !important; box-sizing: border-box !important;
  border: 1px solid rgba(255,255,255,.72) !important; border-radius: 50% !important;
  background: rgba(20,20,20,.86) !important; color: #fff !important;
  box-shadow: 0 1px 4px rgba(0,0,0,.35) !important;
  cursor: pointer !important; opacity: .96 !important; pointer-events: auto !important;
  line-height: 1 !important; font: 600 12px/1 Arial,sans-serif !important;
  -webkit-tap-highlight-color: transparent !important;
}
.ytdlp-card-download-btn:hover { background: #c00 !important; transform: scale(1.06); }
.ytdlp-card-download-btn:focus-visible { outline: 2px solid #3d7eff !important; outline-offset: 2px !important; }
.ytdlp-card-download-btn svg { display: block !important; width: 12px !important; height: 12px !important; }
`;

  function extractCardTitle(card, anchor) {
    const selectors = [
      '#video-title', 'a#video-title', '.yt-lockup-metadata-view-model__title',
      '.yt-core-attributed-string', 'h3', '[title]'
    ];
    for (const selector of selectors) {
      const el = card && card.querySelector ? card.querySelector(selector) : null;
      if (!el) continue;
      const value = (el.getAttribute('title') || el.textContent || '').trim();
      if (value && value.length < 300) return value;
    }
    const aria = anchor && (anchor.getAttribute('aria-label') || anchor.getAttribute('title'));
    return aria ? aria.trim().slice(0, 300) : '';
  }

  function findCardThumbnailAnchor(card) {
    if (!card || !card.querySelectorAll) return null;
    const anchors = Array.from(card.querySelectorAll(CARD_ANCHOR_SELECTOR));
    let best = null;
    let bestScore = -1;
    for (const anchor of anchors) {
      if (!extractVideoIdFromUrl(anchor.getAttribute('href') || anchor.href)) continue;
      let score = 0;
      if (anchor.id === 'thumbnail') score += 100;
      if ((anchor.className || '').toString().includes('content-image')) score += 80;
      if (anchor.querySelector('img, yt-image, ytd-thumbnail, .ytThumbnailViewModelImage')) score += 50;
      if (anchor.querySelector('img')) score += 10;
      if (anchor.closest('ytd-thumbnail')) score += 20;
      if (score > bestScore) { best = anchor; bestScore = score; }
    }
    return best;
  }

  function stopCardButtonEvent(event) {
    event.stopPropagation();
    if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
  }

  function installCardStyle() {
    if (document.getElementById(CARD_STYLE_ID)) return;
    const style = document.createElement('style');
    style.id = CARD_STYLE_ID;
    style.textContent = CARD_STYLE;
    (document.head || document.documentElement).appendChild(style);
  }

  function scanVideoCards(onSelect) {
    installCardStyle();
    if (!document.querySelectorAll) return 0;
    const cards = document.querySelectorAll(CARD_SELECTOR);
    let added = 0;
    for (const card of cards) {
      const anchor = findCardThumbnailAnchor(card);
      if (!anchor) continue;
      const id = extractVideoIdFromUrl(anchor.getAttribute('href') || anchor.href);
      if (!id) continue;
      let button = Array.from(anchor.children || []).find((child) => child.classList && child.classList.contains('ytdlp-card-download-btn')) || null;
      if (!button) {
        button = document.createElement('button');
        button.type = 'button';
        button.className = 'ytdlp-card-download-btn';
        button.setAttribute('aria-label', '为此视频生成 yt-dlp 下载命令');
        button.title = '生成此视频的 yt-dlp 下载命令';
        button.appendChild(icon('download', 12));
        // 按钮位于缩略图链接内部，因此必须拦截按下/点击事件，避免触发视频导航。
        for (const type of ['pointerdown', 'mousedown', 'touchstart', 'keydown']) {
          button.addEventListener(type, stopCardButtonEvent, true);
        }
        button.addEventListener('click', (event) => {
          event.preventDefault();
          stopCardButtonEvent(event);
          const videoId = button.dataset.videoId;
          if (videoId) onSelect(videoId, button.dataset.videoTitle || '', button);
        }, true);
        anchor.classList.add('ytdlp-card-download-anchor');
        anchor.appendChild(button);
        added++;
      }
      button.dataset.videoId = id;
      button.dataset.videoTitle = extractCardTitle(card, anchor);
      button.dataset.ytdlpCardButton = '1';
    }
    return added;
  }

  /* ───────────── 界面 ───────────── */

  function init() {
    if (document.getElementById(HOST_ID)) return; // 防止重复注入

    const host = document.createElement('div');
    host.id = HOST_ID;
    host.style.cssText = 'position:fixed;top:0;left:0;width:0;height:0;z-index:2147483000;display:block;';
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

    // 认证、保存路径和限流设置。脚本只保存 Cookie 文件路径，不读取或保存 Cookie 内容。
    function makeOption(value, label) {
      return h('option', { value }, label);
    }

    const authDetails = h('details', { class: 'auth' });
    const authSummary = h('summary', {}, '下载设置：认证 / 限流 / 保存路径');
    const pcModeSelect = h('select', { class: 'auth-select', 'aria-label': '电脑 Cookie 来源' },
      makeOption('none', '不使用 Cookie'),
      makeOption('chrome', 'Chrome 浏览器'),
      makeOption('edge', 'Microsoft Edge'),
      makeOption('firefox', 'Firefox'),
      makeOption('brave', 'Brave'),
      makeOption('vivaldi', 'Vivaldi'),
      makeOption('opera', 'Opera'),
      makeOption('chromium', 'Chromium'),
      makeOption('file', '使用 cookies.txt 文件'));
    const pcCookieInput = h('input', {
      class: 'auth-input', type: 'text', autocomplete: 'off', spellcheck: 'false',
      placeholder: 'D:/snaptube/cookies.txt', 'aria-label': '电脑 cookies.txt 路径'
    });
    const pcCookieWrap = h('div', { class: 'auth-path-wrap' }, pcCookieInput);
    const pcProfileInput = h('input', {
      class: 'auth-input', type: 'text', autocomplete: 'off', spellcheck: 'false',
      placeholder: 'chrome://version → Profile Path（例如 ...\\User Data\\Default）',
      'aria-label': '电脑浏览器 Profile Path'
    });
    const pcProfileWrap = h('div', { class: 'auth-path-wrap' }, pcProfileInput);

    const phoneModeSelect = h('select', { class: 'auth-select', 'aria-label': '手机 Cookie 来源' },
      makeOption('file', '使用 cookies.txt 文件'),
      makeOption('none', '不使用 Cookie'));
    const phoneCookieInput = h('input', {
      class: 'auth-input', type: 'text', autocomplete: 'off', spellcheck: 'false',
      placeholder: '/storage/emulated/0/snaptube/cookies.txt', 'aria-label': '手机 cookies.txt 路径'
    });
    const phoneCookieWrap = h('div', { class: 'auth-path-wrap' }, phoneCookieInput);
    const pcUaInput = h('input', {
      class: 'auth-input', type: 'text', autocomplete: 'off', spellcheck: 'false',
      placeholder: '留空则使用 yt-dlp 默认 UA', 'aria-label': '电脑 User-Agent'
    });
    const phoneUaInput = h('input', {
      class: 'auth-input', type: 'text', autocomplete: 'off', spellcheck: 'false',
      placeholder: '留空则使用 yt-dlp 默认 UA', 'aria-label': '手机 User-Agent'
    });

    const pcSaveInput = h('input', {
      class: 'auth-input', type: 'text', autocomplete: 'off', spellcheck: 'false',
      placeholder: DEFAULT_SAVE_DIRS.pc, 'aria-label': '电脑保存目录'
    });
    const phoneSaveInput = h('input', {
      class: 'auth-input', type: 'text', autocomplete: 'off', spellcheck: 'false',
      placeholder: DEFAULT_SAVE_DIRS.phone, 'aria-label': '手机保存目录'
    });
    const rateSelect = h('select', { class: 'auth-select', 'aria-label': '请求频率策略' },
      makeOption('conservative', '保守（推荐，适合 429）'),
      makeOption('balanced', '平衡（速度稍快）'));
    const archiveCheckbox = h('input', { type: 'checkbox', 'aria-label': '按下载类型记录历史，跳过重复下载' });
    const archiveLabel = h('label', { class: 'auth-inline' }, archiveCheckbox,
      h('span', { text: '记录下载历史：同一下载类型不重复下载' }));
    const potCheckbox = h('input', { type: 'checkbox', 'aria-label': '使用 mweb 客户端和已安装的 PO Token Provider' });
    const potLabel = h('label', { class: 'auth-inline' }, potCheckbox,
      h('span', { text: '使用 mweb + PO Token Provider（必须先在下载设备安装并配置 Provider）' }));

    const authBody = h('div', { class: 'auth-body' },
      h('div', { class: 'auth-section-label', text: 'Cookie 登录认证' }),
      h('div', { class: 'auth-row' }, h('label', { class: 'auth-label' }, '电脑'), pcModeSelect, pcCookieWrap, pcProfileWrap),
      h('div', { class: 'auth-row' }, h('label', { class: 'auth-label' }, '手机'), phoneModeSelect, phoneCookieWrap),
      h('div', { class: 'auth-section-label', text: 'User-Agent（可选）' }),
      h('div', { class: 'auth-row' }, h('label', { class: 'auth-label' }, '电脑'), pcUaInput),
      h('div', { class: 'auth-row' }, h('label', { class: 'auth-label' }, '手机'), phoneUaInput),
      h('div', { class: 'auth-section-label', text: '下载保存目录' }),
      h('div', { class: 'auth-row' }, h('label', { class: 'auth-label' }, '电脑'), pcSaveInput),
      h('div', { class: 'auth-row' }, h('label', { class: 'auth-label' }, '手机'), phoneSaveInput),
      h('div', { class: 'auth-section-label', text: '请求与下载策略' }),
      h('div', { class: 'auth-row' }, h('label', { class: 'auth-label' }, '限流'), rateSelect),
      archiveLabel,
      potLabel,
      h('p', { class: 'auth-hint', text: '浏览器 Cookie 报“could not find cookies database”时，先选择实际登录 YouTube 的浏览器；若浏览器使用自定义目录，在电脑 Profile Path 栏粘贴 chrome://version（Edge 为 edge://version）页面中的 Profile Path。路径应指向 Default 或 Profile 1 文件夹，而不是只指向 User Data 根目录。' }),
      h('p', { class: 'auth-hint', text: '电脑默认保存到 D:\\snaptube，手机默认保存到 /storage/emulated/0/snaptube。电脑命令在 Windows CMD 运行；手机命令在 Termux Bash 运行。手机访问共享存储前，先在 Termux 执行 termux-setup-storage。' }),
      h('p', { class: 'auth-hint', text: 'User-Agent 默认只填当前设备的浏览器值；另一设备留空时由 yt-dlp 使用默认值。保守策略会降低请求频率，但不能解除 YouTube 对公网 IP 的封锁。' }),
      h('p', { class: 'auth-hint auth-warning', text: 'Cookie 等同登录凭据。不要分享 cookies.txt 或 Profile Path 所在目录。若遇到 429，先停止重试，在同一网络完成 YouTube 人机验证，再使用同一网络与对应 Cookie。' }));
    authDetails.append(authSummary, authBody);

    // 多种格式 × 2 个设备：电脑 CMD / 手机 Termux
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
            h('span', { class: 'dev-path', text: normalizeDir(DEFAULT_SAVE_DIRS[dev.key]) })),
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
    const diagPhoneBtn = h('button', { class: 'pill', type: 'button', 'aria-label': '复制手机诊断命令' }, '手机诊断');
    const diagPcBtn = h('button', { class: 'pill', type: 'button', 'aria-label': '复制电脑诊断命令' }, '电脑诊断');

    const panel = h('section', { class: 'panel', id: 'ytdlp-panel', role: 'dialog', 'aria-label': 'yt-dlp 下载命令' },
      h('header', { class: 'head' },
        h('div', { class: 'head-text' },
          h('h2', { text: 'yt-dlp 下载命令' }),
          titleEl,
          urlEl),
        closeBtn),
      authDetails,
      groups.map((g) => g.el),
      h('footer', { class: 'foot' },
        h('p', { class: 'note', text: '点击任意视频缩略图右上角的 21×21px 下载图标，即可为该视频生成命令；手机命令粘贴到 Termux，电脑命令粘贴到 Windows CMD。诊断命令只读取视频格式。' }),
        diagPhoneBtn, diagPcBtn, cmdToggle));

    root.append(panel, fab);
    shadow.append(style, root);
    document.body.appendChild(host);

    /* ── 状态 ── */

    let currentId = null; // 当前播放页 ID
    let selectedVideoId = null; // 面板当前选中的视频，可来自列表卡片
    let selectedVideoTitle = '';
    let selectedSource = 'none';
    let panelAnchorEl = null;
    let lastHref = location.href;
    let isOpen = false;
    let showCmd = store.get(STORE_SHOW_CMD, '0') === '1';
    const auth = {
      pcMode: String(store.get(STORE_AUTH_PC_MODE, IS_MOBILE_DEVICE ? 'none' : detectBrowser()) || (IS_MOBILE_DEVICE ? 'none' : detectBrowser())),
      pcCookiePath: String(store.get(STORE_AUTH_PC_COOKIE, 'D:\\snaptube\\cookies.txt') || ''),
      pcProfilePath: normalizeProfilePath(store.get(STORE_AUTH_PC_PROFILE, '')),
      phoneMode: String(store.get(STORE_AUTH_PHONE_MODE, 'file') || 'file'),
      phoneCookiePath: String(store.get(STORE_AUTH_PHONE_COOKIE, DEFAULT_SAVE_DIRS.phone + '/cookies.txt') || ''),
      pcUserAgent: String(store.get(STORE_UA_PC, IS_MOBILE_DEVICE ? '' : (navigator.userAgent || '')) || ''),
      phoneUserAgent: String(store.get(STORE_UA_PHONE, IS_MOBILE_DEVICE ? (navigator.userAgent || '') : '') || ''),
      pcSaveDir: normalizePcSaveDir(store.get(STORE_SAVE_PC, DEFAULT_SAVE_DIRS.pc)),
      phoneSaveDir: normalizeSaveDir(store.get(STORE_SAVE_PHONE, DEFAULT_SAVE_DIRS.phone), DEFAULT_SAVE_DIRS.phone),
      rateMode: String(store.get(STORE_RATE_MODE, 'conservative') || 'conservative'),
      archiveMode: store.get(STORE_ARCHIVE_MODE, '0') === '1' || store.get(STORE_ARCHIVE_MODE, false) === true,
      potMode: store.get(STORE_POT_MODE, '0') === '1' || store.get(STORE_POT_MODE, false) === true,
    };
    const saveDirs = { pc: auth.pcSaveDir, phone: auth.phoneSaveDir };
    let dockSide = null;
    let dockYRatio = 0.78;
    let dockNeedsApply = false;
    let isDragging = false;
    let dragState = null;
    let suppressClickUntil = 0;
    let autoHideTimer = 0;

    async function copyDiagnosticCommand(dev, btn) {
      if (!selectedVideoId) return;
      const original = btn.textContent;
      const diagnosticPreset = { key: 'diagnostic', args: ['--verbose', '--list-formats'] };
      const diagnosticSettings = Object.assign({}, auth, { archiveMode: false });
      const rawTokens = buildTokens(diagnosticPreset, selectedVideoId, saveDirs[dev.key], dev, diagnosticSettings);
      const shell = dev.key === 'phone' ? 'bash' : 'cmd';
      const ok = await copyText(serializeTokens(rawTokens, shell));
      btn.textContent = ok ? '已复制' : '复制失败';
      setTimeout(() => { btn.textContent = original; }, 1800);
    }

    diagPhoneBtn.addEventListener('click', () => copyDiagnosticCommand(DEVICES[0], diagPhoneBtn));
    diagPcBtn.addEventListener('click', () => copyDiagnosticCommand(DEVICES[1], diagPcBtn));

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
      if (!selectedVideoId) return;
      const vw = window.innerWidth || document.documentElement.clientWidth;
      const vh = window.innerHeight || document.documentElement.clientHeight;
      const narrow = vw <= 560;
      const width = Math.max(1, Math.min(narrow ? vw - 16 : 420, vw - 16));
      const fabRect = panelAnchorEl && panelAnchorEl.isConnected
        ? panelAnchorEl.getBoundingClientRect() : fab.getBoundingClientRect();

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

    function updateAuthUI() {
      pcModeSelect.value = auth.pcMode;
      phoneModeSelect.value = auth.phoneMode;
      pcCookieInput.value = auth.pcCookiePath;
      pcProfileInput.value = auth.pcProfilePath;
      phoneCookieInput.value = auth.phoneCookiePath;
      pcUaInput.value = auth.pcUserAgent;
      phoneUaInput.value = auth.phoneUserAgent;
      pcSaveInput.value = auth.pcSaveDir;
      phoneSaveInput.value = auth.phoneSaveDir;
      rateSelect.value = auth.rateMode;
      archiveCheckbox.checked = !!auth.archiveMode;
      potCheckbox.checked = !!auth.potMode;
      pcCookieWrap.style.display = auth.pcMode === 'file' ? 'block' : 'none';
      pcProfileWrap.style.display = auth.pcMode !== 'file' && auth.pcMode !== 'none' ? 'block' : 'none';
      phoneCookieWrap.style.display = auth.phoneMode === 'file' ? 'block' : 'none';
    }

    function authChanged() {
      if (selectedVideoId) renderCommands();
      if (isOpen) positionPanel();
    }

    pcModeSelect.addEventListener('change', () => {
      auth.pcMode = pcModeSelect.value;
      store.set(STORE_AUTH_PC_MODE, auth.pcMode);
      updateAuthUI();
      authChanged();
    });
    phoneModeSelect.addEventListener('change', () => {
      auth.phoneMode = phoneModeSelect.value;
      store.set(STORE_AUTH_PHONE_MODE, auth.phoneMode);
      updateAuthUI();
      authChanged();
    });
    pcCookieInput.addEventListener('change', () => {
      auth.pcCookiePath = normalizeSaveDir(pcCookieInput.value, 'D:\\snaptube\\cookies.txt');
      store.set(STORE_AUTH_PC_COOKIE, auth.pcCookiePath);
      updateAuthUI();
      authChanged();
    });
    pcProfileInput.addEventListener('change', () => {
      auth.pcProfilePath = normalizeProfilePath(pcProfileInput.value);
      store.set(STORE_AUTH_PC_PROFILE, auth.pcProfilePath);
      updateAuthUI();
      authChanged();
    });
    phoneCookieInput.addEventListener('change', () => {
      auth.phoneCookiePath = normalizeSaveDir(phoneCookieInput.value, DEFAULT_SAVE_DIRS.phone + '/cookies.txt');
      store.set(STORE_AUTH_PHONE_COOKIE, auth.phoneCookiePath);
      updateAuthUI();
      authChanged();
    });
    pcUaInput.addEventListener('change', () => {
      auth.pcUserAgent = pcUaInput.value.trim();
      store.set(STORE_UA_PC, auth.pcUserAgent);
      updateAuthUI();
      authChanged();
    });
    phoneUaInput.addEventListener('change', () => {
      auth.phoneUserAgent = phoneUaInput.value.trim();
      store.set(STORE_UA_PHONE, auth.phoneUserAgent);
      updateAuthUI();
      authChanged();
    });
    pcSaveInput.addEventListener('change', () => {
      auth.pcSaveDir = normalizePcSaveDir(pcSaveInput.value);
      saveDirs.pc = auth.pcSaveDir;
      store.set(STORE_SAVE_PC, auth.pcSaveDir);
      updateAuthUI();
      authChanged();
    });
    phoneSaveInput.addEventListener('change', () => {
      auth.phoneSaveDir = normalizeSaveDir(phoneSaveInput.value, DEFAULT_SAVE_DIRS.phone);
      saveDirs.phone = auth.phoneSaveDir;
      store.set(STORE_SAVE_PHONE, auth.phoneSaveDir);
      updateAuthUI();
      authChanged();
    });
    rateSelect.addEventListener('change', () => {
      auth.rateMode = rateSelect.value === 'balanced' ? 'balanced' : 'conservative';
      store.set(STORE_RATE_MODE, auth.rateMode);
      authChanged();
    });
    archiveCheckbox.addEventListener('change', () => {
      auth.archiveMode = !!archiveCheckbox.checked;
      store.set(STORE_ARCHIVE_MODE, auth.archiveMode ? '1' : '0');
      authChanged();
    });
    potCheckbox.addEventListener('change', () => {
      auth.potMode = !!potCheckbox.checked;
      store.set(STORE_POT_MODE, auth.potMode ? '1' : '0');
      authChanged();
    });
    authDetails.addEventListener('toggle', () => {
      if (isOpen) setTimeout(positionPanel, 0);
    });
    updateAuthUI();

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
      if (!selectedVideoId) return;
      urlEl.textContent = canonicalUrl(selectedVideoId).replace(/^https:\/\/www\./, '');
      for (const t of targets) {
        const dir = saveDirs[t.dev.key];
        const rawTokens = buildTokens(t.preset, selectedVideoId, dir, t.dev, auth);
        const shell = t.dev.key === 'phone' ? 'bash' : 'cmd';
        const tokens = rawTokens.map((tok, i) => (i === 0 || String(tok).startsWith('-'))
          ? String(tok) : quoteArg(tok, shell));
        t.command = serializeTokens(rawTokens, shell);
        t.btn.querySelector('.dev-path').textContent = dir;
        t.term.textContent = '';
        tokens.forEach((tok, i) => {
          if (i > 0) t.term.append(' ');
          t.term.append(h('span', { class: tokenClass(tok, i, tokens), text: tok }));
        });
        resetTarget(t);
      }
    }

    function renderTitle() {
      const id = selectedVideoId;
      const fallbackTitle = selectedVideoTitle || (selectedSource === 'page' ? pageTitle() : '');
      titleEl.textContent = fallbackTitle || '正在读取标题…';
      fetchTitle(id).then((t) => {
        if (id !== selectedVideoId) return;
        titleEl.textContent = fallbackTitle || t || '未能读取标题（不影响下载）';
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

    function openPanel() {
      if (!selectedVideoId && currentId) {
        selectedVideoId = currentId;
        selectedVideoTitle = pageTitle();
        selectedSource = 'page';
      }
      if (!selectedVideoId) return;
      if (!panelAnchorEl) revealFab();
      host.style.display = 'block';
      isOpen = true;
      syncTheme();
      renderCommands();
      renderTitle();
      positionPanel();
      panel.classList.add('open');
      fab.setAttribute('aria-expanded', 'true');
    }

    function openPanelForCard(videoId, title, anchorButton) {
      if (!videoId || !/^[\w-]{11}$/.test(videoId)) return;
      selectedVideoId = videoId;
      selectedVideoTitle = title || '';
      selectedSource = 'card';
      panelAnchorEl = anchorButton || null;
      host.style.display = 'block';
      if (isOpen) {
        syncTheme();
        renderCommands();
        renderTitle();
        positionPanel();
        return;
      }
      openPanel();
    }

    function closePanel() {
      if (!isOpen) return;
      isOpen = false;
      panel.classList.remove('open');
      fab.setAttribute('aria-expanded', 'false');
      panelAnchorEl = null;
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

    // YouTube 是单页应用：同步播放页 ID，并保持列表卡片的选中视频上下文。
    function sync() {
      if (!host.isConnected && document.body) document.body.appendChild(host);
      const href = location.href;
      const navigated = href !== lastHref;
      if (navigated) lastHref = href;
      const id = getVideoId();
      if (id !== currentId) {
        currentId = id;
        if (id) {
          selectedVideoId = id;
          selectedVideoTitle = '';
          selectedSource = 'page';
          panelAnchorEl = null;
          syncTheme();
          if (isOpen) { renderCommands(); renderTitle(); }
        } else if (navigated) {
          selectedVideoId = null;
          selectedVideoTitle = '';
          selectedSource = 'none';
          panelAnchorEl = null;
          closePanel();
        }
      } else if (navigated && !id) {
        selectedVideoId = null;
        selectedVideoTitle = '';
        selectedSource = 'none';
        panelAnchorEl = null;
        closePanel();
      }
      const fullscreen = document.fullscreenElement || document.webkitFullscreenElement;
      const display = fullscreen ? 'none' : 'block';
      if (host.style.display !== display) host.style.display = display;
      // 播放页保留原悬浮入口；列表页隐藏悬浮入口，只显示每张视频卡片上的小按钮。
      fab.style.display = currentId ? 'inline-flex' : 'none';
      if (display === 'block' && dockNeedsApply && currentId) {
        applyDockPosition(true);
        dockNeedsApply = false;
      }
    }

    /* ── 列表卡片注入：动态加载、搜索结果、首页、订阅、播放列表与 Shorts ── */

    let cardScanQueued = false;
    function scheduleCardScan() {
      if (cardScanQueued) return;
      cardScanQueued = true;
      // 约 120ms 节流，避免 YouTube 连续更新 DOM 时反复全页扫描。
      setTimeout(() => {
        cardScanQueued = false;
        scanVideoCards((videoId, title, button) => openPanelForCard(videoId, title, button));
      }, 120);
    }

    scheduleCardScan();
    const cardObserver = new MutationObserver((records) => {
      // 忽略纯属性变化；YouTube 新增卡片/缩略图时再进行节流扫描。
      if (records.some((record) => record.addedNodes && record.addedNodes.length)) scheduleCardScan();
    });
    cardObserver.observe(document.documentElement, { childList: true, subtree: true });

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
      if (!path.includes(host)) closePanel();
    }, true);

    window.addEventListener('resize', handleViewportChange, { passive: true });
    window.addEventListener('orientationchange', handleViewportChange, { passive: true });
    if (window.visualViewport) window.visualViewport.addEventListener('resize', handleViewportChange, { passive: true });

    for (const ev of ['yt-navigate-finish', 'yt-page-data-updated', 'popstate']) {
      window.addEventListener(ev, () => { sync(); scheduleCardScan(); }, true);
    }
    document.addEventListener('fullscreenchange', sync);
    document.addEventListener('webkitfullscreenchange', sync);
    new MutationObserver(syncTheme).observe(document.documentElement, { attributes: true, attributeFilter: ['dark'] });
    setInterval(sync, 500);
    // 兜底处理 YouTube 复用现有 DOM 节点但只更新 href 的情况。
    setInterval(scheduleCardScan, 2500);
    sync();
  }

  if (document.body) init();
  else document.addEventListener('DOMContentLoaded', init, { once: true });
})();
