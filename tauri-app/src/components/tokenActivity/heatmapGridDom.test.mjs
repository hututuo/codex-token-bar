import assert from "node:assert/strict";
import test from "node:test";

import { withSsrModules } from "../../test/ssrHarness.mjs";

test("focused heatmap cell removal transfers DOM focus to the valid fallback", async () => {
  await withMountedHeatmap(async ({ act, container, render }) => {
    const hoverEvents = [];
    const days = calendarDays();
    await render(days, (day) => hoverEvents.push(day?.date ?? null));
    const initialCells = heatmapCells(container);

    await act(async () => initialCells.at(-1).focus());
    await pressKey(act, document.activeElement, "Home");
    assert.equal(cellDate(document.activeElement), days[0].day.date);

    await pressKey(act, document.activeElement, "ArrowRight");
    assert.equal(cellDate(document.activeElement), days[7].day.date);
    await pressKey(act, document.activeElement, "Home");
    assert.equal(cellDate(document.activeElement), days[0].day.date);

    await render(days.slice(1), (day) => hoverEvents.push(day?.date ?? null));

    const refreshedCells = heatmapCells(container);
    assert.equal(cellDate(document.activeElement), days.at(-1).day.date);
    assert.equal(refreshedCells.filter((cell) => cell.tabIndex === 0).length, 1);
    assert.equal(refreshedCells.find((cell) => cell.tabIndex === 0), document.activeElement);
    assert.equal(hoverEvents.at(-1), days.at(-1).day.date);
  });
});

test("rerender does not reclaim focus after the user leaves the heatmap", async () => {
  await withMountedHeatmap(async ({ act, container, render }) => {
    const hoverEvents = [];
    const days = calendarDays();
    await render(days, (day) => hoverEvents.push(day?.date ?? null));
    const initialCells = heatmapCells(container);

    await act(async () => initialCells.at(-1).focus());
    await pressKey(act, document.activeElement, "Home");
    const outside = document.createElement("button");
    document.body.appendChild(outside);
    await act(async () => outside.focus());
    assert.equal(document.activeElement, outside);
    assert.equal(hoverEvents.at(-1), null);

    await render(days.slice(1), (day) => hoverEvents.push(day?.date ?? null));

    const refreshedCells = heatmapCells(container);
    assert.equal(document.activeElement, outside);
    assert.equal(refreshedCells.filter((cell) => cell.tabIndex === 0).length, 1);
    assert.equal(hoverEvents.at(-1), null);
    outside.remove();
  });
});

test("rerender keeps an existing focused cell without refocusing it", async () => {
  await withMountedHeatmap(async ({ act, container, render }) => {
    const hoverEvents = [];
    const days = calendarDays();
    await render(days, (day) => hoverEvents.push(day?.date ?? null));
    const initialCells = heatmapCells(container);

    await act(async () => initialCells.at(-1).focus());
    await pressKey(act, document.activeElement, "Home");
    await pressKey(act, document.activeElement, "ArrowRight");
    const focusedCell = document.activeElement;
    const hoverCount = hoverEvents.length;

    const refreshedDays = days.map(({ day, intensity }) => ({
      day: { ...day, tokens: day.tokens + 1 },
      intensity,
    }));
    await render(refreshedDays, (day) => hoverEvents.push(day?.date ?? null));

    assert.equal(document.activeElement, focusedCell);
    assert.equal(cellDate(document.activeElement), days[7].day.date);
    assert.equal(hoverEvents.length, hoverCount);
    assert.equal(heatmapCells(container).filter((cell) => cell.tabIndex === 0).length, 1);
  });
});

async function withMountedHeatmap(run) {
  const dom = installMiniDom();
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async (load) => {
      const { HeatmapGrid } = await load("/src/components/tokenActivity/HeatmapGrid.tsx");
      const container = document.createElement("div");
      document.body.appendChild(container);
      const root = createRoot(container);
      const render = async (days, onDayHover) => {
        await React.act(async () => {
          root.render(React.createElement(HeatmapGrid, heatmapProps(days, onDayHover)));
        });
      };
      try {
        await run({ act: React.act, container, render });
      } finally {
        await React.act(async () => root.unmount());
        container.remove();
      }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    dom.restore();
  }
}

async function pressKey(act, target, key) {
  await act(async () => {
    target.dispatchEvent(new KeyboardEvent("keydown", {
      bubbles: true,
      cancelable: true,
      key,
    }));
  });
}

function heatmapProps(days, onDayHover) {
  return {
    days,
    hoveredDate: null,
    mode: "daily",
    monthMarkers: [],
    onDateSelect() {},
    onDayHover,
    rangeEnd: null,
    rangeStart: null,
  };
}

function heatmapCells(container) {
  return descendants(container).filter((node) => (
    node.nodeType === 1 && node.localName === "button" && node.className.includes("heatmap-cell")
  ));
}

function descendants(root) {
  return root.childNodes.flatMap((child) => [child, ...descendants(child)]);
}

