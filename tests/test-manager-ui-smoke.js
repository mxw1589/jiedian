'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const html = fs.readFileSync(require.resolve('../index.html'), 'utf8');
assert.match(html, /wget -qO/ , 'direct installer should fall back to wget');
assert.match(html, /<h2>⑤ 自动生成 SSH 命令<\/h2>/, 'main page must label the SSH generator as section ⑤');
assert.match(html, /github\.com\/mxw1589\/jiedian\/blob\/main\/sb-manager-debian-alpine\.sh/, 'main page must link to the exact user-provided GitHub script page');
assert.doesNotMatch(html, /raw\.githubusercontent\.com\/yonggekkk\/argosbx\/main\/argosbx\.sh/, 'main page must not call the unrelated upstream ArgoSBX script');
assert.match(html, /raw\.githubusercontent\.com\/mxw1589\/jiedian\/main\/sb-manager-debian-alpine\.sh/, "installer must download the user repository script");
assert.match(html, /WEB_CONFIG_SCHEMA=8/, 'direct installer should check server script schema');
assert.match(html, /id="nodeFamily"/, 'manager page should expose an address-family selector');
assert.match(html, /value="46" selected/, 'dual-stack should be the default output mode');
const serverScript = fs.readFileSync(require.resolve('../sb-manager-debian-alpine.sh'), 'utf8');
assert.match(serverScript, /sb-manager\.pre-script/, 'server-side installer should back up the existing project manager before replacing it');
const byId = new Map();
const elements = [];
class FakeElement {
  constructor(tagName = 'div', attrs = '') {
    this.tagName = tagName.toLowerCase();
    this.value = '';
    this.checked = /\bchecked\b/.test(attrs);
    this.disabled = /\bdisabled\b/.test(attrs);
    this.textContent = '';
    this.className = '';
    this.listeners = {};
    this.children = [];
    this.dataset = {};
    const value = attrs.match(/\bvalue="([^"]*)"/);
    if (value) this.value = value[1];
    const classes = (attrs.match(/\bclass="([^"]*)"/) || [,''])[1].split(/\s+/).filter(Boolean);
    this.classSet = new Set(classes);
    this.classList = {
      toggle: (name, force) => {
        const on = force === undefined ? !this.classSet.has(name) : Boolean(force);
        if (on) this.classSet.add(name); else this.classSet.delete(name);
        return on;
      },
      contains: name => this.classSet.has(name),
    };
    elements.push(this);
  }
  set id(value) { this._id = value; if (value) byId.set(value, this); }
  get id() { return this._id || ''; }
  addEventListener(type, callback) { (this.listeners[type] ||= []).push(callback); }
  dispatch(type) { for (const callback of this.listeners[type] || []) callback({ target: this }); }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = [...items]; }
  click() { this.dispatch('click'); }
  remove() {}
  select() {}
}

const tagRe = /<(input|select|textarea|button|div|pre)\b([^>]*)>/gi;
let match;
while ((match = tagRe.exec(html))) {
  const attrs = match[2];
  const id = (attrs.match(/\bid="([^"]+)"/) || [,''])[1];
  if (!id || byId.has(id)) continue;
  const el = new FakeElement(match[1], attrs);
  el.id = id;
  if (match[1].toLowerCase() === 'select') {
    const tail = html.slice(tagRe.lastIndex);
    const option = tail.match(/^([\s\S]*?)<\/select>/i)?.[1].match(/<option\b([^>]*)>/i);
    if (option) {
      const selected = option[1].match(/\bvalue="([^"]*)"/);
      el.value = selected ? selected[1] : '';
    }
  }
}
const document = {
  body: { appendChild() {} },
  getElementById(id) { return byId.get(id) || null; },
  createElement(tag) { return new FakeElement(tag); },
  querySelectorAll(selector) {
    if (selector === 'input,select') return elements.filter(x => x.tagName === 'input' || x.tagName === 'select');
    return [];
  },
  querySelector() { return null; },
  execCommand() { return true; },
};

const inline = html.match(/<script>([\s\S]*?)<\/script>/);
assert.ok(inline, 'manager inline script exists');
vm.runInNewContext(inline[1], {
  document, console, URL, Blob, btoa, unescape, encodeURIComponent,
  navigator: { clipboard: { writeText: async () => {} } },
  alert() {},
});

const wsField = byId.get('wsServerField');
assert.ok(wsField, 'WS connection override field exists');
assert.equal(wsField.classList.contains('hidden'), false, 'WS override field is visible when WS is selected');
assert.equal(byId.get('wsServer').disabled, false, 'WS override input is enabled when WS is selected');

byId.get('pWs').checked = false;
byId.get('pWs').dispatch('change');
assert.equal(wsField.classList.contains('hidden'), true, 'WS override field hides when WS is disabled');
assert.equal(byId.get('wsServer').disabled, true, 'WS override input disables when WS is disabled');

byId.get('pWs').checked = true;
byId.get('pWs').dispatch('change');
byId.get('argoHost').value = 'ws.example.com';
byId.get('argoHost').dispatch('input');
byId.get('argoToken').value = 'eyJ' + 'a'.repeat(60) + '==';
byId.get('argoToken').dispatch('input');
byId.get('wsServer').value = '203.0.113.8';
byId.get('wsServer').dispatch('input');
assert.match(byId.get('commandOutput').value, /install-web-config/);
assert.match(byId.get('commandOutput').value, /raw\.githubusercontent\.com\/mxw1589\/jiedian\/main\/sb-manager-debian-alpine\.sh/, 'generated SSH command must download the repository script raw content');
assert.doesNotMatch(byId.get('commandOutput').value, /yonggekkk\/argosbx\/argosbx\.sh/, 'generated SSH command must not call the old upstream generator');
assert.match(byId.get('commandOutput').value, /v1\.0\.9; selectable IPv4, IPv6 or dual-stack node display from web-generated commands/, 'installer must reject stale remote manager scripts');
const encoded = byId.get('commandOutput').value.match(/printf '%s' '([A-Za-z0-9+/=]+)' \| base64 -d/);
assert.ok(encoded, 'installer command carries an encoded JSON configuration');
const decoded = Buffer.from(encoded[1], 'base64').toString('utf8');
const decodedConfig = JSON.parse(decoded);
assert.equal(decodedConfig.ws_server, '203.0.113.8');
assert.equal(decodedConfig.node_family, '46', 'default generated config should select dual-stack');
assert.match(byId.get('commandOutput').value, /sb-manager nodes '46'/, 'generated installer should invoke the repository manager for dual-stack output');
byId.get('nodeFamily').value = '4';
byId.get('nodeFamily').dispatch('change');
assert.match(byId.get('commandOutput').value, /sb-manager nodes '4'/, 'IPv4 selection should change the generated command');
byId.get('nodeFamily').value = '6';
byId.get('nodeFamily').dispatch('change');
assert.match(byId.get('commandOutput').value, /sb-manager nodes '6'/, 'IPv6 selection should change the generated command');
const shellSyntax = spawnSync('sh', ['-n'], { input: byId.get('commandOutput').value, encoding: 'utf8' });
assert.equal(shellSyntax.status, 0, shellSyntax.stderr || 'generated shell installer must parse');

console.log('PASS: main index UI toggles protocol fields and generates SSH install commands from the user repository with IPv4, IPv6 and dual-stack selection.');
