import {
  createComponent as solidCreateComponent,
  createEffect,
  createMemo as solidCreateMemo,
  createRenderEffect,
  createRoot as solidCreateRoot,
  mergeProps as solidMergeProps,
  untrack as solidUntrack,
} from "npm:solid-js@1.9.10/dist/solid.js";

export {
  ErrorBoundary,
  For,
  Index,
  Match,
  Show,
  Suspense,
  SuspenseList,
  Switch,
  batch,
  createEffect,
  createMemo,
  createRoot,
  createSignal,
  onCleanup,
  onMount,
  splitProps,
  untrack,
} from "npm:solid-js@1.9.10/dist/solid.js";

const ROOT_TAG = "shadow-root";
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

const memoHelper = (fn) => solidCreateMemo(() => fn());
const renderer = createRenderer({
  createElement: hostCreateElement,
  createSlotNode: hostCreateSlotNode,
  createTextNode: hostCreateTextNode,
  getFirstChild,
  getNextSibling,
  getParentNode,
  insertNode: insertHostNode,
  isTextNode,
  removeNode,
  replaceText,
  setProperty,
});

export const {
  createComponent,
  createElement,
  createTextNode,
  effect,
  insert,
  insertNode,
  memo,
  mergeProps,
  render,
  setProp,
  spread,
  use,
} = renderer;

export function createRuntimeApp(renderApp) {
  if (typeof renderApp !== "function") {
    throw new TypeError("runtime app entry must be a function");
  }

  const mount = hostCreateElement(ROOT_TAG);
  const dispose = render(() => renderApp(), mount);

  return {
    dispatch(event) {
      dispatchRuntimeEvent(mount, event);
      return renderMountToDocument(mount);
    },
    dispose,
    renderDocument() {
      return renderMountToDocument(mount);
    },
  };
}

export function renderToDocument(root) {
  const nodes = root?.kind === "element" && root.tagName === ROOT_TAG
    ? root.children
    : [root];
  return {
    css: null,
    html: nodes.map((node) => serializeNode(node)).join(""),
  };
}

function hostCreateElement(tagName) {
  const node = {
    attributes: Object.create(null),
    children: [],
    kind: "element",
    listeners: Object.create(null),
    parent: null,
    tagName,
  };
  attachElementAccessors(node);
  return node;
}

function hostCreateTextNode(value) {
  return {
    kind: "text",
    parent: null,
    value: value == null ? "" : String(value),
  };
}

function hostCreateSlotNode() {
  return hostCreateTextNode("");
}

function replaceText(node, value) {
  assertTextNode(node, "replaceText");
  node.value = value == null ? "" : String(value);
}

function setProperty(node, name, value) {
  assertElementNode(node, "setProperty");

  const attributeName = name === "className" ? "class" : name;
  if (attributeName === "classList" && value && typeof value === "object") {
    const className = Object.entries(value)
      .filter(([, enabled]) => Boolean(enabled))
      .map(([className]) => className)
      .join(" ");
    if (className) {
      node.attributes.class = className;
    } else {
      delete node.attributes.class;
    }
    return;
  }

  if (attributeName === "style" && value && typeof value === "object") {
    const styleValue = Object.entries(value)
      .filter(([, styleEntry]) => styleEntry != null && styleEntry !== false)
      .map(([styleName, styleEntry]) =>
        `${toKebabCase(styleName)}:${String(styleEntry)}`
      )
      .join(";");
    if (styleValue) {
      node.attributes.style = styleValue;
    } else {
      delete node.attributes.style;
    }
    return;
  }

  if (attributeName.startsWith("on")) {
    const eventName = attributeName.slice(2).toLowerCase();
    if (typeof value === "function") {
      node.listeners[eventName] = value;
    } else {
      delete node.listeners[eventName];
    }
    return;
  }

  if (value == null || value === false) {
    delete node.attributes[attributeName];
    return;
  }

  node.attributes[attributeName] = value === true ? true : String(value);
}

function insertHostNode(parent, node, anchor = null) {
  assertElementNode(parent, "insertNode");
  detachNode(node);
  node.parent = parent;
  const anchorIndex = resolveAnchorIndex(parent, anchor);
  parent.children.splice(anchorIndex, 0, node);
}

function removeNode(parent, node) {
  assertElementNode(parent, "removeNode");
  const nodeIndex = parent.children.indexOf(node);
  if (nodeIndex >= 0) {
    parent.children.splice(nodeIndex, 1);
  }
  if (node && typeof node === "object") {
    node.parent = null;
  }
}