function cellDate(cell) {
  return cell?.getAttribute("aria-label")?.slice(0, 10) ?? null;
}

function calendarDays() {
  const start = new Date(2026, 0, 1, 12);
  return Array.from({ length: 365 }, (_, index) => {
    const date = new Date(start);
    date.setDate(start.getDate() + index);
    return {
      day: {
        cacheHitRate: 0,
        calls: index === 364 ? 1 : 0,
        date: dateKey(date),
        fiveHourRemainingPercent: null,
        sevenDayRemainingPercent: null,
        tokens: index === 364 ? 100 : 0,
      },
      intensity: index === 364 ? 1 : 0,
    };
  });
}

function dateKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function installMiniDom() {
  const previous = new Map();
  const document = new MiniDocument();
  const window = createMiniWindow(document);
  document.defaultView = window;
  const globals = {
    document,
    window,
    navigator: window.navigator,
    Node: MiniNode,
    Element: MiniElement,
    HTMLElement: MiniElement,
    HTMLButtonElement: MiniElement,
    HTMLIFrameElement: MiniIFrameElement,
    Event: MiniEvent,
    FocusEvent: MiniEvent,
    KeyboardEvent: MiniKeyboardEvent,
  };
  for (const [name, value] of Object.entries(globals)) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value, writable: true });
  }
  return {
    restore() {
      for (const [name, descriptor] of previous) {
        if (descriptor) {
          Object.defineProperty(globalThis, name, descriptor);
        } else {
          delete globalThis[name];
        }
      }
    },
  };
}

class MiniEvent {
  constructor(type, options = {}) {
    this.type = type;
    this.bubbles = options.bubbles ?? false;
    this.cancelable = options.cancelable ?? false;
    this.relatedTarget = options.relatedTarget ?? null;
    this.defaultPrevented = false;
    this.cancelBubble = false;
    this.target = null;
    this.currentTarget = null;
    this.eventPhase = 0;
    this.timeStamp = Date.now();
  }

  preventDefault() {
    if (this.cancelable) {
      this.defaultPrevented = true;
    }
  }

  stopPropagation() {
    this.cancelBubble = true;
  }
}

class MiniKeyboardEvent extends MiniEvent {
  constructor(type, options = {}) {
    super(type, options);
    this.key = options.key ?? "";
    this.code = options.code ?? "";
    this.charCode = 0;
    this.keyCode = 0;
    this.which = 0;
  }
}

class MiniEventTarget {
  constructor() {
    this.listeners = new Map();
  }

  addEventListener(type, listener, options = false) {
    const capture = typeof options === "boolean" ? options : Boolean(options?.capture);
    const listeners = this.listeners.get(type) ?? [];
    listeners.push({ capture, listener });
    this.listeners.set(type, listeners);
  }

  removeEventListener(type, listener, options = false) {
    const capture = typeof options === "boolean" ? options : Boolean(options?.capture);
    const listeners = this.listeners.get(type) ?? [];
    this.listeners.set(type, listeners.filter((entry) => entry.listener !== listener || entry.capture !== capture));
  }

  dispatchEvent(event) {
    event.target ??= this;
    const path = [];
    for (let node = this; node; node = node.parentNode) {
      path.push(node);
    }
    dispatchPath(event, path.slice().reverse(), true);
    if (!event.cancelBubble && event.bubbles) {
      dispatchPath(event, path, false);
    }
    event.currentTarget = null;
    event.eventPhase = 0;
    return !event.defaultPrevented;
  }
}

class MiniNode extends MiniEventTarget {
  constructor(nodeType, nodeName, ownerDocument = null) {
    super();
    this.nodeType = nodeType;
    this.nodeName = nodeName;
    this.ownerDocument = ownerDocument;
    this.parentNode = null;
    this.childNodes = [];
  }

  get firstChild() {
    return this.childNodes[0] ?? null;
  }

  get lastChild() {
    return this.childNodes.at(-1) ?? null;
  }

  get nextSibling() {
    if (!this.parentNode) {
      return null;
    }
    const index = this.parentNode.childNodes.indexOf(this);
    return this.parentNode.childNodes[index + 1] ?? null;
  }

  get parentElement() {
    return this.parentNode?.nodeType === 1 ? this.parentNode : null;
  }

  get textContent() {
    if (this.nodeType === 3) {
      return this.nodeValue;
    }
    return this.childNodes.map((child) => child.textContent).join("");
  }

  set textContent(value) {
    if (this.nodeType === 3) {
      this.nodeValue = String(value);
      return;
    }
    for (const child of this.childNodes) {
      child.parentNode = null;
    }
    this.childNodes = [];
    if (value !== "" && value !== null && value !== undefined) {
      this.appendChild(this.ownerDocument.createTextNode(String(value)));
    }
  }

  appendChild(child) {
    return this.insertBefore(child, null);
  }

  insertBefore(child, before) {
    child.parentNode?.removeChild(child);
    const index = before === null ? this.childNodes.length : this.childNodes.indexOf(before);
    if (index < 0) {
      throw new Error("reference node is not a child");
    }
    this.childNodes.splice(index, 0, child);
    child.parentNode = this;
    return child;
  }

