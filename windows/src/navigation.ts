import {
  Activity,
  CalendarDays,
  CircleUserRound,
  Compass,
  Files,
  FolderOpen,
  HardDrive,
  Heart,
  Images,
  LayoutGrid,
  ListMusic,
  MessageCircle,
  MessagesSquare,
  PhoneOutgoing,
  Smartphone,
  StickyNote,
  Watch,
  type LucideIcon,
} from 'lucide-react';

export type Page =
  | 'overview'
  | 'backups'
  | 'files'
  | 'apps'
  | 'diagnostics'
  | 'messages'
  | 'photos'
  | 'contacts'
  | 'calendar'
  | 'whatsapp'
  | 'notes'
  | 'calls'
  | 'safari'
  | 'music'
  | 'watch'
  | 'health'
  | 'backupfiles'
  | 'settings';

// Mirrors the macOS SidebarSection groups, labels, and signature icon tints.
export type NavGroup = 'Device' | 'Data' | 'Backups' | 'Tools';
export const navGroups: NavGroup[] = ['Device', 'Data', 'Backups', 'Tools'];

export interface NavItem {
  page: Page;
  label: string;
  icon: LucideIcon;
  group: NavGroup;
  tint: string;
}

export const navigation: NavItem[] = [
  { page: 'overview', label: 'Devices', icon: Smartphone, group: 'Device', tint: 'accent' },
  { page: 'messages', label: 'Messages', icon: MessageCircle, group: 'Data', tint: 'green' },
  { page: 'whatsapp', label: 'WhatsApp', icon: MessagesSquare, group: 'Data', tint: 'whatsapp' },
  { page: 'photos', label: 'Photos', icon: Images, group: 'Data', tint: 'orange' },
  { page: 'apps', label: 'Apps', icon: LayoutGrid, group: 'Data', tint: 'indigo' },
  { page: 'notes', label: 'Notes', icon: StickyNote, group: 'Data', tint: 'yellow' },
  { page: 'calls', label: 'Call Log', icon: PhoneOutgoing, group: 'Data', tint: 'green' },
  { page: 'safari', label: 'Safari', icon: Compass, group: 'Data', tint: 'blue' },
  { page: 'health', label: 'Health', icon: Heart, group: 'Data', tint: 'pink' },
  { page: 'music', label: 'Music', icon: ListMusic, group: 'Data', tint: 'red' },
  { page: 'watch', label: 'Apple Watch', icon: Watch, group: 'Data', tint: 'gray' },
  { page: 'contacts', label: 'Contacts', icon: CircleUserRound, group: 'Data', tint: 'blue' },
  { page: 'calendar', label: 'Calendar', icon: CalendarDays, group: 'Data', tint: 'red' },
  { page: 'backups', label: 'Backups', icon: HardDrive, group: 'Backups', tint: 'blue' },
  {
    page: 'backupfiles',
    label: 'Backup Browser',
    icon: FolderOpen,
    group: 'Backups',
    tint: 'purple',
  },
  { page: 'files', label: 'File System', icon: Files, group: 'Tools', tint: 'cyan' },
  { page: 'diagnostics', label: 'Diagnostics', icon: Activity, group: 'Tools', tint: 'mint' },
];

/** Pages that read from the selected local backup rather than the live device. */
export const libraryPages = new Set<Page>([
  'messages',
  'photos',
  'contacts',
  'calendar',
  'whatsapp',
  'notes',
  'calls',
  'safari',
  'music',
  'watch',
  'health',
  'backupfiles',
]);

export const descriptions: Record<Page, string> = {
  overview: 'Connection, snapshots, and upcoming backups.',
  backups: 'Manage independent snapshots on this PC.',
  files: 'Browse, transfer, and recover files by source.',
  apps: 'Manage applications on your connected device.',
  diagnostics: 'Live readings and device tools.',
  messages: 'Messages saved in your selected backup.',
  photos: 'Browse, preview, and review your backed-up media.',
  contacts: 'Contacts saved in your backup.',
  calendar: 'Calendar events saved in your backup.',
  whatsapp: 'WhatsApp conversations included in your backup.',
  notes: 'Read the note text included in your backup.',
  calls: 'Filter calls by date and duration.',
  safari: 'Safari history included in your backup.',
  music: 'Extract backed-up audio files.',
  watch: 'Extract original Apple Watch files.',
  health: 'Extract original Health files.',
  backupfiles: 'Browse original paths and domains in your backup.',
  settings: 'Storage, connection, appearance, and schedules.',
};

export function pageTitle(page: Page) {
  return page === 'settings' ? 'Settings' : navigation.find((n) => n.page === page)?.label;
}
