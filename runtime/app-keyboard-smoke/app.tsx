import { createSignal, For } from "@shadow/sdk";

export const runtimeDocumentCss = `
:root {
  color-scheme: dark;
}

* {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  min-height: 100%;
}

body {
  min-height: 100vh;
  background: linear-gradient(180deg, #020617 0%, #0f172a 45%, #134e4a 100%);
  color: #e2e8f0;
  font: 500 16px/1.45 "Google Sans", "Roboto", "Droid Sans", "Noto Sans", "DejaVu Sans", sans-serif;
}

#shadow-blitz-root {
  min-height: 100vh;
}

.keyboard-shell {
  min-height: 100vh;
  padding: 28px;
}

.keyboard-card {
  min-height: 100%;
  display: flex;
  flex-direction: column;
  gap: 18px;
  padding: 30px 28px;
  border-radius: 32px;
  background: rgba(2, 6, 23, 0.82);
  border: 1px solid rgba(148, 163, 184, 0.18);
  box-shadow: 0 28px 90px rgba(0, 0, 0, 0.36);
}

.keyboard-eyebrow {
  margin: 0;
  color: #5eead4;
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
}

.keyboard-headline {
  margin: 0;
  color: #f8fafc;
  font-size: 58px;
  line-height: 0.96;
  letter-spacing: -0.05em;
}

.keyboard-body {
  margin: 0;
  color: #cbd5e1;
  font-size: 26px;
  line-height: 1.34;
}

.keyboard-input {
  width: 100%;
  min-height: 96px;
  padding: 22px 24px;
  border-radius: 24px;
  border: 2px solid rgba(94, 234, 212, 0.32);
  background: rgba(15, 23, 42, 0.88);
  color: #f8fafc;
  font: inherit;
  font-size: 34px;
}

.keyboard-meta {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 22px 24px;
  border-radius: 24px;
  background: rgba(8, 47, 73, 0.44);
  border: 1px solid rgba(125, 211, 252, 0.16);
}

.keyboard-meta-line {
  margin: 0;
  color: #dbeafe;
  font-size: 20px;
  line-height: 1.4;
}

.keyboard-history {
  display: flex;
  flex-direction: column;
  gap: 10px;
  margin: 0;
  padding: 0;
  list-style: none;
}

.keyboard-history-item {
  padding: 16px 18px;
  border-radius: 20px;
  background: rgba(15, 23, 42, 0.72);
  border: 1px solid rgba(148, 163, 184, 0.16);
  color: #e2e8f0;
  font-family: "Droid Sans Mono", "DejaVu Sans Mono", "Cutive Mono", monospace;
  font-size: 18px;
  line-height: 1.4;
}
`;

type RuntimeKeyboardEvent = {
  altKey: boolean;
  code: string;
  ctrlKey: boolean;
  key: string;
  metaKey: boolean;
  shiftKey: boolean;
};

export function renderApp() {
  const [draft, setDraft] = createSignal("");
  const [focused, setFocused] = createSignal(false);
  const [selection, setSelection] = createSignal("none");
  const [history, setHistory] = createSignal<string[]>([]);

  function rememberKey(event: RuntimeKeyboardEvent) {
    const modifiers = [
      event.shiftKey ? "shift" : null,
      event.ctrlKey ? "ctrl" : null,
      event.altKey ? "alt" : null,
      event.metaKey ? "meta" : null,
    ].filter(Boolean).join("+") || "none";

    setHistory((entries) =>
      [
        ...entries,
        `${event.key} / ${event.code} / ${modifiers}`,
      ].slice(-4)
    );
  }

  return (
    <main class="keyboard-shell">
      <section class="keyboard-card">
        <p class="keyboard-eyebrow">Shadow Keyboard</p>
        <h1 class="keyboard-headline">English text seam</h1>
        <p class="keyboard-body">
          Host smoke for focus, keydown metadata, plain text input, and
          selection updates.
        </p>
        <input
          class="keyboard-input"
          data-shadow-id="draft"
          type="text"
          value={draft()}
          onBlur={() => setFocused(false)}
          onFocus={() => setFocused(true)}
          onInput={(event) => {
            setDraft(event.currentTarget.value);
            setSelection(
              `${event.selectionStart ?? 0}-${event.selectionEnd ?? 0}:${
                event.selectionDirection ?? "none"
              }`,
            );
          }}
          onKeyDown={(event) =>
            rememberKey({
              altKey: event.altKey,
              code: event.code,
              ctrlKey: event.ctrlKey,
              key: event.key,
              metaKey: event.metaKey,
              shiftKey: event.shiftKey,
            })}
        />
        <section class="keyboard-meta">
          <p class="keyboard-meta-line">
            Focus: {focused() ? "focused" : "blurred"}
          </p>
          <p class="keyboard-meta-line">Draft: {draft() || "(empty)"}</p>
          <p class="keyboard-meta-line">Selection: {selection()}</p>
        </section>
        <ul class="keyboard-history">
          <For each={history()}>
            {(entry) => <li class="keyboard-history-item">{entry}</li>}
          </For>
        </ul>
      </section>
    </main>
  );
}