  removeChild(child) {
    const index = this.childNodes.indexOf(child);
    if (index < 0) {
      throw new Error("node is not a child");
    }
    const activeElement = this.ownerDocument?.activeElement;
    if (activeElement && child.contains(activeElement)) {
      this.ownerDocument.activeElement = this.ownerDocument.body;
    }
    this.childNodes.splice(index, 1);
    child.parentNode = null;
    return child;
  }

  contains(node) {
    for (let current = node; current; current = current.parentNode) {
      if (current === this) {
        return true;
      }
    }
    return false;
  }

  remove() {
    this.parentNode?.removeChild(this);
  }
}

class MiniElement extends MiniNode {
  constructor(tagName, ownerDocument) {
    super(1, tagName.toUpperCase(), ownerDocument);
    this.tagName = this.nodeName;
    this.localName = tagName.toLowerCase();
    this.namespaceURI = "http://www.w3.org/1999/xhtml";
    this.attributes = new Map();
    this.style = { setProperty(name, value) { this[name] = String(value); } };
  }

  get className() {
    return this.getAttribute("class") ?? "";
  }

  set className(value) {
    this.setAttribute("class", value);
  }

  get tabIndex() {
    const value = this.getAttribute("tabindex");
    return value === null ? -1 : Number(value);
  }

  set tabIndex(value) {
    this.setAttribute("tabindex", value);
  }

  setAttribute(name, value) {
    this.attributes.set(name.toLowerCase(), String(value));
  }

  setAttributeNS(_namespace, name, value) {
    this.setAttribute(name, value);
  }

  getAttribute(name) {
    return this.attributes.get(name.toLowerCase()) ?? null;
  }

  hasAttribute(name) {
    return this.attributes.has(name.toLowerCase());
  }

  removeAttribute(name) {
    this.attributes.delete(name.toLowerCase());
  }

  focus() {
    const document = this.ownerDocument;
    if (document.activeElement === this) {
      return;
    }
    const previous = document.activeElement;
    document.activeElement = this;
    previous?.dispatchEvent(new MiniEvent("focusout", {
      bubbles: true,
      relatedTarget: this,
    }));
    this.dispatchEvent(new MiniEvent("focusin", {
      bubbles: true,
      relatedTarget: previous,
    }));
  }

  blur() {
    if (this.ownerDocument.activeElement !== this) {
      return;
    }
    this.ownerDocument.activeElement = this.ownerDocument.body;
    this.dispatchEvent(new MiniEvent("focusout", {
      bubbles: true,
      relatedTarget: this.ownerDocument.body,
    }));
  }
}

class MiniIFrameElement extends MiniElement {}

class MiniText extends MiniNode {
  constructor(value, ownerDocument) {
    super(3, "#text", ownerDocument);
    this.nodeValue = value;
    this.data = value;
  }
}

class MiniDocument extends MiniNode {
  constructor() {
    super(9, "#document", null);
    this.ownerDocument = this;
    this.defaultView = null;
    this.documentElement = new MiniElement("html", this);
    this.head = new MiniElement("head", this);
    this.body = new MiniElement("body", this);
    this.appendChild(this.documentElement);
    this.documentElement.appendChild(this.head);
    this.documentElement.appendChild(this.body);
    this.activeElement = this.body;
    this.visibilityState = "visible";
  }

  createElement(tagName) {
    return new MiniElement(tagName, this);
  }

  createElementNS(_namespace, tagName) {
    return this.createElement(tagName);
  }

  createTextNode(value) {
    return new MiniText(String(value), this);
  }

  createComment(value) {
    const comment = new MiniNode(8, "#comment", this);
    comment.nodeValue = String(value);
    return comment;
  }

  hasFocus() {
    return true;
  }
}

function createMiniWindow(document) {
  const window = new MiniEventTarget();
  window.document = document;
  window.window = window;
  window.self = window;
  window.top = window;
  window.navigator = { userAgent: "mini-react-dom-test" };
  window.Node = MiniNode;
  window.Element = MiniElement;
  window.HTMLElement = MiniElement;
  window.HTMLButtonElement = MiniElement;
  window.HTMLIFrameElement = MiniIFrameElement;
  window.Event = MiniEvent;
  window.FocusEvent = MiniEvent;
  window.KeyboardEvent = MiniKeyboardEvent;
  window.getSelection = () => null;
  window.getComputedStyle = () => ({});
  return window;
}

function dispatchPath(event, path, capture) {
  for (const target of path) {
    const listeners = target.listeners?.get(event.type) ?? [];
    for (const entry of listeners) {
      if (entry.capture !== capture) {
        continue;
      }
      event.currentTarget = target;
      event.eventPhase = capture ? 1 : 3;
      if (typeof entry.listener === "function") {
        entry.listener.call(target, event);
      } else {
        entry.listener.handleEvent(event);
      }
      if (event.cancelBubble) {
        return;
      }
    }
  }
}
