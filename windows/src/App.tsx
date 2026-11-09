import { lazy, Suspense, useCallback, useEffect, useRef, useState } from 'react';
import {
  Bell,
  CheckCircle2,
  Database,
  Info,
  Loader2,
  LockKeyhole,
  Maximize2,
  Minus,
  RefreshCw,
  Search,
  Wifi,
  X,
} from 'lucide-react';
import ActivityDrawer from './ActivityDrawer';
import AppDialog from './AppDialog';
import { api, type Row } from './api';
import { AppContext, type AppModel, type DialogKind, type DialogState } from './appModel';
import CommandPalette from './CommandPalette';
import { descriptions, libraryPages, pageTitle, type Page } from './navigation';
import Sidebar from './Sidebar';
import { Button, Loading, date, errorMessage } from './ui';
import AppsView from './views/AppsView';
import BackupsView from './views/BackupsView';
import DevicesView from './views/DevicesView';
import DiagnosticsView from './views/DiagnosticsView';
import LibraryPage from './views/LibraryPage';
import PairPrompt from './views/PairPrompt';
import SettingsView, { type Theme } from './views/SettingsView';

const PdfPreview = lazy(() => import('./PdfPreview'));
const FileBrowser = lazy(() => import('./FileBrowser'));

function storedTheme(): Theme {
  const value = localStorage.getItem('phosphor-theme');
  return value === 'dark' || value === 'system' ? value : 'light';
}

/** Initial form values for a dialog, including the next free slot for a new schedule. */
function dialogForm(kind: DialogKind, data: Row | undefined): Row {
  if (kind === 'schedule') {
    const next =
      data?.next && data.next > Date.now() / 1000
        ? new Date(data.next * 1000)
        : new Date(Date.now() + 3600000);
    const local = new Date(next.getTime() - next.getTimezoneOffset() * 60000);
    const pad = (value: number) => String(value).padStart(2, '0');
    return {
      frequency: data?.frequency === 'hourly' ? 'interval' : data?.frequency || 'daily',
      hours: data?.hours || 1,
      atTime: data?.atTime || `${pad(next.getHours())}:${pad(next.getMinutes())}`,
      firstAt: local.toISOString().slice(0, 16),
      weekday: data?.weekday ?? (next.getDay() + 6) % 7,
      enabled: data?.enabled ?? true,
    };
  }
  if (kind === 'backup') return { full: 'full' };
  if (kind === 'renameBackup') return { name: data?.name };
  if (kind === 'encryption') return { mode: 'on' };
  return {};
}

