const PROTOCOLS = [
  { key: 'vlpt', name: 'VLESS TCP Reality Vision-Enc', group: 'Xray', help: 'TCP + Reality + Vision-Enc；不需要域名证书' },
  { key: 'xhpt', name: 'VLESS XHTTP Reality Vision-Enc', group: 'Xray', help: 'XHTTP + Reality；不需要域名证书' },
  { key: 'vxpt', name: 'VLESS XHTTP Vision-Enc', group: 'Xray', help: 'XHTTP Vision-Enc；支持 CDN/Argo 固定隧道' },
  { key: 'vwpt', name: 'VLESS WebSocket Vision-Enc', group: 'Xray', help: 'WebSocket Vision-Enc；支持 CDN/Argo' },
  { key: 'xupt', name: 'VLESS XHTTP TLS-UDP', group: 'Xray', help: 'XHTTP + TLS + HTTP/3 UDP' },
  { key: 'xcpt', name: 'VLESS XHTTP TLS-TCP/UDP', group: 'Xray', help: 'XHTTP + TLS；支持 TCP/UDP-CDN 方案' },
  { key: 'tupt', name: 'TUIC', group: 'Sing-box', help: 'TUIC 入站；默认自签 TLS，可启用域名/IP 证书' },
  { key: 'anpt', name: 'AnyTLS', group: 'Sing-box', help: 'AnyTLS 入站；默认自签 TLS，可启用域名/IP 证书' },
  { key: 'nvpt', name: 'NaiveProxy', group: 'Sing-box', help: '需要先开启域名/IP 证书 TLS' },
  { key: 'arpt', name: 'Any-reality', group: 'Sing-box', help: 'AnyTLS + Reality；不需要域名证书' },
  { key: 'sspt', name: 'Shadowsocks 2022', group: 'Sing-box', help: 'SS2022 入站' },
  { key: 'snpt', name: 'Snell v6', group: 'Sing-box', help: 'Snell v6 入站' },
  { key: 'hypt', name: 'Hysteria2', group: '自动选择内核', help: '内核由官方脚本根据当前已选协议自动分配' },
  { key: 'vmpt', name: 'VMess WebSocket', group: '自动选择内核', help: '支持 CDN/Argo' },
  { key: 'sopt', name: 'SOCKS5', group: '自动选择内核', help: '内核由官方脚本根据当前已选协议自动分配' },
];
const PROTOCOL_ORDER = ['sopt', 'vmpt', 'vlpt', 'xhpt', 'vxpt', 'vwpt', 'xupt', 'xcpt', 'hypt', 'tupt', 'nvpt', 'anpt', 'arpt', 'sspt', 'snpt'];
const OPTION_ORDER = ['warp', 'ippz', 'uuid', 'reym', 'cfip', 'alns', 'hyjpt', 'cdnym', 'name', 'oap', 'sub', 'subid', 'subpt'];
const SHORTCUTS = ['list', 'del', 'upx', 'ups', 'upa', 'res', 'rep'];
const WARP_OPTIONS = [
  ['', '默认：服务器本地 IP 出站'],
  ['s', '1：Sing-box 使用 WARP IPv4 + IPv6；Xray 本地 IP'],
  ['s4', '2：Sing-box 使用 WARP IPv4；Xray 本地 IP'],
  ['s6', '3：Sing-box 使用 WARP IPv6；Xray 本地 IP'],
  ['x', '4：Sing-box 本地 IP；Xray 使用 WARP IPv4 + IPv6'],
  ['x4', '5：Sing-box 本地 IP；Xray 使用 WARP IPv4'],
  ['x6', '6：Sing-box 本地 IP；Xray 使用 WARP IPv6'],
  ['s4x4', '7：Sing-box + Xray 使用 WARP IPv4'],
  ['s4x6', '8：Sing-box WARP IPv4；Xray WARP IPv6'],
  ['s6x4', '9：Sing-box WARP IPv6；Xray WARP IPv4'],
  ['s6x6', '10：Sing-box + Xray 使用 WARP IPv6'],
  ['sx4', '11：Sing-box WARP 双栈；Xray WARP IPv4'],
  ['sx6', '12：Sing-box WARP 双栈；Xray WARP IPv6'],
  ['s4x', '13：Sing-box WARP IPv4；Xray WARP 双栈'],
  ['s6x', '14：Sing-box WARP IPv6；Xray WARP 双栈'],
  ['sx', '15：Sing-box + Xray 均使用 WARP IPv4 + IPv6'],
];
const DOMAIN_RE = /^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[A-Za-z]{2,63}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SAFE_NAME_RE = /^[\p{L}\p{N}._-]{1,32}$/u;
const SAFE_SUBID_RE = /^[A-Za-z0-9._-]{1,64}$/;
const clean = value => String(value ?? '').trim();
function validPort(value) {
  if (value === '') return true;
  if (!/^[1-9]\d{0,4}$/.test(value)) return false;
  const n = Number(value);
  return Number.isSafeInteger(n) && n >= 1 && n <= 65535;
}
function parsePortRanges(value) {
  const raw = clean(value);
  if (!raw) return { ok: true, ranges: [] };
  const ranges = [];
  for (const token of raw.split(/\s+/)) {
    const match = token.match(/^([1-9]\d{0,4})(?::([1-9]\d{0,4}))?$/);
    if (!match) return { ok: false, ranges: [] };
    const start = Number(match[1]);
    const end = match[2] === undefined ? start : Number(match[2]);
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end > 65535 || start > end) return { ok: false, ranges: [] };
    ranges.push([start, end]);
  }
  for (let i = 0; i < ranges.length; i++) for (let j = i + 1; j < ranges.length; j++) {
    if (ranges[i][0] <= ranges[j][1] && ranges[j][0] <= ranges[i][1]) return { ok: false, ranges: [], overlap: true };
  }
  return { ok: true, ranges };
}
const isDomain = value => DOMAIN_RE.test(clean(value));

