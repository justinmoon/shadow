import { createSignal } from "@shadow/app-runtime-solid";

function describeSelection(event: {
  currentTarget: {
    selectionDirection: string | null;
    selectionEnd: number | null;
    selectionStart: number | null;
    value: string;
  };
  selectionDirection: string | null;
  selectionEnd: number | null;
  selectionStart: number | null;
}) {
  return `Selection: ${event.selectionStart}-${event.selectionEnd} ${event.selectionDirection ?? "none"} (${event.currentTarget.value})`;
}

export function renderApp() {
  const [draft, setDraft] = createSignal("ready");
  const [selection, setSelection] = createSignal("Selection: none");

  return (
    <main class="compose">
      <label class="field">
        <span>Draft</span>
        <input
          class="field-input"
          data-shadow-id="draft"
          name="draft"
          value={draft()}
          onInput={(event) => {
            setDraft(event.currentTarget.value);
            setSelection(describeSelection(event));
          }}
        />
      </label>
      <p class="status">{selection()}</p>
      <p class="preview">Preview: {draft()}</p>
    </main>
  );
}
