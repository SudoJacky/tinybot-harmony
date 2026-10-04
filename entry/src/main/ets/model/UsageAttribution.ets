import { RequestUsage, UsageOrigin } from './Usage';
import { ThreadData, MessageData } from './Conversation';
import { AgentStep } from './Agent';

// Join only existing ledger IDs; copied transcripts must never create extra usage.
// Ambiguous legacy IDs (e.g. copied into branches) remain unassigned.
export function attributeLegacyUsage(records: RequestUsage[], threads: ThreadData[]): RequestUsage[] {
  const needed = new Set(records.filter((item) => !item.origin?.threadId).map((item) => item.id));
  if (needed.size === 0) { return records; }
  const candidates = new Map<string, UsageOrigin>();
  const ambiguous = new Set<string>();
  const collect = (steps: AgentStep[], origin: UsageOrigin): void => {
    for (let index = 0; index < steps.length; index++) {
      const id = steps[index].usage?.id; if (!id || !needed.has(id)) { continue; }
      const found = candidates.get(id);
      if (found && (found.threadId !== origin.threadId || found.turnId !== origin.turnId || found.attemptId !== origin.attemptId)) { ambiguous.add(id); }
      else { const copy = JSON.parse(JSON.stringify(origin)) as UsageOrigin; copy.step = index + 1; candidates.set(id, copy); }
    }
  };
  for (const thread of threads) {
    let user: MessageData | undefined = undefined;
    const users = new Map<string, MessageData>();
    for (const message of thread.messages) {
      if (message.role === 'user') { user = message; }
      if (user) { users.set(message.id, user); }
      if (message.role !== 'assistant') { continue; }
      collect(message.steps || [], { threadId: thread.id, threadTitle: thread.title, turnId: user?.id || message.id,
        turnLabel: user?.content.slice(0, 80), purpose: 'conversation' });
    }
    for (const team of thread.teams || []) {
      const user = team.ownerMessageId ? users.get(team.ownerMessageId) : undefined;
      const base: UsageOrigin = { threadId: thread.id, threadTitle: thread.title, turnId: user?.id || team.id,
        turnLabel: (user?.content || team.goal).slice(0, 80), teamId: team.id, purpose: 'team_planning' };
      collect(team.planning.steps, base);
      for (const task of team.tasks) {
        for (let index = 0; index < task.attempts.length; index++) {
          const attempt = task.attempts[index]; const origin = JSON.parse(JSON.stringify(base)) as UsageOrigin;
          origin.purpose = 'team_task'; origin.taskId = task.task.id; origin.taskTitle = task.task.title;
          origin.memberName = team.members.find((item) => item.id === task.task.memberId)?.name;
          origin.attemptId = attempt.id; origin.attempt = index + 1;
          collect(attempt.turn.steps, origin);
        }
      }
    }
  }
  return records.map((record: RequestUsage): RequestUsage => {
    if (record.origin?.threadId || ambiguous.has(record.id) || !candidates.has(record.id)) { return record; }
    const copy = JSON.parse(JSON.stringify(record)) as RequestUsage; copy.origin = candidates.get(record.id); return copy;
  });
}
