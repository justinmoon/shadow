import { createSignal } from "@shadow/app-runtime-solid";

function describeEvent(event: {
  currentTarget: { name: string; value: string };
  targetId: string;
  type: string;
}) {
  return `${event.type}:${event.targetId}:${event.currentTarget.name}:${event.currentTarget.value}`;
}

export function renderApp() {
  const [draft, setDraft] = createSignal("ready");
  const [focusState, setFocusState] = createSignal("blurred");
  const [lastEvent, setLastEvent] = createSignal("idle");

  return (
    <main class="compose">
      <label class="field">
        <span>Draft</span>
        <input
          class="field-input"
          data-shadow-id="draft"
          name="draft"
          value={draft()}
          onFocus={(event) => {
            setFocusState(`focus:${event.targetId}`);
            setLastEvent(describeEvent(event));
          }}
          onInput={(event) => {
            setDraft(event.currentTarget.value);
            setLastEvent(describeEvent(event));
          }}
          onBlur={(event) => {
            setFocusState("blurred");
            setLastEvent(describeEvent(event));
          }}
        />
      </label>
      <p class="status">Focus: {focusState()}</p>
      <p class="status">Last: {lastEvent()}</p>
      <p class="preview">Preview: {draft()}</p>
    </main>
  );
}
