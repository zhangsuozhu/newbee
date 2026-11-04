// 组件定向测试用的极简 DOM 替身（Node 22，自带 node:test）。
// 只实现 conversation-work.js 用到的 API；没有 innerHTML，因此组件一旦
// 用 HTML 字符串拼内容，测试会立刻失败。

const VOID = new Set(["input", "br", "img"]);

class TextNode {
  constructor(text) { this.nodeType = 3; this.text = String(text); }
  get textContent() { return this.text; }
}

class Element {
  constructor(tag) {
    this.nodeType = 1;
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.attributes = new Map();
    this.dataset = {};
    this.listeners = new Map();
    this.className = "";
    this.id = "";
    this.type = "";
    this.title = "";
    this.value = "";
    this.placeholder = "";
    this.rows = 0;
    this.disabled = false;
    this.hidden = false;
    this.selectionStart = 0;
    this.selectionEnd = 0;
    this.parentNode = null;
    this.ownerDocument = null;
    this._text = "";
    this.classList = {
      add: (...names) => { names.forEach((n) => { if (!this._classes().includes(n)) this.className = [this.className, n].join(" ").trim(); }); },
      remove: (...names) => { this.className = this._classes().filter((c) => !names.includes(c)).join(" "); },
      contains: (name) => this._classes().includes(name)
    };
  }
  _classes() { return this.className.split(/\s+/).filter(Boolean); }
  get childNodes() { return this.children; }
  get textContent() {
    return this.children.map((c) => c.textContent).join("");
  }
  set textContent(value) {
    // 与真实 DOM 一致：整体替换为一个文本子节点，之后 append 不会覆盖它。
    this.children = [];
    const node = new TextNode(value == null ? "" : value);
    node.parentNode = this;
    this.children.push(node);
  }
  appendChild(node) {
    if (node && node.parentNode) node.parentNode.removeChild(node);
    this.children.push(node);
    if (node) node.parentNode = this;
    if (node && node.ownerDocument == null) node.ownerDocument = this.ownerDocument;
    return node;
  }
  append(...nodes) { nodes.forEach((n) => this.appendChild(n)); }
  replaceChildren(...nodes) {
    this.children = [];
    nodes.forEach((n) => this.appendChild(n));
  }
  insertBefore(node, reference) {
    if (reference == null) return this.appendChild(node);
    if (node && node.parentNode) node.parentNode.removeChild(node);
    const index = this.children.indexOf(reference);
    if (index < 0) return this.appendChild(node);
    this.children.splice(index, 0, node);
    if (node) node.parentNode = this;
    if (node && node.ownerDocument == null) node.ownerDocument = this.ownerDocument;
    return node;
  }
  removeChild(node) {
    const i = this.children.indexOf(node);
    if (i >= 0) this.children.splice(i, 1);
    if (node) node.parentNode = null;
    return node;
  }
  setAttribute(name, value) {
    this.attributes.set(name, String(value));
    if (name === "id") this.id = String(value);
    if (name === "aria-label") this.ariaLabel = String(value);
  }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  addEventListener(type, fn) {
    const list = this.listeners.get(type) || [];
    list.push(fn);
    this.listeners.set(type, list);
  }
  removeEventListener(type, fn) {
    const list = this.listeners.get(type) || [];
    this.listeners.set(type, list.filter((f) => f !== fn));
  }
  dispatch(type, event) {
    const list = (this.listeners.get(type) || []).slice();
    const payload = Object.assign({type: type, target: this, preventDefault() { this.defaultPrevented = true; }}, event || {});
    list.forEach((fn) => fn(payload));
    return payload;
  }
  click() { return this.dispatch("click", {}); }
  focus() { if (this.ownerDocument) this.ownerDocument.activeElement = this; }
  setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
  contains(node) {
    if (!node) return false;
    if (node === this) return true;
    return this.children.some((child) => child.nodeType === 1 && child.contains(node));
  }
  querySelectorAll(selector) {
    const out = [];
    const walk = (node) => {
      node.children.forEach((child) => {
        if (child.nodeType !== 1) return;
        if (selector === "[data-cw-key]" && child.dataset && child.dataset.cwKey) out.push(child);
        walk(child);
      });
    };
    walk(this);
    return out;
  }
  querySelector(selector) {
    const all = this.querySelectorAll(selector);
    return all.length ? all[0] : null;
  }
  allElements() {
    const out = [this];
    const walk = (node) => node.children.forEach((child) => { if (child.nodeType === 1) { out.push(child); walk(child); } });
    walk(this);
    return out;
  }
}

class Document {
  constructor() {
    this.body = new Element("body");
    this.body.ownerDocument = this;
    this.hidden = false;
    this.activeElement = null;
    this.listeners = new Map();
  }
  createElement(tag) {
    const node = new Element(tag);
    node.ownerDocument = this;
    return node;
  }
  createTextNode(text) { return new TextNode(text); }
  getElementById(id) {
    return this.body.allElements().find((node) => node.id === id) || null;
  }
  addEventListener(type, fn) {
    const list = this.listeners.get(type) || [];
    list.push(fn);
    this.listeners.set(type, list);
  }
  removeEventListener(type, fn) {
    const list = this.listeners.get(type) || [];
    this.listeners.set(type, list.filter((f) => f !== fn));
  }
  dispatch(type) {
    (this.listeners.get(type) || []).slice().forEach((fn) => fn({type: type}));
  }
}

function install() {
  const document = new Document();
  document.createElementNS = (namespace, tag) => document.createElement(tag);
  const main = document.createElement("main");
  main.id = "main";
  // 与 priv/web/index.html 一致：#composer 位于 #main 内部，卡片插在它之前。
  const composer = document.createElement("footer");
  composer.id = "composer";
  const actions = document.createElement("div");
  actions.id = "composer-actions";
  const send = document.createElement("button");
  send.id = "send";
  actions.append(send);
  composer.append(actions);
  main.append(composer);
  document.body.append(main);
  globalThis.document = document;
  globalThis.window = globalThis.window || globalThis;
  return document;
}

module.exports = {Document, Element, install};
