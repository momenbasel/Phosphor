export type Row = Record<string, any>;
export interface Bridge {
  call(method: string, params?: Row): Promise<any>;
  choose(kind: string, options?: Row): Promise<string | null>;
  reveal(path: string): Promise<void>;
  external(url: string): Promise<void>;
  window(action: string): void;
  droppedPath(file: File): string;
  onEvent(callback: (event: Row) => void): () => void;
}
declare global {
  interface Window {
    phosphor?: Bridge;
  }
}
const preview: Bridge = {
  async call(method) {
    if (method === 'status')
      return {
        platform: 'Browser preview',
        engine: false,
        driver: false,
        preview: true,
        backupRoot: 'Choose a folder in the desktop app',
        schedules: [],
        jobs: [],
      };
    if (method === 'devices' || method === 'backups') return [];
    throw new Error(
      'This action uses the local device engine. Open the Windows desktop app to continue.',
    );
  },
  async choose() {
    throw new Error('Open the desktop app to select local files.');
  },
  async reveal() {},
  async external(url) {
    window.open(url, '_blank', 'noopener,noreferrer');
  },
  window() {},
  droppedPath() {
    throw new Error('Open the desktop app to transfer files.');
  },
  onEvent() {
    return () => {};
  },
};
export const api = window.phosphor ?? preview;
