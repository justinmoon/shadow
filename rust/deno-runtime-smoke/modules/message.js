export async function finalizeMessage(hostMessage, delayedMessage) {
  const suffix = await Promise.resolve(`AND ${delayedMessage}`);
  return `${hostMessage} ${suffix}`;
}
