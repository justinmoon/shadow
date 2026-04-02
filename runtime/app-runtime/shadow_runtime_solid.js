const VOID_ELEMENTS = new Set([
  "area",
  "base",
  "br",
  "col",
  "embed",
  "hr",
  "img",
  "input",
  "link",
  "meta",
  "param",
  "source",
  "track",
  "wbr",
]);

export function createElement(tagName) {
  return {
    attributes: Object.create(null),
    children: [],
    kind: "element",
    listeners: Object.create(null),
    tagName,
  };
}

export function createTextNode(value) {
  return {
    kind: "text",
    value: value == null ? "" : String(value),
  };
}

export function createComponent(component, props) {
  return component(props ?? {});
}

export function insertNode(parent, node, anchor = null) {
  insertResolved(parent, [node], anchor);
}

export function insert(parent, value, anchor = null) {
  insertResolved(parent, resolveNodes(value), anchor);
  return value;
}

export function setProp(node, name, value) {
  assertElementNode(node, "setProp");

  const attributeName = name === "className" ? "class" : name;
  if (attributeName === "classList" && value && typeof value === "object") {
    const className = Object.entries(value)
      .filter(([, enabled]) => Boolean(enabled))
      .map(([className]) => className)
      .join(" ");
    if (className) {
      node.attributes.class = className;
    }
    return;
  }

  if (attributeName === "style" && value && typeof value === "object") {
    node.attributes.style = Object.entries(value)
      .filter(([, styleValue]) => styleValue != null && styleValue !== false)
      .map(([styleName, styleValue]) =>
        `${toKebabCase(styleName)}:${String(styleValue)}`
      )
      .join(";");
    return;
  }

  if (attributeName.startsWith("on") && typeof value === "function") {
    node.listeners[attributeName.slice(2).toLowerCase()] = value;
    return;
  }

  if (value == null || value === false) {
    delete node.attributes[attributeName];
    return;
  }

  node.attributes[attributeName] = value === true ? true : String(value);
}

export function renderToDocument(root) {
  const nodes = resolveNodes(root);
  return {
    css: null,
    html: nodes.map((node) => serializeNode(node)).join(""),
  };
}

function insertResolved(parent, nodes, anchor) {
  assertElementNode(parent, "insert");

  if (nodes.length === 0) {
    return;
  }

  const anchorIndex = resolveAnchorIndex(parent, anchor);
  parent.children.splice(anchorIndex, 0, ...nodes);
}

function resolveNodes(value) {
  if (typeof value === "function") {
    return resolveNodes(value());
  }

  if (value == null || value === false || value === true) {
    return [];
  }

  if (Array.isArray(value)) {
    return value.flatMap((entry) => resolveNodes(entry));
  }

  if (typeof value === "string" || typeof value === "number") {
    return [createTextNode(value)];
  }

  if (typeof value === "object" && value.kind) {
    return [value];
  }

  return [createTextNode(String(value))];
}

function resolveAnchorIndex(parent, anchor) {
  if (anchor == null) {
    return parent.children.length;
  }

  const anchorIndex = parent.children.indexOf(anchor);
  return anchorIndex === -1 ? parent.children.length : anchorIndex;
}

function serializeNode(node) {
  if (node.kind === "text") {
    return escapeHtml(node.value);
  }

  assertElementNode(node, "serialize");

  const attributes = Object.entries(node.attributes)
    .map(([name, value]) => serializeAttribute(name, value))
    .filter(Boolean)
    .join("");
  if (VOID_ELEMENTS.has(node.tagName)) {
    return `<${node.tagName}${attributes}>`;
  }

  const children = node.children.map((child) => serializeNode(child)).join("");
  return `<${node.tagName}${attributes}>${children}</${node.tagName}>`;
}

function serializeAttribute(name, value) {
  if (value == null || value === false) {
    return "";
  }

  if (value === true) {
    return ` ${name}`;
  }

  return ` ${name}="${escapeAttribute(String(value))}"`;
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function escapeAttribute(value) {
  return escapeHtml(value).replaceAll('"', "&quot;");
}

function toKebabCase(value) {
  return value.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
}

function assertElementNode(node, operation) {
  if (!node || node.kind !== "element") {
    throw new TypeError(`${operation} expects an element node`);
  }
}
