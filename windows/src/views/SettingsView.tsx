import { useEffect, useState } from 'react';
import {
  ArrowUpRight,
  CheckCircle2,
  Clock3,
  Folder,
  FolderOpen,
  Info,
  Moon,
  ShieldCheck,
  Sun,
} from 'lucide-react';
import { api } from '../api';
import { useApp } from '../appModel';
import { Badge, Button } from '../ui';
import ScheduleSection from './ScheduleSection';
import WifiSection from './WifiSection';

export type Theme = 'light' | 'dark' | 'system';

const themes: { value: Theme; label: string; icon: typeof Sun }[] = [
  { value: 'light', label: 'Light', icon: Sun },
  { value: 'dark', label: 'Dark', icon: Moon },
  { value: 'system', label: 'System', icon: Sun },
];

export default function SettingsView({
  theme,
  onThemeChange,
}: {
  theme: Theme;
  onThemeChange: (theme: Theme) => void;
}) {
  const { status, perform, refresh, openDialog } = useApp();
  const [startup, setStartup] = useState(() => localStorage.getItem('phosphor-startup') === 'true');
  useEffect(() => {
    if (typeof status.startup === 'boolean') setStartup(status.startup);
  }, [status.startup]);

  const changeStartup = (enabled: boolean) => {
    setStartup(enabled);
    localStorage.setItem('phosphor-startup', String(enabled));
    api.window(enabled ? 'startup-on' : 'startup-off');
  };
  const changeBackupRoot = () =>
    perform(async () => {
      const path = await api.choose('folder', { title: 'Choose your backup storage folder' });
      if (path) {
        await api.call('setBackupRoot', { path });
        await refresh();
      }
    });

  return (
    <div className="settings-stack">
      <section className="panel setting-section">
        <div className="setting-heading">
          <Folder size={22} />
          <div>
            <h3>Backup storage</h3>
            <p>Choose a local drive with plenty of space.</p>
          </div>
        </div>
        <div className="path-setting">
          <code>{status.backupRoot || 'Loading…'}</code>
          <Button icon={FolderOpen} onClick={changeBackupRoot}>
            Change folder
          </Button>
        </div>
        <p className="setting-note">
          Apple Devices and iTunes backup folders are discovered automatically. Phosphor writes its
          own backups to the folder above.
        </p>
      </section>
      <section className="panel setting-section">
        <WifiSection />
      </section>
      <section className="panel setting-section">
        <div className="setting-heading">
          <Sun size={22} />
          <div>
            <h3>Appearance</h3>
            <p>Choose your preferred appearance.</p>
          </div>
        </div>
        <div className="theme-options">
          {themes.map((option) => (
            <button
              key={option.value}
              className={theme === option.value ? 'active' : ''}
              onClick={() => onThemeChange(option.value)}
            >
              <option.icon size={22} />
              <span>{option.label}</span>
              {theme === option.value && <CheckCircle2 size={17} />}
            </button>
          ))}
        </div>
      </section>
      <section className="panel setting-section">
        <div className="setting-heading">
          <Clock3 size={22} />
          <div>
            <h3>Startup</h3>
            <p>Phosphor stays in the system tray when schedules or operations are active.</p>
          </div>
        </div>
        <label className="toggle-row">
          <div>
            <b>Start with Windows</b>
            <small>Keep scheduled backups available after you sign in.</small>
          </div>
          <input
            type="checkbox"
            checked={startup}
            onChange={(e) => changeStartup(e.target.checked)}
          />
        </label>
      </section>
      <ScheduleSection />
      <section className="panel setting-section">
        <div className="setting-heading">
          <ShieldCheck size={22} />
          <div>
            <h3>Local engine</h3>
            <p>Backups and device data stay on this PC.</p>
          </div>
        </div>
        <div className="engine-check">
          <Badge good={!!status.engine}>
            {status.engine ? 'Local engine bundled' : 'Desktop engine required'}
          </Badge>
          <Badge good={!!status.driver}>
            {status.driver ? 'Apple service ready' : 'Apple service unavailable'}
          </Badge>
        </div>
        <p className="setting-note">
          Phosphor for Windows {status.version ? 'v' + status.version : '(browser preview)'}. The
          Windows edition shares this repository and its release version with the macOS app.
        </p>
        <div className="inline-actions">
          <Button
            icon={ArrowUpRight}
            onClick={() => api.external('https://github.com/momenbasel/Phosphor')}
          >
            Phosphor on GitHub
          </Button>
          <Button icon={Info} onClick={() => openDialog('about')}>
            About this edition
          </Button>
        </div>
      </section>
    </div>
  );
}
