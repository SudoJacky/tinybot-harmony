import { AppData } from './Conversation';
import { toolReceipts } from './Agent';
import { Attachment } from './Productivity';

interface StorageThread { title: string; messageCount: number; }

// A point-in-time view for storage management. Message bodies, credentials and
// tool payloads are not needed to count files or protect referenced attachments.
export class StorageCatalog {
  readonly sessions: Map<string, StorageThread> = new Map();
  readonly workspaces: Map<string, string> = new Map();
  readonly attachments: Map<string, string> = new Map();

  constructor(data: AppData) {
    for (const project of data.projects || []) { this.workspaces.set(project.workspaceId, project.name); }
    for (const thread of data.threads) {
      this.sessions.set(thread.id, { title: thread.title, messageCount: thread.messages.length });
      if (!thread.projectId) { this.workspaces.set(thread.id, thread.title || thread.id); }
      for (const item of thread.attachments || []) { this.add(item); }
      for (const input of thread.pendingInputs || []) {
        for (const item of input.attachments || []) { this.add(item); }
      }
      for (const message of thread.messages) {
        for (const item of message.attachments || []) { this.add(item); }
        for (const step of message.steps || []) {
          for (const item of step.steering?.attachments || []) { this.add(item); }
          for (const tool of toolReceipts(step.tools)) {
            if (tool.previewScreenshot) { this.add(tool.previewScreenshot.image); }
            if (tool.inspectedImage) { this.add(tool.inspectedImage); }
            for (const frame of tool.browserObservation?.frames || []) { this.add(frame.image); }
          }
        }
      }
    }
  }

  private add(item: Attachment): void {
    if (item && item.path && !item.workspaceId) { this.attachments.set(item.path, item.name); }
  }
}