function getParentNode(node) {
  return node?.parent ?? null;
}

function getFirstChild(node) {
  assertElementNode(node, "getFirstChild");
  return node.children[0] ?? null;
}

function getNextSibling(node) {
  const parent = node?.parent;
  if (!parent) {
    return null;
  }

  const nodeIndex = parent.children.indexOf(node);
  return nodeIndex === -1 ? null : parent.children[nodeIndex + 1] ?? null;
}

function isTextNode(node) {
  return node?.kind === "text";
}

function dispatchRuntimeEvent(root, event) {
  const normalizedEvent = normalizeRuntimeEvent(event);
  const targetNode = findNodeByShadowId(root, normalizedEvent.targetId);
  if (!targetNode) {
    return;
  }

  applyRuntimeEventState(targetNode, normalizedEvent);
  const handler = targetNode.listeners[normalizedEvent.type];
  if (typeof handler === "function") {
    handler(createRuntimeEvent(targetNode, normalizedEvent));
  }
}

function normalizeRuntimeEvent(event) {
  if (!event || typeof event !== "object") {
    throw new TypeError("runtime event must be an object");
  }

  const type = typeof event.type === "string" ? event.type.toLowerCase() : "";
  const targetId = typeof event.targetId === "string" ? event.targetId : "";
  if (!type || !targetId) {
    throw new TypeError("runtime event requires string type and targetId");
  }

  const normalizedEvent = { targetId, type };
  if (typeof event.value === "string") {
    normalizedEvent.value = event.value;
  }
  return normalizedEvent;
}

function findNodeByShadowId(node, targetId) {
  if (!node || node.kind !== "element") {
    return null;
  }

  if (node.attributes["data-shadow-id"] === targetId) {
    return node;
  }

  for (const child of node.children) {
    const match = child.kind === "element"
      ? findNodeByShadowId(child, targetId)
      : null;
    if (match) {
      return match;
    }
  }

  return null;
}

function renderMountToDocument(root) {
  return renderToDocument(root);
}

function applyRuntimeEventState(node, event) {
  if ((event.type === "change" || event.type === "input") && "value" in event) {
    node.value = event.value;
  }
}

function createRuntimeEvent(targetNode, event) {
  return {
    currentTarget: targetNode,
    preventDefault() {},
    target: targetNode,
    targetId: event.targetId,
    type: event.type,
  };
}

function resolveAnchorIndex(parent, anchor) {
  if (anchor == null) {
    return parent.children.length;
  }

  const anchorIndex = parent.children.indexOf(anchor);
  return anchorIndex === -1 ? parent.children.length : anchorIndex;
}

function detachNode(node) {
  if (!node?.parent) {
    return;
  }

  const siblings = node.parent.children;
  const nodeIndex = siblings.indexOf(node);
  if (nodeIndex >= 0) {
    siblings.splice(nodeIndex, 1);
  }
  node.parent = null;
}