export default function App() {
  const [page, setPage] = useState<Page>('overview');
  const [status, setStatus] = useState<Row>({});
  const [devices, setDevices] = useState<Row[]>([]);
  const [deviceId, setDeviceId] = useState('');
  const [backups, setBackups] = useState<Row[]>([]);
  const [backupId, setBackupId] = useState('');
  const [jobs, setJobs] = useState<Row[]>([]);
  const [showActivity, setShowActivity] = useState(false);
  const [dialog, setDialog] = useState<DialogState | null>(null);
  const [form, setForm] = useState<Row>({});
  const [toast, setToast] = useState<{ message: string; error: boolean } | null>(null);
  const [busy, setBusy] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [scanError, setScanError] = useState('');
  const [palette, setPalette] = useState(false);
  const [theme, setTheme] = useState<Theme>(storedTheme);
  const [revision, setRevision] = useState(0);
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const actionInFlight = useRef(false);
  const statusInFlight = useRef<Promise<void> | null>(null);
  const refreshInFlight = useRef<Promise<void> | null>(null);
  const refreshPending = useRef(false);
  const discoverPending = useRef(false);
  const device = devices.find((d) => d.id === deviceId);
  const backup = backups.find((b) => b.id === backupId);
  const activeJobs = jobs.filter((j) => j.status === 'running');

  const notify = useCallback((message: string, error = false) => {
    setToast({ message: errorMessage(message), error });
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(null), error ? 12000 : 6000);
  }, []);
  // Runs one user action at a time and reports failures as a toast.
  const perform = useCallback(
    async <T,>(fn: () => Promise<T>, success?: string): Promise<T | null> => {
      if (actionInFlight.current) return null;
      actionInFlight.current = true;
      setBusy(true);
      try {
        const result = await fn();
        if (success) notify(success);
        return result;
      } catch (e) {
        notify(errorMessage(e), true);
        return null;
      } finally {
        actionInFlight.current = false;
        setBusy(false);
      }
    },
    [notify],
  );
  const pollStatus = useCallback(() => {
    if (statusInFlight.current) return statusInFlight.current;
    const request = api
      .call('status')
      .then((result) => {
        setStatus(result);
        setJobs(result.jobs || []);
      })
      .catch(() => {})
      .finally(() => {
        statusInFlight.current = null;
      });
    statusInFlight.current = request;
    return request;
  }, []);
  // Coalesces overlapping refreshes; device discovery runs only when forced.
  const refresh = useCallback(
    (force = false, reloadPage = force) => {
      if (force) setScanning(true);
      if (reloadPage) setRevision((value) => value + 1);
      if (refreshInFlight.current) {
        refreshPending.current = true;
        discoverPending.current ||= force;
        return refreshInFlight.current;
      }
      const request = (async () => {
        let discover = force;
        try {
          do {
            refreshPending.current = false;
            const [, found, listed] = await Promise.allSettled([
              pollStatus(),
              discover ? api.call('devices') : Promise.resolve(null),
              api.call('backups'),
            ]);
            if (found.status === 'fulfilled' && found.value) {
              const rows: Row[] = found.value;
              setDevices(rows);
              setDeviceId((id) => (rows.some((d) => d.id === id) ? id : rows[0]?.id || ''));
              setScanError('');
            } else if (found.status === 'rejected') setScanError(errorMessage(found.reason));
            if (listed.status === 'fulfilled') {
              const rows: Row[] = listed.value;
              setBackups(rows);
              setBackupId((id) => (rows.some((b) => b.id === id) ? id : rows[0]?.id || ''));
            }
            discover = discoverPending.current;
            discoverPending.current = false;
          } while (refreshPending.current);
        } finally {
          setScanning(false);
          refreshInFlight.current = null;
        }
      })();
      refreshInFlight.current = request;
      return request;
    },
    [pollStatus],
  );

  useEffect(() => {
    refresh(true);
    const timer = setInterval(() => {
      if (document.visibilityState === 'visible') pollStatus();
    }, 5000);
    const slower = setInterval(() => {
      if (document.visibilityState === 'visible') refresh(true, false);
    }, 60000);
    return () => {
      clearInterval(timer);
      clearInterval(slower);
    };
  }, [refresh, pollStatus]);
  useEffect(
    () => () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    },
    [],
  );
  useEffect(
    () =>
      api.onEvent((event) => {
        if (event.event === 'job') {
          const job = event.data;
          setJobs((js) => [...js.filter((j) => j.id !== job.id), job]);
          if (job.status === 'completed') {
            notify(job.title + ' completed');
            setRevision((v) => v + 1);
            refresh();
          } else if (job.status === 'failed') notify(job.detail, true);
        }
        if (event.event === 'engine-stopped')
          notify('The local engine stopped. Restart Phosphor to reconnect.', true);
      }),
    [refresh, notify],
  );
  useEffect(() => {
    const media = matchMedia('(prefers-color-scheme: dark)');
    const apply = () => {
      document.documentElement.dataset.theme =
        theme === 'system' ? (media.matches ? 'dark' : 'light') : theme;
    };
    apply();
    localStorage.setItem('phosphor-theme', theme);
    media.addEventListener('change', apply);
    return () => media.removeEventListener('change', apply);
  }, [theme]);
  useEffect(() => {
    const handle = (event: KeyboardEvent) => {
      if (event.ctrlKey && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        setPalette((value) => !value);
      }
      if (event.ctrlKey && event.key.toLowerCase() === 'f') {
        const field = document.querySelector<HTMLInputElement>(
          'main input[type="search"],main input[placeholder*="Search"],main input[placeholder*="Find"]',
        );
        if (field) {
          event.preventDefault();
          field.focus();
        }
      }
      if (event.key === 'Escape') {
        setPalette(false);
        setShowActivity(false);
      }
    };
    document.addEventListener('keydown', handle);
    return () => document.removeEventListener('keydown', handle);
  }, []);

  const navigate = (next: Page) => {
    setPage(next);
    setPalette(false);
  };
  const openDialog = (kind: DialogKind, data?: Row) => {
    const saved =
      kind === 'schedule'
        ? data || (status.schedules || []).find((s: Row) => s.udid === deviceId)
        : data;
    setForm(dialogForm(kind, saved));
    setDialog({
      kind,
      data: kind === 'schedule' ? saved || { udid: deviceId, name: device?.name } : data,
    });
  };
  const closeDialog = () => {
    if (!busy) {
      setDialog(null);
      setForm({});
    }
  };
  const confirm = (title: string, description: string, action: () => Promise<unknown>) =>
    setDialog({ kind: 'confirm', title, description, action });
  const selectBackup = (id: string, nextPage?: Page) => {
    const target = backups.find((value) => value.id === id);
    if (target?.encrypted && !target.unlocked) {
      openDialog('unlock', { backup: id, nextPage });
      return;
    }
    setBackupId(id);
    if (nextPage) navigate(nextPage);
  };
  const chooseBackupFolder = async () => {
    await perform(async () => {
      const path = await api.choose('folder', { title: 'Open an iPhone backup folder' });
      if (path) {
        await api.call('addBackupRoot', { path });
        await refresh();
        navigate('backups');
      }
    });
  };

  const submitDialog = async () => {
    if (!dialog) return;
    const result = await perform(async () => {
      switch (dialog.kind) {
        case 'backup':
          return api.call('createBackup', { udid: deviceId, full: form.full === 'full' });
        case 'encryption':
          if (form.mode === 'on' && form.password !== form.repeatPassword)
            throw new Error('The backup passwords do not match.');
          if (form.mode === 'change' && form.newPassword !== form.repeatPassword)
            throw new Error('The new backup passwords do not match.');
          return api.call('encryption', {
            udid: deviceId,
            mode: form.mode,
            password: form.password,
            newPassword: form.newPassword,
          });
        case 'schedule':
          return api.call('schedule', {
            udid: dialog.data?.udid || deviceId,
            name: dialog.data?.name || device?.name,
            frequency: form.frequency,
            hours: Number(form.hours),
            atTime: form.atTime,
            weekday: Number(form.weekday),
            timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
            enabled: form.enabled,
            firstAt: ['interval', 'monthly'].includes(form.frequency)
              ? new Date(form.firstAt).toISOString()
              : undefined,
          });
        case 'renameBackup':
          return api.call('renameBackup', { backup: dialog.data?.id, name: form.name });
        case 'deleteBackup':
          await api.call('deleteBackup', { backup: dialog.data?.id, confirmed: true });
          notify('Backup moved to the Recycle Bin');
          return true;
        case 'unlock': {
          const id = dialog.data?.backup;
          const nextPage = dialog.data?.nextPage as Page | undefined;
          await api.call('openBackup', { backup: id, password: form.password });
          setBackupId(id);
          await refresh();
          setBackups((rows) =>
            rows.map((row) => (row.id === id ? { ...row, unlocked: true } : row)),
          );
          if (nextPage) navigate(nextPage);
          return true;
        }
        case 'restore':
          return api.call('restoreBackup', {
            udid: deviceId,
            backup: dialog.data?.backup,
            password: form.password || '',
            confirmed: true,
          });
        case 'clone':
          return api.call('clone', {
            source: deviceId,
            target: form.target,
            password: form.password || '',
            confirmed: true,
          });
        case 'confirm':
          await dialog.action?.();
          return true;
        default:
          return true;
      }
    });
    if (result) {
      setDialog(null);
      setForm({});
      if (dialog.kind !== 'unlock') refresh();
    }
  };

  const model: AppModel = {
    status,
    devices,
    device,
    deviceId,
    backups,
    backup,
    backupId,
    jobs,
    busy,
    revision,
    notify,
    perform,
    confirm,
    openDialog,
    navigate,
    refresh,
    reload: () => setRevision((value) => value + 1),
    selectDevice: setDeviceId,
    selectBackup,
    setBackupId,
    chooseBackupFolder,
  };

  function renderPage() {
    if (page === 'overview') return <DevicesView />;
    if (page === 'backups') return <BackupsView />;
    if (page === 'settings') return <SettingsView theme={theme} onThemeChange={setTheme} />;
    if (page === 'files')
      return (
        <Suspense fallback={<Loading label="Opening file browser…" />}>
          <FileBrowser
            deviceId={deviceId}
            backupId={backupId}
            backupUnlocked={!!backup && (!backup.encrypted || backup.unlocked)}
            onUnlock={() => openDialog('unlock', { backup: backupId })}
            notify={notify}
            revision={revision}
          />
        </Suspense>
      );
    if (libraryPages.has(page)) return <LibraryPage page={page} />;
    if (!device?.paired) return <PairPrompt />;
    return page === 'apps' ? <AppsView key={deviceId} /> : <DiagnosticsView key={deviceId} />;
  }

  return (
    <AppContext.Provider value={model}>
      <div className="app-shell">
        {status.selfTestPdfUrl && (
          <Suspense fallback={null}>
            <PdfPreview
              url={status.selfTestPdfUrl}
              name="Synthetic PDF"
              onError={(error) => {
                void api.call('selfTestPreviewComplete', { error }).catch(() => {});
              }}
              onReady={(data) => {
                void api
                  .call('selfTestPreviewComplete', data)
                  .catch((error) => notify(errorMessage(error), true));
              }}
            />
          </Suspense>
        )}
        <Sidebar page={page} />
        <div className="main-shell">
          <div className="titlebar">
            <span>Phosphor</span>
            <div>
              <button aria-label="Minimize window" onClick={() => api.window('minimize')}>
                <Minus size={14} />
              </button>
              <button aria-label="Maximize window" onClick={() => api.window('maximize')}>
                <Maximize2 size={12} />
              </button>
              <button
                className="close-window"
                aria-label="Close window"
                onClick={() => api.window('close')}
              >
                <X size={15} />
              </button>
            </div>
          </div>
          <main>
            <header className="page-header">
              <div>
                <h1>{pageTitle(page)}</h1>
                <p>{descriptions[page]}</p>
              </div>
              <div className="header-actions">
                <button
                  className="command-button"
                  aria-label="Find a page"
                  onClick={() => setPalette(true)}
                >
                  <Search size={16} />
                  <kbd>Ctrl K</kbd>
                </button>
                <button
                  className={
                    'icon-button activity-button ' + (activeJobs.length ? 'has-activity' : '')
                  }
                  aria-label="Open activity"
                  onClick={() => setShowActivity(!showActivity)}
                >
                  <Bell size={19} />
                  {activeJobs.length > 0 && <i />}
                </button>
                <Button icon={RefreshCw} loading={scanning} onClick={() => refresh(true)}>
                  Refresh
                </Button>
              </div>
            </header>
            {device?.connection === 'Network' && device.serviceWarning && (
              <div className="notice caution">
                <Wifi size={18} />
                <span>{device.serviceWarning}</span>
              </div>
            )}
            {libraryPages.has(page) && backups.length > 0 && (
              <div className="backup-selector">
                <Database size={16} />
                <select
                  aria-label="Selected local backup"
                  value={backupId}
                  onChange={(e) => setBackupId(e.target.value)}
                >
                  {backups.map((b) => (
                    <option value={b.id} key={b.id}>
                      {b.name} · {date(b.date)}
                      {b.encrypted ? ' · Encrypted' : ''}
                    </option>
                  ))}
                </select>
                <span className="muted">
                  {backup?.encrypted ? (backup.unlocked ? 'Unlocked' : 'Locked') : 'Read only'}
                </span>
                {backup?.encrypted && backup.unlocked && (
                  <Button
                    icon={LockKeyhole}
                    onClick={() =>
                      perform(async () => {
                        await api.call('lockBackup', { backup: backupId });
                        await refresh();
                      })
                    }
                  >
                    Lock
                  </Button>
                )}
              </div>
            )}
            {renderPage()}
          </main>
        </div>
        {showActivity && <ActivityDrawer onClose={() => setShowActivity(false)} />}
        {activeJobs.length > 0 && !showActivity && (
          <button className="activity-pill" onClick={() => setShowActivity(true)}>
            <Loader2 size={15} className="spin" />
            <span>{activeJobs[0].title}</span>
            <b>{Math.round(activeJobs[0].percent)}%</b>
          </button>
        )}
        {toast && (
          <div
            className={'toast ' + (toast.error ? 'error' : '')}
            role={toast.error ? 'alert' : 'status'}
          >
            {toast.error ? <Info size={19} /> : <CheckCircle2 size={19} />}
            <span>{toast.message}</span>
            <button
              className="icon-button"
              onClick={() => setToast(null)}
              aria-label="Dismiss notification"
            >
              <X size={16} />
            </button>
          </div>
        )}
        {dialog && (
          <AppDialog
            dialog={dialog}
            form={form}
            setForm={setForm}
            scanning={scanning}
            scanError={scanError}
            onClose={closeDialog}
            onSubmit={submitDialog}
          />
        )}
        {palette && <CommandPalette onNavigate={navigate} onClose={() => setPalette(false)} />}
      </div>
    </AppContext.Provider>
  );
}
