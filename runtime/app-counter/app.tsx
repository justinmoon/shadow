import {
  clearLifecycleHandler,
  createEffect,
  createSignal,
  getLifecycleState,
  getWindowMetrics,
  onCleanup,
  onMount,
  setLifecycleHandler,
} from "@shadow/sdk";

const SHELL_STYLE =
  "width:100%;height:100%;display:flex;align-items:center;justify-content:center;padding:28px;box-sizing:border-box";
const STACK_STYLE =
  "display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;width:100%;max-width:320px";
const CARD_STYLE =
  "width:280px;height:280px;display:flex;flex-direction:column;justify-content:space-between;padding:22px;box-sizing:border-box";
const ACCENT_STYLE = "display:block;width:100%;height:44px";
const ROW_STYLE =
  "display:flex;align-items:center;justify-content:center;gap:14px;width:100%";
const DOT_STYLE = "display:block;width:44px;height:44px";
const FOOT_STYLE = "display:block;width:100%;height:22px";

function shellStyle(active: boolean) {
  return `${SHELL_STYLE};background:${active ? "#2a1209" : "#0b1630"}`;
}

function cardStyle(active: boolean) {
  return `${CARD_STYLE};background:${active ? "#ff8a42" : "#2fb8ff"}`;
}

function accentStyle(active: boolean) {
  return `${ACCENT_STYLE};background:${active ? "#ffe0a6" : "#10243b"}`;
}

function dotStyle(active: boolean, enabled: boolean) {
  const background = enabled
    ? active ? "#7b2900" : "#08121b"
    : active
    ? "#ffc98b"
    : "#89daff";
  return `${DOT_STYLE};background:${background}`;
}

function footStyle(active: boolean) {
  return `${FOOT_STYLE};background:${active ? "#7b2900" : "#08121b"}`;
}

type CounterProps = {
  count: number;
  active: boolean;
  onClick: () => void;
};

function Counter(props: CounterProps) {
  const litSegments = () => ((props.count - 1) % 3) + 1;

  return (
    <section
      data-shadow-id="counter"
      data-shadow-card={props.active ? "warm" : "cool"}
      data-shadow-count={String(props.count)}
      style={cardStyle(props.active)}
      onClick={props.onClick}
    >
      <div
        data-shadow-accent={props.active ? "warm" : "cool"}
        style={accentStyle(props.active)}
      />
      <div style={ROW_STYLE}>
        <span style={dotStyle(props.active, litSegments() >= 1)} />
        <span style={dotStyle(props.active, litSegments() >= 2)} />
        <span style={dotStyle(props.active, litSegments() >= 3)} />
      </div>
      <div
        data-shadow-foot={props.active ? "warm" : "cool"}
        style={footStyle(props.active)}
      />
    </section>
  );
}

export function renderApp() {
  const [count, setCount] = createSignal(1);
  const [lifecycleState, setLifecycleState] = createSignal(getLifecycleState());
  const windowMetrics = getWindowMetrics();
  const active = () => count() > 1;

  createEffect(() => {
    const value = count();
    console.error(
      `[shadow-runtime-counter] render count=${value} state=${
        value > 1 ? "warm" : "cool"
      }`,
    );
  });
  setLifecycleHandler(({ state }: { state: string }) => {
    setLifecycleState(state);
    console.error(`[shadow-runtime-counter] lifecycle_state=${state}`);
  });
  onMount(() => {
    console.error(
      `[shadow-runtime-counter] window_metrics surface=${windowMetrics.surfaceWidth}x${windowMetrics.surfaceHeight} safe_area=l${windowMetrics.safeAreaInsets.left} t${windowMetrics.safeAreaInsets.top} r${windowMetrics.safeAreaInsets.right} b${windowMetrics.safeAreaInsets.bottom}`,
    );
  });
  onCleanup(() => {
    clearLifecycleHandler();
  });

  return (
    <main
      class="shell"
      data-shadow-state={active() ? "warm" : "cool"}
      data-shadow-count={String(count())}
      data-shadow-lifecycle={lifecycleState()}
      style={shellStyle(active())}
    >
      <div style={STACK_STYLE}>
        <Counter
          count={count()}
          active={active()}
          onClick={() =>
            setCount((value) => {
              const next = value + 1;
              console.error(
                `[shadow-runtime-counter] counter_incremented count=${next}`,
              );
              return next;
            })}
        />
      </div>
    </main>
  );
}
