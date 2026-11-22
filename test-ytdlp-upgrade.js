const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(__dirname + '/youtube-ytdlp-command.user.js', 'utf8');

function extract(name, nextMarker) {
  const start = src.indexOf('  function ' + name + '(');
  if (start < 0) throw new Error('Missing helper: ' + name);
  const end = nextMarker ? src.indexOf(nextMarker, start) : -1;
  if (end < 0) throw new Error('Missing end marker for ' + name);
  return src.slice(start, end).trim();
}

const helpers = [
  extract('quoteArg', '\n  function serializePlainTokens'),
  extract('serializePlainTokens', '\n  // CMD 会展开'),
  extract('encodeUtf16LeBase64', '\n  function serializeTokens'),
  extract('serializeTokens', '\n  function getShell'),
  extract('getVideoIdFromUrl', '\n  // 当前页面地址'),
  extract('normalizeDir', '\n  function getVideoIdFromUrl'),
].join('\n\n');

const context = { URL, location: { href: 'https://www.youtube.com/' }, btoa };
vm.createContext(context);
vm.runInContext(helpers + '\nthis.api = { quoteArg, serializeTokens, getVideoIdFromUrl, normalizeDir };', context);
const api = context.api;

const cases = [
  ['watch', 'https://www.youtube.com/watch?v=abcdefghijk&list=PL123', 'abcdefghijk'],
  ['shorts', 'https://www.youtube.com/shorts/abcdefghijk?feature=share', 'abcdefghijk'],
  ['live', 'https://www.youtube.com/live/abcdefghijk', 'abcdefghijk'],
  ['embed', 'https://www.youtube.com/embed/abcdefghijk', 'abcdefghijk'],
  ['youtu.be', 'https://youtu.be/abcdefghijk?t=12', 'abcdefghijk'],
  ['music', 'https://music.youtube.com/watch?v=abcdefghijk', 'abcdefghijk'],
  ['nocookie', 'https://www.youtube-nocookie.com/embed/abcdefghijk', 'abcdefghijk'],
  ['reject lookalike domain', 'https://fakeyoutube.com/watch?v=abcdefghijk', null],
  ['reject malformed id', 'https://www.youtube.com/watch?v=short', null],
];
for (const [label, url, expected] of cases) {
  const got = api.getVideoIdFromUrl(url);
  if (got !== expected) throw new Error(`${label}: expected ${expected}, got ${got}`);
}

const bash = api.quoteArg("a'b c", 'bash');
if (bash !== "'a'\\''b c'") throw new Error('Bash quote mismatch: ' + bash);
const ps = api.quoteArg("C:\\folder\\O'Brien", 'powershell');
if (ps !== "'C:\\folder\\O''Brien'") throw new Error('PowerShell quote mismatch: ' + ps);
const cmd = api.serializeTokens(['yt-dlp', '-o', '%(title)s [%(id)s].%(ext)s', '-P', 'D:\\视频 目录'], 'cmd');
if (!cmd.startsWith('powershell.exe -NoLogo -NoProfile -EncodedCommand ')) throw new Error('CMD wrapper missing');
const encoded = cmd.split(' ').at(-1);
const decoded = Buffer.from(encoded, 'base64').toString('utf16le');
if (!decoded.includes("'%(title)s [%(id)s].%(ext)s'")) throw new Error('CMD wrapper did not preserve yt-dlp output template');
if (!decoded.includes("'D:\\视频 目录'")) throw new Error('CMD wrapper did not preserve Unicode path');
if (api.normalizeDir('D:\\snaptube\\') !== 'D:\\snaptube') throw new Error('Windows path normalization failed');
if (api.normalizeDir('D:\\bad"path') !== '') throw new Error('Invalid quote should be rejected');

const presetBlock = src.slice(src.indexOf('  const PRESETS = ['), src.indexOf('\n  const HOST_ID'));
for (const cap of [2160, 1080, 720]) {
  if (!presetBlock.includes(`height<=${cap}`)) throw new Error(`Missing real height cap ${cap}`);
}
if (!src.includes('const THUMB_BADGE_SIZE = 30')) throw new Error('Thumbnail badge is not 30px (~8mm)');
if (!src.includes('top: 6px; left: 6px; right: auto;')) throw new Error('Thumbnail badge CSS is not anchored top-left');
if (!src.includes('top:6px!important;left:6px!important;right:auto!important;')) throw new Error('Thumbnail badge inline position is not anchored top-left');
if (!src.includes("event.preventDefault();\n        event.stopPropagation();")) throw new Error('Thumbnail click navigation prevention missing');
if (!src.includes('background: transparent; background-color: transparent;')) throw new Error('Thumbnail button background is not transparent');
if (!src.includes('button:hover, button:active, button:focus-visible { background: transparent; background-color: transparent; }')) throw new Error('Thumbnail button interaction states are not transparent');

console.log('PASS: URL parsing (9 cases)');
console.log('PASS: Bash / PowerShell quoting');
console.log('PASS: CMD EncodedCommand wrapper preserves yt-dlp templates and Unicode paths');
console.log('PASS: Windows path normalization and invalid-path rejection');
console.log('PASS: 4K / 1080p / 720p format caps');
console.log('PASS: 30px thumbnail badge and no-navigation click handling');
console.log('PASS: thumbnail badge positioned top-left in both positioning layers');
console.log('PASS: transparent thumbnail button background in all interaction states');