function validateConfig(config) {
  const errors = [];
  const protocols = config.protocols ?? {};
  const options = config.options ?? {};
  const argo = config.argo ?? {};
  const selected = PROTOCOL_ORDER.filter(key => Boolean(protocols[key]?.enabled));
  if (!selected.length) errors.push('请至少勾选一种代理协议。');
  const occupied = new Map();
  for (const key of selected) {
    const port = clean(protocols[key]?.port);
    if (!validPort(port)) { errors.push(`${key.toUpperCase()} 端口必须是 1–65535 的整数，或留空自动分配。`); continue; }
    if (port) {
      if (occupied.has(port)) errors.push(`端口 ${port} 被 ${occupied.get(port)} 和 ${key.toUpperCase()} 重复使用，请改成不同端口。`);
      else occupied.set(port, key.toUpperCase());
    }
  }
  const uuid = clean(options.uuid);
  if (uuid && !UUID_RE.test(uuid)) errors.push('UUID 格式不正确，请使用标准 UUID，或留空让服务器自动生成。');
  const realitySelected = ['vlpt', 'xhpt', 'arpt'].some(key => selected.includes(key));
  const reym = clean(options.reym);
  if (realitySelected && reym && !isDomain(reym)) errors.push('Reality 域名必须填写有效域名，例如 apple.com。');
  if (!realitySelected && reym) errors.push('只有选择 VLESS Reality、XHTTP Reality 或 Any-reality 时才需要填写 Reality 域名。');
  const cfip = clean(options.cfip);
  if (cfip) {
    if (!['vmpt', 'vxpt', 'vwpt', 'xcpt'].some(key => selected.includes(key))) errors.push('CDN 优选 IP 域名仅在选择 VMess WS、VLESS XHTTP/WS-Enc 或 XHTTP TLS-TCP/UDP 时使用。');
    const domains = cfip.split(/\s+/);
    if (domains.length > 2 || domains.some(domain => !isDomain(domain))) errors.push('CDN 优选 IP 域名最多填写两个有效域名，使用空格分隔。');
  }
  const alns = clean(options.alns);
  if (!['', 'y'].includes(alns)) errors.push('域名/IP 证书 TLS 只能选择默认关闭或开启。');
  if (selected.includes('nvpt') && alns !== 'y') errors.push('NaiveProxy 必须先开启「域名/IP 证书 TLS」。');
  const cdnym = clean(options.cdnym);
  if (cdnym) {
    if (!['vmpt', 'vxpt', 'vwpt'].some(key => selected.includes(key))) errors.push('CF 回源域名仅适用于 VMess WS、VLESS XHTTP-Enc 或 VLESS WS-Enc。');
    if (!isDomain(cdnym)) errors.push('CF 解析 IP 的域名格式不正确，例如 cdn.example.com。');
  }
  const hyjpt = clean(options.hyjpt);
  if (hyjpt) {
    if (!selected.includes('hypt')) errors.push('Hysteria2 端口跳跃仅在启用 Hysteria2 时可填写。');
    const parsed = parsePortRanges(hyjpt);
    if (!parsed.ok) errors.push(parsed.overlap ? 'Hysteria2 端口跳跃范围不能互相重叠。' : 'Hysteria2 端口跳跃格式错误，请使用例如「123:456 789」。');
  }
  const warp = clean(options.warp);
  if (!WARP_OPTIONS.some(([value]) => value === warp)) errors.push('WARP 出站组合无效。');
  const ippz = clean(options.ippz);
  if (!['', '4', '6'].includes(ippz)) errors.push('IP 配置导出只能选择自动、IPv4 或 IPv6。');
  if (!['', 'y'].includes(clean(options.oap))) errors.push('开放所有端口选项无效。');
  const name = clean(options.name);
  if (name && !SAFE_NAME_RE.test(name)) errors.push('节点名称前缀最多 32 个字符，只允许中文、字母、数字、点、下划线和短横线。');
  const sub = clean(options.sub);
  if (!['', 'y'].includes(sub)) errors.push('订阅开关值无效。');
  const subid = clean(options.subid);
  const subpt = clean(options.subpt);
  if (sub !== 'y' && (subid || subpt)) errors.push('请先启用订阅链接，再填写订阅密码或端口。');
  if (subid && !SAFE_SUBID_RE.test(subid)) errors.push('订阅密码只能使用 1–64 位英文字母、数字、点、下划线或短横线。');
  if (sub === 'y' && !validPort(subpt)) errors.push('订阅端口必须是 1–65535 的整数，或留空自动分配。');
  if (subpt) {
    if (occupied.has(subpt)) errors.push(`订阅端口 ${subpt} 与 ${occupied.get(subpt)} 冲突，请更换端口。`);
    else occupied.set(subpt, '订阅服务');
  }
  const argoProtocol = clean(argo.protocol);
  if (!['', 'vmpt', 'vwpt', 'vxpt'].includes(argoProtocol)) errors.push('Argo 主协议选择无效。');
  if (argoProtocol && !selected.includes(argoProtocol)) errors.push(`启用 Argo 时必须同时勾选对应协议 ${argoProtocol.toUpperCase()}。`);
  const agn = clean(argo.domain);
  const agk = clean(argo.token);
  const agqc = clean(argo.mode);
  if (!['', 'y'].includes(agqc)) errors.push('Argo 传输模式只能选择 TCP 或 UDP。');
  if (!argoProtocol && (agn || agk || agqc)) errors.push('请先选择 Argo 主协议，再填写隧道模式、域名或 Token。');
  if (Boolean(agn) !== Boolean(agk)) errors.push('固定 Argo 隧道必须同时填写 CF 域名和 Token；两项都留空则使用临时隧道。');
  if (agn && !isDomain(agn)) errors.push('固定隧道 CF 域名格式不正确，例如 tunnel.example.com。');
  if (agk && !/^eyJ[A-Za-z0-9._~+\/=-]+$/.test(agk)) errors.push('固定隧道 Token 格式不正确，请粘贴完整的 eyJ... Token。');
  if (argoProtocol === 'vxpt' && (!agn || !agk)) errors.push('VLESS XHTTP-Enc 的 Argo 模式仅支持固定隧道，必须填写 CF 域名和 Token。');
  return errors;
}

