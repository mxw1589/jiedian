'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const G = require('../generator.js');

const byId = new Map();
const allElements = [];
class FakeElement {
  constructor(tagName = 'div') {
    this.tagName = tagName.toLowerCase(); this.children = []; this.listeners = {}; this.dataset = {};
    this.value = ''; this.checked = false; this.disabled = false; this.textContent = ''; this.className = '';
    this.classList = { toggle() {} };
    allElements.push(this);
  }
  set id(value) { this._id = value; if (value) byId.set(value, this); }
  get id() { return this._id || ''; }
  append(...items) { this.children.push(...items); }
  addEventListener(type, callback) { (this.listeners[type] ||= []).push(callback); }
  dispatch(type) { for (const callback of this.listeners[type] || []) callback({ target: this }); }
  click() { this.dispatch('click'); }
  focus() {}
  select() {}
  setSelectionRange() {}
}
const staticTags = {
  xrayProtocols:'div', singboxProtocols:'div', autoProtocols:'div', uuid:'input', generateUuid:'button', reym:'input', cfip:'input', alns:'select',
  hyjpt:'input', cdnym:'input', warp:'select', ippz:'select', oap:'select', name:'input', sub:'select', subid:'input',
  subpt:'input', argo:'select', agqc:'select', agn:'input', agk:'input', themeToggle:'button', status:'div', preview:'div',
  output:'textarea', copy:'button', download:'button', reset:'button', importText:'textarea', import:'button', clearImport:'button'
};
for (const [id, tag] of Object.entries(staticTags)) { const el = new FakeElement(tag); el.id = id; }
const curlRadio = new FakeElement('input'); curlRadio.name = 'commandType'; curlRadio.value = 'curl'; curlRadio.checked = true;
const wgetRadio = new FakeElement('input'); wgetRadio.name = 'commandType'; wgetRadio.value = 'wget';
const shortcutButtons = [];
for (const key of ['list','del','upx','ups','upa','res','rep']) { const b = new FakeElement('button'); b.dataset.shortcut = key; shortcutButtons.push(b); }
const document = {
  documentElement: { classList: { toggle() {} } },
  getElementById(id) { return byId.get(id) || null; },
  createElement(tag) { return new FakeElement(tag); },
  querySelectorAll(selector) {
    if (selector === 'input,select') return allElements.filter(el => el.tagName === 'input' || el.tagName === 'select');
    if (selector === '[data-shortcut]') return shortcutButtons;
    return [];
  },
  querySelector(selector) {
    if (selector === 'input[name="commandType"]:checked') return [curlRadio,wgetRadio].find(el => el.checked) || null;
    const match = selector.match(/^input\[name="commandType"\]\[value="(curl|wget)"\]$/);
    if (match) return match[1] === 'curl' ? curlRadio : wgetRadio;
    return null;
  }
};
const window = { ArgoGenerator: G };
const html = fs.readFileSync(require.resolve('../index.html'), 'utf8');
const inline = html.match(/<script>([\s\S]*?)<\/script>/);
assert.ok(inline, 'inline page script exists');
vm.runInNewContext(inline[1], { window, document, console, Blob: class {}, URL: { createObjectURL(){return 'blob:';}, revokeObjectURL(){} }, globalThis: { crypto: { randomUUID: () => '550e8400-e29b-41d4-a716-446655440000' } } });

assert.equal(allElements.filter(el => el.dataset.proto).length, 15, 'page renders 15 protocol selectors');
assert.match(byId.get('status').textContent, /至少勾选一种/);
const vlpt = byId.get('proto-vlpt');
vlpt.checked = true; vlpt.dispatch('input'); vlpt.dispatch('change');
assert.match(byId.get('output').value, /vlpt=''/, 'selecting a protocol creates an empty-port variable');
const port = byId.get('port-vlpt'); port.value = '443'; port.dispatch('input');
assert.match(byId.get('output').value, /vlpt='443'/, 'port input updates generated command');
const naive = byId.get('proto-nvpt'); assert.equal(naive.disabled, true, 'NaiveProxy is disabled before TLS certificate option');
byId.get('alns').value = 'y'; byId.get('alns').dispatch('change');
assert.equal(naive.disabled, false, 'NaiveProxy becomes selectable after alns=y');
naive.checked = true; naive.dispatch('input'); naive.dispatch('change');
assert.match(byId.get('output').value, /nvpt=''/, 'NaiveProxy checkbox is exported after TLS is enabled');
byId.get('sub').value = 'y'; byId.get('sub').dispatch('change');
assert.equal(byId.get('subid').disabled, false, 'subscription password input unlocks when subscription is enabled');
byId.get('argo').value = 'vxpt'; byId.get('argo').dispatch('change');
assert.equal(byId.get('proto-vxpt').checked, true, 'Argo selection auto-selects its main protocol');
assert.match(byId.get('status').textContent, /固定隧道/);
byId.get('agn').value = 'tunnel.example.com'; byId.get('agn').dispatch('input');
byId.get('agk').value = 'eyJtest-token+/=='; byId.get('agk').dispatch('input');
assert.match(byId.get('output').value, /argo='vxpt'/);
byId.get('reset').click();
assert.equal(byId.get('proto-vlpt').checked, false);
assert.equal(byId.get('output').value, '');
console.log('PASS: browser UI smoke test renders, links dependencies, validates Argo and resets correctly.');
