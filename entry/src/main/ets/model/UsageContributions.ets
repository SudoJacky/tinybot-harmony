import { UsageDay, usageDate } from './UsageStatistics';

export class ContributionCell {
  date: string = '';
  day?: UsageDay;
  level: number = 0;
}

export class ContributionWeek {
  key: string = '';
  month: string = '';
  cells: ContributionCell[] = [];
}

export class UsageContributions {
  weeks: ContributionWeek[] = [];
  activeDays: number = 0;
  longestStreak: number = 0;
}

// Keep calendar arithmetic local (including DST) and pad to complete Monday-first weeks.
// Small ranges retain a 13-week context; padding is not selectable or counted as activity.
export function usageContributions(days: UsageDay[]): UsageContributions {
  const result = new UsageContributions();
  if (days.length === 0) { return result; }
  const byDate: Map<string, UsageDay> = new Map();
  let streak = 0;
  let peak = 1;
  for (const day of days) {
    byDate.set(day.date, day);
    streak = day.calls > 0 ? streak + 1 : 0;
    if (day.calls > 0) { result.activeDays++; }
    result.longestStreak = Math.max(result.longestStreak, streak);
    peak = Math.max(peak, day.total);
  }
  const last = days[days.length - 1].date.split('-');
  const end = new Date(Number(last[0]), Number(last[1]) - 1, Number(last[2]));
  end.setDate(end.getDate() + 6 - (end.getDay() + 6) % 7);
  const first = days[0].date.split('-');
  const start = new Date(Number(first[0]), Number(first[1]) - 1, Number(first[2]));
  start.setDate(start.getDate() - (start.getDay() + 6) % 7);
  const context = new Date(end.getTime()); context.setDate(context.getDate() - 90);
  if (context.getTime() < start.getTime()) { start.setTime(context.getTime()); }
  const cursor = new Date(start.getTime());
  let previousMonth = -1;
  while (cursor.getTime() <= end.getTime()) {
    const week = new ContributionWeek(); week.key = usageDate(cursor.getTime());
    if (cursor.getMonth() !== previousMonth) {
      week.month = String(cursor.getMonth() + 1); previousMonth = cursor.getMonth();
    }
    for (let index = 0; index < 7; index++) {
      const cell = new ContributionCell(); cell.date = usageDate(cursor.getTime()); cell.day = byDate.get(cell.date);
      if (cell.day && cell.day.total > 0) { cell.level = Math.min(4, Math.ceil(cell.day.total / peak * 4)); }
      week.cells.push(cell); cursor.setDate(cursor.getDate() + 1);
    }
    result.weeks.push(week);
  }
  return result;
}
