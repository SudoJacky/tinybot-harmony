import { Attachment } from './Productivity';
import { ThreadData } from './Conversation';
import { toolReceipts } from './Agent';

export function threadAttachments(thread: ThreadData): Attachment[] {
  const result = (thread.attachments || []).concat(...thread.messages.map((message) => message.attachments || []));
  result.push(...(thread.pendingInputs || []).flatMap((input) => input.attachments || []));
  for (const message of thread.messages) {
    for (const step of message.steps || []) {
      result.push(...step.steering?.attachments || []);
      for (const tool of toolReceipts(step.tools)) { if (tool.previewScreenshot) { result.push(tool.previewScreenshot.image); }
        if (tool.inspectedImage) { result.push(tool.inspectedImage); }
        for (const frame of tool.browserObservation?.frames || []) { result.push(frame.image); } }
    }
  }
  return result;
}
