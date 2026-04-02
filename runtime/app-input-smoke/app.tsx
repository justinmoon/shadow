import { createSignal } from "@shadow/app-runtime-solid";

export function renderApp() {
  const [draft, setDraft] = createSignal("ready");

  return (
    <main class="compose">
      <label class="field">
        <span>Draft</span>
        <input
          class="field-input"
          data-shadow-id="draft"
          name="draft"
          value={draft()}
          onChange={(event) => setDraft(event.currentTarget.value)}
        />
      </label>
      <p class="preview">Preview: {draft()}</p>
    </main>
  );
}
