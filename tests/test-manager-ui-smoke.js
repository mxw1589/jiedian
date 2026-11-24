'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const html = fs.readFileSync(require.resolve('../manager.html'), 'utf8');
assert.match(html, /wget -qO/ , 'direct installer should fall back to wget');
assert.match(html, /WEB_CONFIG_SCHEMA=8/, 'direct installer should check server script schema');
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
assert.match(byId.get('commandOutput').value, /v1\.0\.8; compact IPv4\/IPv6 node lists and per-family client configs/, 'installer must reject stale remote manager scripts');
const encoded = byId.get('commandOutput').value.match(/printf '%s' '([A-Za-z0-9+/=]+)' \| base64 -d/);
assert.ok(encoded, 'installer command carries an encoded JSON configuration');
const decoded = Buffer.from(encoded[1], 'base64').toString('utf8');
const decodedConfig = JSON.parse(decoded);
assert.equal(decodedConfig.ws_server, '203.0.113.8');
const shellSyntax = spawnSync('sh', ['-n'], { input: byId.get('commandOutput').value, encoding: 'utf8' });
assert.equal(shellSyntax.status, 0, shellSyntax.stderr || 'generated shell installer must parse');

console.log('PASS: legacy manager UI toggles the WS address override and generates a valid installer command.');
