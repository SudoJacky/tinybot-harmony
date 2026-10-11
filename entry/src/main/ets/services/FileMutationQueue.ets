// Shared by all workspace adapters, including tools and user-initiated writes.
const pending: Map<string, Promise<void>> = new Map<string, Promise<void>>();

export async function withFileMutation<T>(path: string, operation: () => Promise<T>): Promise<T> {
  const previous = pending.get(path) || Promise.resolve();
  let release: () => void = () => {};
  const current = new Promise<void>((resolve) => { release = resolve; });
  pending.set(path, current);
  await previous;
  try { return await operation(); }
  finally {
    release();
    if (pending.get(path) === current) { pending.delete(path); }
  }
}
