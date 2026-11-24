'use strict';
const assert = require('node:assert/strict');
const G = require('../generator.js');

function emptyConfig() {
  const protocols = {};
  for (const key of G.PROTOCOL_ORDER) protocols[key] = { enabled: false, port: '' };
  const options = { warp: '', ippz: '', uuid: '', reym: '', cfip: '', alns: '', hyjpt: '', cdnym: '', name: '', oap: '', sub: '', subid: '', subpt: '' };
  return { protocols, options, argo: { protocol: '', mode: '', domain: '', token: '' } };
}
function enable(cfg, key, port = '') { cfg.protocols[key] = { enabled: true, port }; }

assert.equal(G.PROTOCOL_ORDER.length, 15, 'all 15 protocol switches must exist');
assert.deepEqual(G.PROTOCOLS.map(x => x.key), ['vlpt','xhpt','vxpt','vwpt','xupt','xcpt','tupt','anpt','nvpt','arpt','sspt','snpt','hypt','vmpt','sopt']);
assert.equal(G.WARP_OPTIONS.length, 16, 'default plus all 15 WARP combinations must exist');

// Empty ports are intentionally emitted as KEY='' because the upstream script detects protocol selection by variable presence.
{
  const cfg = emptyConfig(); enable(cfg, 'vlpt');
  assert.deepEqual(G.validateConfig(cfg), []);
  const command = G.buildCommand(cfg, 'curl');
  assert.match(command, /^sopt=|^vmpt=|^vlpt=''/);
  assert.match(command, /vlpt='' bash <\(curl -Ls https:\/\/raw\.githubusercontent\.com\/yonggekkk\/argosbx\/main\/argosbx\.sh\)$/);
}

// Port range, duplicate port and invalid port checks.
{
  const cfg = emptyConfig(); enable(cfg, 'vlpt', '443'); enable(cfg, 'vmpt', '443');
  assert.match(G.validateConfig(cfg).join(' '), /端口 443/);
  cfg.protocols.vmpt.port = '70000';
  assert.match(G.validateConfig(cfg).join(' '), /1–65535/);
  cfg.protocols.vmpt.port = '0443';
  assert.match(G.validateConfig(cfg).join(' '), /1–65535/);
}

// NaiveProxy is unavailable until domain/IP certificate TLS is enabled.
{
  const cfg = emptyConfig(); enable(cfg, 'nvpt');
  assert.match(G.validateConfig(cfg).join(' '), /NaiveProxy 必须/);
  cfg.options.alns = 'y';
  assert.deepEqual(G.validateConfig(cfg), []);
}

// Reality, CDN and Hysteria2 conditional inputs.
{
  const cfg = emptyConfig(); enable(cfg, 'xhpt'); cfg.options.reym = 'bad_domain';
  assert.match(G.validateConfig(cfg).join(' '), /Reality 域名/);
  cfg.options.reym = 'apple.com'; cfg.options.cfip = 'cdn.example.com other.example.net';
  assert.match(G.validateConfig(cfg).join(' '), /CDN 优选 IP 域名仅/);
  cfg.options.cfip = '';
  enable(cfg, 'hypt'); cfg.options.hyjpt = '123:456 789';
  assert.deepEqual(G.validateConfig(cfg), []);
  cfg.options.hyjpt = '123:456 400:500';
  assert.match(G.validateConfig(cfg).join(' '), /不能互相重叠/);
}

// Argo temporary tunnel, fixed tunnel and XHTTP fixed-only rule.
{
  const cfg = emptyConfig(); enable(cfg, 'vwpt');
  cfg.argo = { protocol: 'vwpt', mode: '', domain: '', token: '' };
  assert.deepEqual(G.validateConfig(cfg), []);
  const temporaryArgoCommand = G.buildCommand(cfg, 'curl');
  assert.match(temporaryArgoCommand, /argo='vwpt' agqc=''/, 'default TCP mode must be passed explicitly');
  assert.doesNotMatch(temporaryArgoCommand, /\bagn=|\bagk=/, 'temporary tunnel must not carry fixed tunnel credentials');
  cfg.argo.domain = 'tunnel.example.com';
  assert.match(G.validateConfig(cfg).join(' '), /必须同时填写/);
  cfg.argo.token = 'eyJabc+/==';
  assert.deepEqual(G.validateConfig(cfg), []);
  cfg.argo.protocol = 'vxpt'; enable(cfg, 'vxpt');
  cfg.protocols.vwpt.enabled = false;
  cfg.argo.domain = ''; cfg.argo.token = '';
  assert.match(G.validateConfig(cfg).join(' '), /仅支持固定隧道/);
}

// Subscription settings and listener port collision.
{
  const cfg = emptyConfig(); enable(cfg, 'sspt', '8388');
  cfg.options.sub = 'y'; cfg.options.subpt = '8388';
  assert.match(G.validateConfig(cfg).join(' '), /订阅端口 8388/);
  cfg.options.subpt = '18080'; cfg.options.subid = 'private_01';
  assert.deepEqual(G.validateConfig(cfg), []);
}