function collectVariables(config) {
  const variables = {};
  const protocols = config.protocols ?? {};
  const options = config.options ?? {};
  const argo = config.argo ?? {};
  for (const key of PROTOCOL_ORDER) if (protocols[key]?.enabled) variables[key] = clean(protocols[key]?.port);
  for (const key of OPTION_ORDER) {
    const value = clean(options[key]);
    if (value !== '') variables[key] = value;
  }
  if (clean(argo.protocol)) {
    variables.argo = clean(argo.protocol);
    variables.agqc = clean(argo.mode); // 空字符串代表默认 TCP，仍需传递
    if (clean(argo.domain)) variables.agn = clean(argo.domain);
    if (clean(argo.token)) variables.agk = clean(argo.token);
  }
  return variables;
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function buildCommand(config, commandType = 'curl', shortcut = '') {
  if (!['curl', 'wget'].includes(commandType)) throw new Error('命令类型只能是 curl 或 wget。');
  if (shortcut && !SHORTCUTS.includes(shortcut)) throw new Error('快捷命令无效。');
  let variables = {};
  if (shortcut === 'rep' || !shortcut) {
    const errors = validateConfig(config);
    if (errors.length) throw new Error(errors[0]);
    variables = collectVariables(config);
  } else if (shortcut === 'list') {
    const ippz = clean(config.options?.ippz);
    if (ippz === '4' || ippz === '6') variables.ippz = ippz;
  }
  const assignments = Object.entries(variables).map(([key, value]) => `${key}=${shellQuote(value)}`).join(' ');
  const base = commandType === 'curl'
    ? 'bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/argosbx/main/argosbx.sh)'
    : 'bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/argosbx/main/argosbx.sh)';
  return `${assignments ? assignments + ' ' : ''}${base}${shortcut ? ' ' + shortcut : ''}`;
}

function readShellWord(source, start) {
  let i = start;
  let value = '';
  let state = 'bare';
  while (i < source.length) {
    const ch = source[i];
    if (state === 'bare') {
      if (/\s/.test(ch)) break;
      if (ch === "'") state = 'single';
      else if (ch === '"') state = 'double';
      else if (ch === '\\') { i++; if (i < source.length) value += source[i]; }
      else value += ch;
    } else if (state === 'single') {
      if (ch === "'") state = 'bare';
      else value += ch;
    } else {
      if (ch === '"') state = 'bare';
      else if (ch === '\\' && i + 1 < source.length) { i++; value += source[i]; }
      else value += ch;
    }
    i++;
  }
  if (state !== 'bare') throw new Error('命令中的引号没有闭合。');
  return { value, index: i };
}

function parseCommand(command) {
  const source = String(command ?? '').trim();
  const variables = {};
  let i = 0;
  while (i < source.length) {
    while (i < source.length && /\s/.test(source[i])) i++;
    if (i >= source.length) break;
    const word = readShellWord(source, i);
    const eq = word.value.indexOf('=');
    if (eq <= 0 || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(word.value.slice(0, eq))) break;
    variables[word.value.slice(0, eq)] = word.value.slice(eq + 1);
    i = word.index;
  }
  const allowed = new Set([...PROTOCOL_ORDER, ...OPTION_ORDER, 'argo', 'agqc', 'agn', 'agk']);
  for (const key of Object.keys(variables)) if (!allowed.has(key)) delete variables[key];
  const shortcutMatch = source.match(/\)\s+(list|del|upx|ups|upa|res|rep)\s*$/);
  return {
    variables,
    commandType: /wget\s+-qO-/.test(source) ? 'wget' : 'curl',
    shortcut: shortcutMatch ? shortcutMatch[1] : '',
  };
}

