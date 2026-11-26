export enum ConversationImageStyle {
  Editorial,
  Poster,
  Transcript
}

export interface ConversationImageTheme {
  page: number;
  ink: number;
  muted: number;
  rule: number;
  surface: number;
  accent: number;
  pagePadding: number;
  titleSize: number;
}

const IMAGE_THEMES: ConversationImageTheme[] = [
  { page: 0xfff7f3eb, ink: 0xff28241e, muted: 0xff665b50, rule: 0xffd6cbbd,
    surface: 0xffede5d8, accent: 0xff28241e, pagePadding: 24, titleSize: 30 },
  { page: 0xff20202a, ink: 0xfffff6ee, muted: 0xffc2b8cb, rule: 0xff48414f,
    surface: 0xff34313e, accent: 0xfff7bea9, pagePadding: 24, titleSize: 32 },
  { page: 0xfff4f6f5, ink: 0xff1e2522, muted: 0xff4e5a55, rule: 0xffd2dad5,
    surface: 0xffdeebe2, accent: 0xff1e2522, pagePadding: 16, titleSize: 25 }
];

export function conversationImageTheme(style: ConversationImageStyle): ConversationImageTheme {
  return IMAGE_THEMES[style];
}