function serializeNode(node) {
  if (node.kind === "text") {
    return escapeHtml(node.value);
  }

  assertElementNode(node, "serializeNode");
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

function assertTextNode(node, operation) {
  if (!node || node.kind !== "text") {
    throw new TypeError(`${operation} expects a text node`);
  }
}

function attachElementAccessors(node) {
  Object.defineProperties(node, {
    value: {
      enumerable: false,
      get() {
        return node.attributes.value ?? "";
      },
      set(nextValue) {
        if (nextValue == null) {
          delete node.attributes.value;
          return;
        }
        node.attributes.value = String(nextValue);
      },
    },
    name: {
      enumerable: false,
      get() {
        return node.attributes.name ?? "";
      },
      set(nextValue) {
        if (nextValue == null) {
          delete node.attributes.name;
          return;
        }
        node.attributes.name = String(nextValue);
      },
    },
  });

  node.getAttribute = (name) => node.attributes[name] ?? null;
  node.setAttribute = (name, value) => {
    if (value == null) {
      delete node.attributes[name];
      return;
    }
    node.attributes[name] = String(value);
  };
}

function createRenderer({
  createElement,
  createSlotNode,
  createTextNode,
  getFirstChild,
  getNextSibling,
  getParentNode,
  insertNode,
  isTextNode,
  removeNode,
  replaceText,
  setProperty,
}) {
  function insert(parent, accessor, marker, initial) {
    if (marker !== undefined && !initial) {
      initial = [];
    }
    if (typeof accessor !== "function") {
      return insertExpression(parent, accessor, initial, marker);
    }

    createRenderEffect((current) =>
      insertExpression(parent, accessor(), current, marker), initial);
  }

  function insertExpression(parent, value, current, marker, unwrapArray) {
    while (typeof current === "function") {
      current = current();
    }
    if (value === current) {
      return current;
    }

    const valueType = typeof value;
    const multi = marker !== undefined;

    if (valueType === "string" || valueType === "number") {
      if (valueType === "number") {
        value = value.toString();
      }
      if (multi) {
        let node = current[0];
        if (node && isTextNode(node)) {
          replaceText(node, value);
        } else {
          node = createTextNode(value);
        }
        current = cleanChildren(parent, current, marker, node);
      } else if (current !== "" && typeof current === "string") {
        replaceText(getFirstChild(parent), current = value);
      } else {
        cleanChildren(parent, current, marker, createTextNode(value));
        current = value;
      }
    } else if (value == null || valueType === "boolean") {
      current = cleanChildren(parent, current, marker);
    } else if (valueType === "function") {
      createRenderEffect(() => {
        let nextValue = value();
        while (typeof nextValue === "function") {
          nextValue = nextValue();
        }
        current = insertExpression(parent, nextValue, current, marker);
      });
      return () => current;
    } else if (Array.isArray(value)) {
      const normalized = [];
      if (normalizeIncomingArray(normalized, value, unwrapArray)) {
        createRenderEffect(() =>
          current = insertExpression(parent, normalized, current, marker, true));
        return () => current;
      }

      if (normalized.length === 0) {
        const replacement = cleanChildren(parent, current, marker);
        if (multi) {
          return current = replacement;
        }
      } else if (Array.isArray(current)) {
        if (current.length === 0) {
          appendNodes(parent, normalized, marker);
        } else {
          reconcileArrays(parent, current, normalized);
        }
      } else if (current == null || current === "") {
        appendNodes(parent, normalized);
      } else {
        reconcileArrays(
          parent,
          (multi && current) || [getFirstChild(parent)],
          normalized,
        );
      }

      current = normalized;
    } else {
      if (Array.isArray(current)) {
        if (multi) {
          return current = cleanChildren(parent, current, marker, value);
        }
        cleanChildren(parent, current, null, value);
      } else if (current == null || current === "" || !getFirstChild(parent)) {
        insertNode(parent, value);
      } else {
        replaceNode(parent, value, getFirstChild(parent));
      }
      current = value;
    }

    return current;
  }

  function normalizeIncomingArray(normalized, array, unwrap) {
    let dynamic = false;
    for (let index = 0; index < array.length; index += 1) {
      let item = array[index];
      const itemType = typeof item;
      if (item == null || item === true || item === false) {
        continue;
      }
      if (Array.isArray(item)) {
        dynamic = normalizeIncomingArray(normalized, item) || dynamic;
      } else if (itemType === "string" || itemType === "number") {
        normalized.push(createTextNode(item));
      } else if (itemType === "function") {
        if (unwrap) {
          while (typeof item === "function") {
            item = item();
          }
          dynamic = normalizeIncomingArray(
            normalized,
            Array.isArray(item) ? item : [item],
          ) || dynamic;
        } else {
          normalized.push(item);
          dynamic = true;
        }
      } else {
        normalized.push(item);
      }
    }
    return dynamic;
  }

  function reconcileArrays(parent, current, next) {
    let nextLength = next.length;
    let currentEnd = current.length;
    let nextEnd = nextLength;
    let currentStart = 0;
    let nextStart = 0;
    const after = getNextSibling(current[currentEnd - 1]);
    let indexMap = null;

    while (currentStart < currentEnd || nextStart < nextEnd) {
      if (current[currentStart] === next[nextStart]) {
        currentStart += 1;
        nextStart += 1;
        continue;
      }

      while (current[currentEnd - 1] === next[nextEnd - 1]) {
        currentEnd -= 1;
        nextEnd -= 1;
      }

      if (currentEnd === currentStart) {
        const anchor = nextEnd < nextLength
          ? (nextStart ? getNextSibling(next[nextStart - 1]) : next[nextEnd - nextStart])
          : after;
        while (nextStart < nextEnd) {
          insertNode(parent, next[nextStart], anchor);
          nextStart += 1;
        }
      } else if (nextEnd === nextStart) {
        while (currentStart < currentEnd) {
          if (!indexMap || !indexMap.has(current[currentStart])) {
            removeNode(parent, current[currentStart]);
          }
          currentStart += 1;
        }
      } else if (
        current[currentStart] === next[nextEnd - 1] &&
        next[nextStart] === current[currentEnd - 1]
      ) {
        const node = getNextSibling(current[--currentEnd]);
        insertNode(parent, next[nextStart++], getNextSibling(current[currentStart++]));
        insertNode(parent, next[--nextEnd], node);
        current[currentEnd] = next[nextEnd];
      } else {
        if (!indexMap) {
          indexMap = new Map();
          for (let index = nextStart; index < nextEnd; index += 1) {
            indexMap.set(next[index], index);
          }
        }

        const index = indexMap.get(current[currentStart]);
        if (index != null) {
          if (nextStart < index && index < nextEnd) {
            let sequence = 1;
            for (
              let cursor = currentStart + 1;
              cursor < currentEnd && cursor < nextEnd;
              cursor += 1
            ) {
              const nextIndex = indexMap.get(current[cursor]);
              if (nextIndex == null || nextIndex !== index + sequence) {
                break;
              }
              sequence += 1;
            }

            if (sequence > index - nextStart) {
              const node = current[currentStart];
              while (nextStart < index) {
                insertNode(parent, next[nextStart++], node);
              }
            } else {
              replaceNode(parent, next[nextStart++], current[currentStart++]);
            }
          } else {
            currentStart += 1;
          }
        } else {
          removeNode(parent, current[currentStart++]);
        }
      }
    }
  }

  function cleanChildren(parent, current, marker, replacement) {
    if (marker === undefined) {
      let removed = getFirstChild(parent);
      while (removed) {
        removeNode(parent, removed);
        removed = getFirstChild(parent);
      }
      if (replacement) {
        insertNode(parent, replacement);
      }
      return replacement ?? "";
    }

    const node = replacement || createSlotNode();
    if (current.length) {
      let inserted = false;
      for (let index = current.length - 1; index >= 0; index -= 1) {
        const child = current[index];
        if (node === child) {
          inserted = true;
          continue;
        }

        const isParent = getParentNode(child) === parent;
        if (!inserted && index === 0) {
          if (isParent) {
            replaceNode(parent, node, child);
          } else {
            insertNode(parent, node, marker);
          }
        } else if (isParent) {
          removeNode(parent, child);
        }
      }
    } else {
      insertNode(parent, node, marker);
    }

    return [node];
  }

  function appendNodes(parent, array, marker) {
    for (const node of array) {
      insertNode(parent, node, marker);
    }
  }

  function replaceNode(parent, next, current) {
    insertNode(parent, next, current);
    removeNode(parent, current);
  }

  function spreadExpression(node, props, prevProps = {}, skipChildren) {
    props ||= {};

    if (!skipChildren) {
      createRenderEffect(() =>
        prevProps.children = insertExpression(
          node,
          props.children,
          prevProps.children,
        ));
    }

    createRenderEffect(() => props.ref && props.ref(node));
    createRenderEffect(() => {
      for (const prop in props) {
        if (prop === "children" || prop === "ref") {
          continue;
        }
        const value = props[prop];
        if (value === prevProps[prop]) {
          continue;
        }
        setProperty(node, prop, value, prevProps[prop]);
        prevProps[prop] = value;
      }
    });
    return prevProps;
  }

  return {
    createComponent: solidCreateComponent,
    createElement,
    createTextNode,
    effect: createRenderEffect,
    insert,
    insertNode,
    memo: memoHelper,
    mergeProps: solidMergeProps,
    render(code, element) {
      let disposer;
      solidCreateRoot((dispose) => {
        disposer = dispose;
        insert(element, code());
      });
      return disposer;
    },
    setProp(node, name, value, previous) {
      setProperty(node, name, value, previous);
      return value;
    },
    spread(node, accessor, skipChildren) {
      if (typeof accessor === "function") {
        createRenderEffect((current) =>
          spreadExpression(node, accessor(), current, skipChildren));
      } else {
        spreadExpression(node, accessor, undefined, skipChildren);
      }
    },
    use(fn, element, arg) {
      return solidUntrack(() => fn(element, arg));
    },
  };
}
