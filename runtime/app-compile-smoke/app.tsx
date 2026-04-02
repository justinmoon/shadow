import { createSignal } from "@shadow/app-runtime-solid";

const SHELL_STYLE =
  "width:384px;height:720px;display:flex;flex-direction:column;justify-content:center;align-items:center;gap:20px;padding:32px;box-sizing:border-box;color:#f4fbff;font-family:system-ui,sans-serif";
const TITLE_STYLE =
  "margin:0;font-size:42px;line-height:0.95;letter-spacing:-0.05em;text-align:center";
const LEDE_STYLE =
  "margin:0;max-width:280px;color:#bfd5df;font-size:18px;line-height:1.35;text-align:center";
const BUTTON_STYLE =
  "width:100%;max-width:280px;min-height:96px;border:none;border-radius:28px;color:#04212d;font-size:36px;font-weight:800;line-height:1;padding:20px 24px;box-shadow:0 24px 72px rgba(0,0,0,0.35)";
const PANEL_STYLE =
  "width:100%;max-width:280px;display:flex;flex-direction:column;gap:18px;padding:22px;border-radius:36px;background:rgba(6,18,27,0.46)";
const BUTTON_CONTENT_STYLE =
  "display:flex;flex-direction:column;align-items:center;gap:16px";
const STATUS_ROW_STYLE =
  "display:flex;align-items:center;justify-content:center;gap:10px;width:100%";
const PULSE_STYLE =
  "height:14px;border-radius:999px;background:rgba(4,33,45,0.78);box-shadow:inset 0 1px 2px rgba(255,255,255,0.24)";
const LABEL_STYLE =
  "display:flex;align-items:center;justify-content:center;min-height:24px";

function shellStyle(armed: boolean) {
  const gradient = armed
    ? "linear-gradient(180deg,#10293a,#09131c)"
    : "linear-gradient(180deg,#09131c,#10293a)";
  return `${SHELL_STYLE};background:${gradient}`;
}

function panelStyle(armed: boolean) {
  const border = armed
    ? "1px solid rgba(255,196,112,0.34)"
    : "1px solid rgba(121,212,255,0.18)";
  const glow = armed
    ? "0 32px 96px rgba(255,138,66,0.18)"
    : "0 24px 72px rgba(0,0,0,0.28)";
  return `${PANEL_STYLE};border:${border};box-shadow:inset 0 1px 0 rgba(255,255,255,0.08),${glow}`;
}

function buttonStyle(armed: boolean) {
  const gradient = armed
    ? "linear-gradient(135deg,#ffd06b,#ff8a42)"
    : "linear-gradient(135deg,#79d4ff,#2fb8ff)";
  const lift = armed ? "-8px" : "0px";
  return `${BUTTON_STYLE};background:${gradient};transform:translateY(${lift})`;
}

function pulseStyle(active: boolean) {
  const width = active ? "148px" : "78px";
  const opacity = active ? "1" : "0.38";
  return `${PULSE_STYLE};width:${width};opacity:${opacity}`;
}

type CounterProps = {
  initialCount: number;
  title: string;
};

function Counter(props: CounterProps) {
  const [count, setCount] = createSignal(props.initialCount);
  const litSegments = () => ((count() - 1) % 3) + 1;
  const armed = () => count() % 2 === 0;

  return (
    <section style={panelStyle(armed())}>
      <button
        class="primary"
        data-shadow-id="counter"
        style={buttonStyle(armed())}
        onClick={() => setCount((value) => value + 1)}
      >
        <div style={BUTTON_CONTENT_STYLE}>
          <div style={STATUS_ROW_STYLE}>
            <span style={pulseStyle(litSegments() >= 1)} />
            <span style={pulseStyle(litSegments() >= 2)} />
            <span style={pulseStyle(litSegments() >= 3)} />
          </div>
          <div style={LABEL_STYLE}>
            {props.title} {count()}
          </div>
        </div>
      </button>
    </section>
  );
}

export function renderApp() {
  return (
    <main class="shell" style={shellStyle(false)}>
      <h1 style={TITLE_STYLE}>Shadow Runtime Smoke</h1>
      <p style={LEDE_STYLE}>Tap the button on the phone screen.</p>
      <Counter title="Count" initialCount={1} />
    </main>
  );
}
