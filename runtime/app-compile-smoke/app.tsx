type CounterProps = {
  count: number;
  title: string;
};

function Counter(props: CounterProps) {
  return (
    <button
      class="primary"
      data-shadow-id="counter"
      onClick={() => props.count + 1}
    >
      {props.title} {props.count}
    </button>
  );
}

export function renderApp() {
  return (
    <main class="shell">
      <h1>Shadow Runtime Smoke</h1>
      <Counter title="Count" count={1} />
    </main>
  );
}
