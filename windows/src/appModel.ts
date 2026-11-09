import { createContext, useContext } from 'react';
import type { Row } from './api';
import type { Page } from './navigation';

export type DialogKind =
  | 'connect'
  | 'about'
  | 'backup'
  | 'encryption'
  | 'unlock'
  | 'restore'
  | 'clone'
  | 'schedule'
  | 'renameBackup'
  | 'deleteBackup'
  | 'confirm';

export interface DialogState {
  kind: DialogKind;
  title?: string;
  description?: string;
  action?: () => Promise<unknown>;
  data?: Row;
}

/**
 * Shared application state and actions, playing the role of the macOS app's
 * DeviceViewModel/BackupViewModel environment objects. Views read it with
 * useApp() instead of receiving every value as a prop.
 */
export interface AppModel {
  status: Row;
  devices: Row[];
  device?: Row;
  deviceId: string;
  backups: Row[];
  backup?: Row;
  backupId: string;
  jobs: Row[];
  busy: boolean;
  revision: number;
  notify: (message: string, error?: boolean) => void;
  perform: <T>(fn: () => Promise<T>, success?: string) => Promise<T | null>;
  confirm: (title: string, description: string, action: () => Promise<unknown>) => void;
  openDialog: (kind: DialogKind, data?: Row) => void;
  navigate: (page: Page) => void;
  refresh: (force?: boolean, reloadPage?: boolean) => Promise<void>;
  reload: () => void;
  selectDevice: (id: string) => void;
  selectBackup: (id: string, nextPage?: Page) => void;
  setBackupId: (id: string) => void;
  chooseBackupFolder: () => Promise<void>;
}

export const AppContext = createContext<AppModel | null>(null);

export function useApp() {
  const model = useContext(AppContext);
  if (!model) throw new Error('useApp must be used inside AppContext.');
  return model;
}
