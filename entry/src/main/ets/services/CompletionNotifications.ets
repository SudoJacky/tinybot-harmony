import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { SessionService } from './SessionService';

// Completion is a saved user turn, not a network transfer, tool call or idle transition.
export class CompletionNotifications {
  private context?: common.UIAbilityContext;
  private session?: SessionService;
  private unsubscribe?: () => void;
  private foreground: boolean = false;
  private requested: boolean = false;

  attach(session: SessionService, context: common.UIAbilityContext): void {
    this.dispose(); this.session = session; this.context = context;
    this.unsubscribe = session.subscribe((event) => {
      if (event.kind !== 'task-complete' || !event.threadId || !event.messageId || this.foreground) { return; }
      this.publish(session, context, event.threadId, event.messageId)
        .catch((error: Error) => Diagnostics.log('error', 'notification', 'publish_failed',
          { threadId: event.threadId, messageId: event.messageId }, error));
    });
  }

  setForeground(value: boolean): void { this.foreground = value; }

  // Ask only from a foreground user action; queued/background turns cannot open a permission dialog.
  async prepare(): Promise<void> {
    const context = this.context;
    if (!context || !this.foreground || this.requested) { return; }
    this.requested = true;
    try {
      if (!await notificationManager.isNotificationEnabled() && this.foreground && this.context === context) {
        await notificationManager.requestEnableNotification(context);
      }
      Diagnostics.log('info', 'notification', 'authorization_checked',
        { enabled: await notificationManager.isNotificationEnabled() });
    } catch (error) {
      if ((error as BusinessError).code === 1600004) {
        Diagnostics.log('warn', 'notification', 'authorization_denied', undefined, error as Error);
      } else {
        Diagnostics.log('error', 'notification', 'authorization_failed', undefined, error as Error);
      }
    }
  }

  dispose(): void {
    this.unsubscribe?.(); this.unsubscribe = undefined;
    this.session = undefined; this.context = undefined;
  }

  private async publish(session: SessionService, context: common.UIAbilityContext, threadId: string, messageId: string): Promise<void> {
    if (!await notificationManager.isNotificationEnabled()) {
      Diagnostics.log('info', 'notification', 'disabled', { threadId: threadId, messageId: messageId }); return;
    }
    if (this.foreground || this.session !== session) { return; }
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name,
        // Distinct identities keep older notifications pointing at their own conversations.
        uri: 'tinybot-harmony://notification/' + encodeURIComponent(threadId),
        parameters: { tinybotAction: 'continue-chat', tinybotThreadId: threadId } }],
      actionType: wantAgent.OperationType.START_ABILITY, requestCode: 1,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    if (this.foreground || this.session !== session) { return; }
    await notificationManager.publish({
      id: 1, label: 'turn-complete:' + threadId,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      tapDismissed: true, wantAgent: agent,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: t('任务已完成'), text: t('本轮回答已完成，点击查看对话。') }
      }
    });
    Diagnostics.log('info', 'notification', 'published', { threadId: threadId, messageId: messageId });
  }
}

export const completionNotifications = new CompletionNotifications();