function configFromVariables(variables) {
  const protocols = {};
  for (const key of PROTOCOL_ORDER) protocols[key] = { enabled: Object.prototype.hasOwnProperty.call(variables, key), port: variables[key] ?? '' };
  const options = {};
  for (const key of OPTION_ORDER) options[key] = variables[key] ?? '';
  const argo = { protocol: variables.argo ?? '', mode: variables.agqc ?? '', domain: variables.agn ?? '', token: variables.agk ?? '' };
  return { protocols, options, argo };
}

function summarizeConfig(config) {
  const selected = PROTOCOLS.filter(item => config.protocols?.[item.key]?.enabled);
  const ports = selected.map(item => `${item.name}: ${clean(config.protocols[item.key]?.port) || '自动分配'}`);
  return { selected, ports };
}

function generateUuid(cryptoObject = globalThis.crypto) {
  if (cryptoObject?.randomUUID) return cryptoObject.randomUUID();
  if (!cryptoObject?.getRandomValues) throw new Error('当前环境不支持安全随机数，请在 HTTPS 页面或现代浏览器中打开。');
  const bytes = new Uint8Array(16);
  cryptoObject.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

const ArgoGenerator = { PROTOCOLS, PROTOCOL_ORDER, OPTION_ORDER, SHORTCUTS, WARP_OPTIONS, validateConfig, collectVariables, shellQuote, buildCommand, parseCommand, configFromVariables, summarizeConfig, generateUuid };
if (typeof module !== 'undefined' && module.exports) module.exports = ArgoGenerator;
else if (typeof window !== 'undefined') window.ArgoGenerator = ArgoGenerator;
