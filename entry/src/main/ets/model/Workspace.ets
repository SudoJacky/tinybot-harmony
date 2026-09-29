// Derive paths at runtime: the sandbox location can change after data migration.
export function threadWorkspacePath(rootDir: string, threadId: string): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(threadId)) {
    throw new Error('会话 ID 无效，无法创建工作区。');
  }
  return rootDir + '/' + threadId;
}
