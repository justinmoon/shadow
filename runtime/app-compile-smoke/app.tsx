import { createSignal } from "@shadow/app-runtime-solid";

const SHELL_STYLE =
  "width:100%;height:100%;display:flex;flex-direction:column;justify-content:center;align-items:center;gap:24px;padding:32px;box-sizing:border-box;color:#f4fbff;font-family:system-ui,sans-serif;transition:background 120ms ease";
const TITLE_STYLE =
  "margin:0;font-size:42px;line-height:0.95;letter-spacing:-0.05em;text-align:center";
const LEDE_STYLE =
  "margin:0;max-width:280px;color:#bfd5df;font-size:18px;line-height:1.35;text-align:center";
const BUTTON_STYLE =
  "width:100%;max-width:300px;min-height:184px;border:none;border-radius:40px;color:#04212d;font-size:40px;font-weight:800;line-height:1;padding:28px 24px;box-shadow:0 24px 72px rgba(0,0,0,0.35)";
const PANEL_STYLE =
  "width:100%;max-width:320px;display:flex;flex-direction:column;gap:18px;padding:18px;border-radius:44px;background:rgba(6,18,27,0.34)";
const BUTTON_CONTENT_STYLE =
  "display:flex;flex-direction:column;align-items:center;justify-content:center;gap:20px";
const STATUS_ROW_STYLE =
  "display:flex;align-items:center;justify-content:center;gap:10px;width:100%";
const PULSE_STYLE =
  "height:18px;border-radius:999px;background:rgba(4,33,45,0.82);box-shadow:inset 0 1px 2px rgba(255,255,255,0.24)";
const LABEL_STYLE =
  "display:flex;align-items:center;justify-content:center;min-height:32px";
const BADGE_STYLE =
  "width:100%;max-width:300px;height:28px;border-radius:999px;box-shadow:0 16px 32px rgba(0,0,0,0.24)";

function shellStyle(active: boolean) {
  const gradient = active
    ? "linear-gradient(180deg,#3e1606,#120507)"
    : "linear-gradient(180deg,#09131c,#10293a)";
  return `${SHELL_STYLE};background:${gradient}`;
}

function panelStyle(active: boolean) {
  const border = active
    ? "1px solid rgba(255,196,112,0.42)"
    : "1px solid rgba(121,212,255,0.18)";
  const glow = active
    ? "0 32px 96px rgba(255,138,66,0.24)"
    : "0 24px 72px rgba(0,0,0,0.28)";
  return `${PANEL_STYLE};border:${border};box-shadow:inset 0 1px 0 rgba(255,255,255,0.08),${glow}`;
}

function buttonStyle(active: boolean) {
  const gradient = active
    ? "linear-gradient(135deg,#ffd06b,#ff8a42)"
    : "linear-gradient(135deg,#79d4ff,#2fb8ff)";
  const lift = active ? "-18px scale(1.03)" : "0px scale(1)";
  return `${BUTTON_STYLE};background:${gradient};transform:translateY(${lift})`;
}

function pulseStyle(active: boolean) {
  const width = active ? "160px" : "72px";
  const opacity = active ? "1" : "0.38";
  return `${PULSE_STYLE};width:${width};opacity:${opacity}`;
}

function badgeStyle(active: boolean) {
  const gradient = active
    ? "linear-gradient(90deg,#ffb15f,#ff7a2f)"
    : "linear-gradient(90deg,#40c9ff,#1d88ff)";
  return `${BADGE_STYLE};background:${gradient}`;
}

type CounterProps = {
  count: number;
  active: boolean;
  title: string;
  onClick: () => void;
};

function Counter(props: CounterProps) {
  const litSegments = () => ((props.count - 1) % 3) + 1;

  return (
    <section
      data-shadow-id="counter"
      style={panelStyle(props.active)}
      onClick={props.onClick}
    >
      <button
        class="primary"
        style={buttonStyle(props.active)}
        onClick={props.onClick}
      >
        <div style={BUTTON_CONTENT_STYLE}>
          <div style={STATUS_ROW_STYLE}>
            <span style={pulseStyle(litSegments() >= 1)} />
            <span style={pulseStyle(litSegments() >= 2)} />
            <span style={pulseStyle(litSegments() >= 3)} />
          </div>
          <div style={LABEL_STYLE}>
            {props.title} {props.count}
          </div>
        </div>
      </button>
    </section>
  );
}

export function renderApp() {
  const [count, setCount] = createSignal(1);
  const active = () => count() > 1;

  return (
    <main class="shell" style={shellStyle(active())}>
      <h1 style={TITLE_STYLE}>Shadow Runtime Smoke</h1>
      <p style={LEDE_STYLE}>First successful tap latches the card warm.</p>
      <div style={badgeStyle(active())} />
      <Counter
        title="Count"
        count={count()}
        active={active()}
        onClick={() => setCount((value) => value + 1)}
      />
    </main>
  );
}
