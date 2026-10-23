export interface Announcement {
  id: string;
  title: string;
  body: string;
}

interface AnnouncementFeed {
  schemaVersion: number;
  announcement: Announcement | null;
}

// One active announcement. Reuse an ID for typo fixes; publish a new ID to notify again.
// { "schemaVersion": 1, "announcement": { "id": "2026-10-23-1", "title": "...", "body": "..." } }
// Set announcement to null to withdraw it. Body uses the app's native Markdown renderer, not HTML.
export function parseAnnouncement(source: string): Announcement | null {
  const feed = JSON.parse(source) as AnnouncementFeed;
  if (!feed || feed.schemaVersion !== 1) { throw new Error('Invalid announcement JSON schemaVersion'); }
  if (feed.announcement === null) { return null; }
  const item = feed.announcement;
  if (!item || typeof item.id !== 'string' || !/^[A-Za-z0-9._-]{1,128}$/.test(item.id) ||
    typeof item.title !== 'string' || !item.title.trim() || item.title.length > 120 ||
    typeof item.body !== 'string' || !item.body.trim() || item.body.length > 20000) {
    throw new Error('Invalid announcement JSON content');
  }
  return { id: item.id, title: item.title, body: item.body };
}