// Shell quoting must preserve spaces, Unicode and single quotes without command injection.
{
  const cfg = emptyConfig(); enable(cfg, 'vmpt');
  cfg.options.name = "HK'01";
  assert.match(G.validateConfig(cfg).join(' '), /节点名称前缀/);
  cfg.options.name = '香港-01';
  const command = G.buildCommand(cfg, 'wget');
  assert.match(command, /bash <\(wget -qO-/);
  const parsed = G.parseCommand(command);
  assert.equal(parsed.commandType, 'wget');
  assert.equal(parsed.variables.vmpt, '');
  assert.equal(parsed.variables.name, '香港-01');
}

// Round-trip values that contain spaces and shell quote characters (accepted only where appropriate).
{
  const cfg = emptyConfig(); enable(cfg, 'vmpt'); cfg.options.cdnym = 'origin.example.com';
  cfg.options.name = '东京-02'; cfg.options.warp = 's4x6'; cfg.options.ippz = '6';
  cfg.argo = { protocol: 'vmpt', mode: 'y', domain: 'argo.example.com', token: 'eyJ' + 'b'.repeat(60) + '==' };
  const command = G.buildCommand(cfg, 'curl');
  const parsed = G.parseCommand(command);
  const restored = G.configFromVariables(parsed.variables);
  assert.equal(restored.protocols.vmpt.enabled, true);
  assert.equal(restored.options.name, '东京-02');
  assert.equal(restored.options.warp, 's4x6');
  assert.equal(restored.argo.token, 'eyJ' + 'b'.repeat(60) + '==');
  assert.deepEqual(G.validateConfig(restored), []);
}

// Full-matrix configuration: every protocol and global option can be serialized together.
{
  const cfg = emptyConfig();
  G.PROTOCOL_ORDER.forEach((key, index) => enable(cfg, key, String(12000 + index)));
  cfg.options = {
    warp: 'sx', ippz: '6', uuid: '550e8400-e29b-41d4-a716-446655440000',
    reym: 'apple.com', cfip: 'cdn1.example.com cdn2.example.com', alns: 'y',
    hyjpt: '123:456 789', cdnym: 'origin.example.com', name: '全协议-01',
    oap: 'y', sub: 'y', subid: 'subscription_01', subpt: '23000'
  };
  cfg.argo = { protocol: 'vxpt', mode: 'y', domain: 'tunnel.example.com', token: 'eyJ' + 'c'.repeat(60) + '==' };
  assert.deepEqual(G.validateConfig(cfg), []);
  const command = G.buildCommand(cfg, 'curl');
  for (const key of G.PROTOCOL_ORDER) assert.match(command, new RegExp(`${key}='\\d+'`));
  for (const key of ['warp','ippz','uuid','reym','cfip','alns','hyjpt','cdnym','name','oap','sub','subid','subpt','argo','agqc','agn','agk']) {
    assert.ok(command.includes(`${key}=`), `missing command variable ${key}`);
  }
}

// Existing upstream-style double-quoted commands can be imported.
{
  const parsed = G.parseCommand('vlpt="443" reym="apple.com" bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/argosbx/main/argosbx.sh)');
  assert.equal(parsed.variables.vlpt, '443');
  assert.equal(parsed.variables.reym, 'apple.com');
}

// Shortcut commands: list retains only IP-family choice; rep retains selected config.
{
  const cfg = emptyConfig(); cfg.options.ippz = '4';
  assert.match(G.buildCommand(cfg, 'curl', 'list'), /^ippz='4' .* list$/);
  assert.match(G.buildCommand(cfg, 'curl', 'del'), /^bash <\(curl .* del$/);
  enable(cfg, 'snpt');
  assert.match(G.buildCommand(cfg, 'curl', 'rep'), /snpt='' .* rep$/);
}


// Path-safe subscription IDs and bounded Cloudflare Tunnel tokens.
{
  const cfg = emptyConfig(); enable(cfg, 'vmpt'); cfg.options.sub = 'y';
  cfg.options.subid = '..';
  assert.match(G.validateConfig(cfg).join(' '), /首尾必须是字母或数字/);
  cfg.options.subid = 'safe-sub_01';
  cfg.argo = { protocol: 'vmpt', mode: '', domain: 'tunnel.example.com', token: 'bad-token' };
  assert.match(G.validateConfig(cfg).join(' '), /Token 格式不正确/);
  cfg.argo.token = 'eyJd+/==';
  assert.deepEqual(G.validateConfig(cfg), []);
}

// Risk notices reflect upstream side effects that cannot be made safe by form validation alone.
{
  const cfg = emptyConfig(); enable(cfg, 'hypt'); enable(cfg, 'tupt', '12005');
  cfg.options.hyjpt = '12000:12010';
  cfg.options.oap = 'y'; cfg.options.sub = 'y'; cfg.options.alns = 'y';
  const warnings = G.getWarnings(cfg);
  assert.deepEqual(warnings.map(x => x.id).sort(), ['alns','hyjpt','hyjpt-overlap','oap','sub']);
  assert.match(warnings.find(x => x.id === 'hyjpt').message, /PREROUTING/);
  assert.match(warnings.find(x => x.id === 'hyjpt-overlap').message, /TUPT/);
  assert.match(warnings.find(x => x.id === 'oap').message, /filter/);
  assert.match(warnings.find(x => x.id === 'sub').message, /HTTP/);
}

// The 15 WARP values must stay aligned with the upstream ArgoSBX generator.
{
  assert.deepEqual(G.WARP_OPTIONS.map(([value]) => value), [
    '', 's', 's4', 's6', 'x', 'x4', 'x6', 's4x4', 's4x6', 's6x4', 's6x6', 'sx4', 'sx6', 's4x', 's6x', 'sx'
  ]);
}

console.log('PASS: 15 protocols, WARP matrix, dependency rules, validation, Argo, subscriptions, quoting, import/export and shortcuts.');
