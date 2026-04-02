import { finalizeMessage } from "./message.js";

const fileMessage = await Deno.readTextFile(
  new URL("./message.txt", import.meta.url),
);
const delayedMessage = await new Promise((resolve) =>
  setTimeout(() => resolve(fileMessage.trim()), 1),
);

globalThis.RUNTIME_SMOKE_RESULT = await finalizeMessage(
  "HELLO FROM DENO_RUNTIME",
  delayedMessage,
);
