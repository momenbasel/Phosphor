import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent,
} from 'react';
import {
  ArrowDown,
  ArrowDownToLine,
  ArrowLeft,
  ArrowUp,
  ArrowUpDown,
  ChevronRight,
  Cloud,
  File,
  FileText,
  Folder,
  FolderPlus,
  Grid2X2,
  Image,
  Info,
  List,
  Loader2,
  Music2,
  Pencil,
  RefreshCw,
  Search,
  Smartphone,
  Trash2,
  Upload,
  Video,
  X,
} from 'lucide-react';
import { api, type Row } from './api';
import './file_browser.css';
const PdfPreview = lazy(() => import('./PdfPreview'));

type Source = 'device' | 'backup' | 'icloud' | 'local';
type Prompt = {
  action: 'rename' | 'mkdir' | 'trash' | 'purge';
  title: string;
  description?: string;
  name?: string;
} | null;
type Props = {
  deviceId: string;
  backupId: string;
  backupUnlocked: boolean;
  onUnlock?: () => void;
  notify?: (message: string, error?: boolean) => void;
  revision?: number;
  initialSource?: Source;
};
const icons = { folder: Folder, photo: Image, video: Video, audio: Music2, file: File };
function size(value?: number | null) {
  if (value == null) return '—';
  if (value < 1024) return value + ' B';
  const n = Math.min(4, Math.floor(Math.log(value) / Math.log(1024)));
  return (value / 1024 ** n).toFixed(n === 1 ? 0 : 1) + ' ' + ['B', 'KB', 'MB', 'GB', 'TB'][n];
}
function date(value?: string) {
  if (!value) return '—';
  const d = new Date(value);
  return Number.isNaN(d.getTime())
    ? '—'
    : d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}
function cleanError(error: unknown) {
  return String((error as Error)?.message || error).replace(
    /^Error invoking remote method '[^']+': Error: /,
    '',
  );
}

export default function FileBrowser({
  deviceId,
  backupId,
  backupUnlocked,
  onUnlock,
  notify,
  revision = 0,
  initialSource = 'device',
}: Props) {
  const [source, setSource] = useState<Source>(initialSource);
  const [roots, setRoots] = useState<Row[]>([]);
  const [root, setRoot] = useState('');
  const [path, setPath] = useState('/');
  const [pathInput, setPathInput] = useState('/');
  const [query, setQuery] = useState('');
  const [debounced, setDebounced] = useState('');
  const [kind, setKind] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [sort, setSort] = useState('name');
  const [direction, setDirection] = useState('asc');
  const [mode, setMode] = useState<'list' | 'grid'>('list');
  const [density, setDensity] = useState('medium');
  const [trash, setTrash] = useState(false);
  const [result, setResult] = useState<Row>({ rows: [], total: 0 });
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [focused, setFocused] = useState('');
  const [offset, setOffset] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [working, setWorking] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [prompt, setPrompt] = useState<Prompt>(null);
  const [name, setName] = useState('');
  const [promptError, setPromptError] = useState('');
  const [preview, setPreview] = useState<Row | null>(null);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [pendingJob, setPendingJob] = useState('');
  const table = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const anchor = useRef('');
  const request = useRef(0);
  const lastRefresh = useRef(0);
  const focusReturn = useRef<HTMLElement | null>(null);
  const modalRef = useRef<HTMLDivElement>(null);
  const jobStates = useRef<Map<string, Row>>(new Map());
  const previewRequest = useRef(0);
  const previewToken = useRef('');
  const rows: Row[] = result.rows || [];
  const capability = result.capabilities || {};
  const selectedRows = rows.filter((row) => selected.has(row.id));
  const item = rows.find((row) => row.id === focused) || selectedRows[0];
  const available =
    source === 'device' ? !!deviceId : source === 'backup' ? !!backupId && backupUnlocked : !!root;
  const context = { source, udid: deviceId, backup: backupId, root, path, trash };
  const report = useCallback(
    (message: string, isError = false) => {
      notify?.(message, isError);
      if (isError) setError(message);
    },
    [notify],
  );
  const closePreview = () => {
    previewRequest.current++;
    setPreview(null);
    setPreviewLoading(false);
    const token = previewToken.current;
    previewToken.current = '';
    if (token) void api.call('fileRelease', { token }).catch(() => {});
  };
  useEffect(
    () => () => {
      previewRequest.current++;
      if (previewToken.current)
        void api.call('fileRelease', { token: previewToken.current }).catch(() => {});
    },
    [],
  );
  useEffect(() => {
    closePreview();
  }, [source, root, backupId, backupUnlocked, deviceId]);
  useEffect(() => {
    setSource(initialSource);
  }, [initialSource]);
  useEffect(() => {
    let alive = true;
    api
      .call('fileSources')
      .then((data) => {
        if (alive) {
          const local = data.roots || [];
          setRoots(local);
          const cloud = data.icloud?.[0];
          if (cloud) setRoot((value) => value || cloud.root);
        }
      })
      .catch((e) => {
        if (alive) setError(cleanError(e));
      });
    return () => {
      alive = false;
    };
  }, []);
  useEffect(() => {
    const t = setTimeout(() => setDebounced(query), 180);
    return () => clearTimeout(t);
  }, [query]);
  useEffect(() => {
    setPath('/');
    setPathInput('/');
    setTrash(false);
    setSelected(new Set());
    setOffset(0);
    setFocused('');
    setQuery('');
    setError('');
  }, [source, deviceId, backupId, root]);
  useEffect(() => {
    setOffset(0);
    setSelected(new Set());
    setFocused('');
  }, [debounced, kind, sort, direction, dateFrom, dateTo, trash]);
  useEffect(() => {
    setPathInput(path);
    setSelected(new Set());
    setFocused('');
    setOffset(0);
  }, [path]);
  useEffect(() => {
    const id = ++request.current;
    if (!available) {
      setResult({ rows: [], total: 0 });
      setLoading(false);
      return;
    }
    setLoading(true);
    setError('');
    const force = lastRefresh.current !== refresh;
    lastRefresh.current = refresh;
    api
      .call('fileList', {
        source,
        udid: deviceId,
        backup: backupId,
        root,
        path,
        trash,
        query: debounced,
        kind,
        sort,
        direction,
        dateFrom,
        dateTo,
        offset,
        limit: 200,
        refresh: force,
      })
      .then((data) => {
        if (id === request.current) setResult(data);
      })
      .catch((e) => {
        if (id === request.current) {
          setError(cleanError(e));
          setResult({ rows: [], total: 0 });
        }
      })
      .finally(() => {
        if (id === request.current) setLoading(false);
      });
    return () => {
      if (id === request.current) request.current++;
    };
  }, [
    source,
    deviceId,
    backupId,
    root,
    path,
    trash,
    debounced,
    kind,
    sort,
    direction,
    dateFrom,
    dateTo,
    offset,
    refresh,
    revision,
    available,
  ]);
  useEffect(() => {
    if (!prompt && !preview) return;
    focusReturn.current = document.activeElement as HTMLElement;
    const frame = requestAnimationFrame(() =>
      modalRef.current?.querySelector<HTMLElement>('input,button')?.focus(),
    );
    const key = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape' && !working) {
        setPrompt(null);
        closePreview();
      }
      if (event.key === 'Tab') {
        const nodes = [
          ...(modalRef.current?.querySelectorAll<HTMLElement>(
            'button:not(:disabled),input:not(:disabled),[tabindex="0"]',
          ) || []),
        ];
        if (event.shiftKey && document.activeElement === nodes[0]) {
          nodes.at(-1)?.focus();
          event.preventDefault();
        } else if (!event.shiftKey && document.activeElement === nodes.at(-1)) {
          nodes[0]?.focus();
          event.preventDefault();
        }
      }
    };
    document.addEventListener('keydown', key);
    return () => {
      cancelAnimationFrame(frame);
      document.removeEventListener('keydown', key);
      focusReturn.current?.focus();
    };
  }, [prompt, preview, working]);
  const navigate = (value: string) => {
    setPath(value);
    setPathInput(value);
    setTrash(false);
    setQuery('');
  };
  const parent = path === '/' ? '/' : path.slice(0, path.lastIndexOf('/')) || '/';
  const chooseRoot = async (cloud: boolean) => {
    try {
      const picked = await api.choose('folder', {
        title: cloud ? 'Choose your iCloud Drive folder' : 'Choose a folder to browse',
      });
      if (!picked) return;
      const registered = await api.call('fileRoot', {
        path: picked,
        source: cloud ? 'icloud' : 'local',
      });
      setRoots((value) => [...value.filter((r) => r.root !== registered.root), registered]);
      setRoot(registered.root);
      setSource(cloud ? 'icloud' : 'local');
    } catch (e) {
      report(cleanError(e), true);
    }
  };
  const changeSource = (value: Source) => {
    setSource(value);
    if (value === 'icloud' || value === 'local')
      setRoot(roots.find((r) => r.source === value)?.root || '');
  };
  const choose = (row: Row, event?: MouseEvent) => {
    setFocused(row.id);
    if (event?.shiftKey && anchor.current) {
      const a = rows.findIndex((r) => r.id === anchor.current),
        b = rows.findIndex((r) => r.id === row.id);
      if (a >= 0)
        setSelected(new Set(rows.slice(Math.min(a, b), Math.max(a, b) + 1).map((r) => r.id)));
    } else if (event?.ctrlKey || event?.metaKey)
      setSelected((values) => {
        const next = new Set(values);
        next.has(row.id) ? next.delete(row.id) : next.add(row.id);
        return next;
      });
    else {
      setSelected(new Set([row.id]));
      anchor.current = row.id;
    }
  };
  const open = (row: Row) => {
    if (row.link) {
      report('Open links and junctions in File Explorer.', true);
      return;
    }
    if (row.directory && !trash) {
      navigate(row.path);
      return;
    }
    if (trash) return;
    closePreview();
    const requestId = ++previewRequest.current;
    setPreview({ name: row.name });
    setPreviewLoading(true);
    api
      .call('filePreview', { ...context, path: row.path })
      .then((data) => {
        if (requestId === previewRequest.current) {
          previewToken.current = data.token || '';
          setPreview({ ...data, previewPath: row.path });
        } else if (data.token) void api.call('fileRelease', { token: data.token }).catch(() => {});
      })
      .catch((e) => {
        if (requestId === previewRequest.current)
          setPreview({ name: row.name, previewPath: row.path, error: cleanError(e) });
      })
      .finally(() => {
        if (requestId === previewRequest.current) setPreviewLoading(false);
      });
  };
  const ask = (action: NonNullable<Prompt>['action']) => {
    const titles = {
      rename: 'Rename item',
      mkdir: 'New folder',
      trash: source === 'device' ? 'Move to Phosphor Trash?' : 'Move to Recycle Bin?',
      purge: 'Permanently delete?',
    };
    setName(action === 'rename' ? selectedRows[0]?.name || '' : '');
    setPromptError('');
    setPrompt({
      action,
      title: titles[action],
      description:
        action === 'trash'
          ? source === 'device'
            ? `${selected.size} selected item(s) will move to Phosphor Trash on your iPhone. You can restore them here.`
            : `${selected.size} selected item(s) will move to Windows Recycle Bin.${source === 'icloud' ? ' Changes sync to iCloud and your other devices.' : ''}`
          : action === 'purge'
            ? `${selected.size} selected item(s) will be permanently removed from Phosphor Trash. This cannot be undone.`
            : undefined,
    });
  };
  const operate = async (action: string, extra: Row = {}) => {
    setWorking(true);
    setError('');
    setPromptError('');
    let jobStarted = false;
    try {
      const outcome = await api.call('fileOperation', {
        ...context,
        paths: [...selected],
        action,
        ...extra,
      });
      if (outcome?.job) {
        const finished = jobStates.current.get(outcome.job);
        if (finished && finished.status !== 'running') {
          setRefresh((value) => value + 1);
          report(
            finished.status === 'failed' ? finished.detail : 'File operation completed.',
            finished.status === 'failed',
          );
        } else {
          jobStarted = true;
          setPendingJob(outcome.job);
          report('File operation started. Progress appears in Activity.');
        }
      } else {
        report('File operation completed.');
        setRefresh((value) => value + 1);
      }
      setPrompt(null);
      setSelected(new Set());
    } catch (e) {
      const message = cleanError(e);
      setPromptError(message);
      report(message, true);
    } finally {
      if (!jobStarted) setWorking(false);
    }
  };
  useEffect(
    () =>
      api.onEvent((event) => {
        if (event.event !== 'job') return;
        jobStates.current.set(event.data.id, event.data);
        if (jobStates.current.size > 100)
          jobStates.current.delete(jobStates.current.keys().next().value!);
        if (event.data.status === 'completed') setRefresh((value) => value + 1);
        if (event.data.id === pendingJob && event.data.status !== 'running') {
          setWorking(false);
          setPendingJob('');
          setRefresh((value) => value + 1);
          if (event.data.status === 'failed') report(event.data.detail, true);
        }
      }),
    [pendingJob, report],
  );
  const download = async () => {
    try {
      const picked = await api.choose('folder', { title: 'Download selected files to' });
      if (picked) await operate('download', { localPath: picked });
    } catch (e) {
      report(cleanError(e), true);
    }
  };
  const upload = async () => {
    try {
      const picked = await api.choose('file', { title: 'Upload a file' });
      if (picked) await operate('upload', { localPath: picked });
    } catch (e) {
      report(cleanError(e), true);
    }
  };
  const keydown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.target !== table.current) return;
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a') {
      event.preventDefault();
      setSelected(new Set(rows.map((r) => r.id)));
      return;
    }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') {
      event.preventDefault();
      searchRef.current?.focus();
      return;
    }
    if (event.key === 'Backspace' || (event.altKey && event.key === 'ArrowUp')) {
      event.preventDefault();
      if (!trash) navigate(parent);
      return;
    }
    if (event.key === 'F2' && selected.size === 1 && capability.rename && !trash) {
      event.preventDefault();
      ask('rename');
      return;
    }
    if (event.key === 'Delete' && selected.size && capability.trash && !trash) {
      event.preventDefault();
      ask('trash');
      return;
    }
    if (event.key === 'Enter' && item) {
      event.preventDefault();
      open(item);
      return;
    }
    if (event.key === ' ' && item) {
      event.preventDefault();
      setSelected((values) => {
        const next = new Set(values);
        next.has(item.id) ? next.delete(item.id) : next.add(item.id);
        return next;
      });
      return;
    }
    if (event.key === 'Escape') {
      setSelected(new Set());
      return;
    }
    if (
      ['ArrowDown', 'ArrowUp', 'ArrowRight', 'ArrowLeft', 'Home', 'End'].includes(event.key) &&
      rows.length
    ) {
      event.preventDefault();
      const current = rows.findIndex((r) => r.id === focused);
      const columns =
        mode === 'grid' && table.current
          ? getComputedStyle(table.current).gridTemplateColumns.split(' ').length
          : 1;
      const jump = ['ArrowDown', 'ArrowUp'].includes(event.key) ? columns : 1;
      const step = (event.key === 'ArrowUp' || event.key === 'ArrowLeft' ? -1 : 1) * jump;
      const index =
        event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? rows.length - 1
            : current < 0
              ? 0
              : Math.max(0, Math.min(rows.length - 1, current + step));
      const row = rows[index];
      setFocused(row.id);
      if (event.shiftKey && anchor.current) {
        const start = rows.findIndex((r) => r.id === anchor.current);
        if (start >= 0)
          setSelected(
            new Set(
              rows.slice(Math.min(start, index), Math.max(start, index) + 1).map((r) => r.id),
            ),
          );
      } else if (!event.ctrlKey) {
        setSelected(new Set([row.id]));
        anchor.current = row.id;
      }
      table.current
        ?.querySelector<HTMLElement>('[data-index="' + index + '"]')
        ?.scrollIntoView({ block: 'nearest' });
    }
  };
  const toggleSort = (value: string) => {
    if (sort === value) setDirection(direction === 'asc' ? 'desc' : 'asc');
    else {
      setSort(value);
      setDirection(value === 'name' ? 'asc' : 'desc');
    }
  };
  const sourceText =
    source === 'device'
      ? 'iPhone Media'
      : source === 'backup'
        ? 'Backup files'
        : source === 'icloud'
          ? 'iCloud Drive'
          : 'PC folder';
  const breadcrumb = path.split('/').filter(Boolean);
  return (
    <section className="fb-shell" aria-label="File browser">
      <div className="fb-sourcebar">
        <div className="fb-source">
          <label htmlFor="fb-source">Location</label>
          <select
            id="fb-source"
            value={source}
            onChange={(e) => changeSource(e.target.value as Source)}
          >
            <option value="device">iPhone Media</option>
            <option value="backup">Backup snapshot</option>
            <option value="icloud">iCloud Drive</option>
            <option value="local">PC folder</option>
          </select>
        </div>
        {(source === 'local' || source === 'icloud') && (
          <>
            <select
              aria-label="Selected folder"
              value={root}
              onChange={(e) => setRoot(e.target.value)}
            >
              <option value="">Choose a folder</option>
              {roots
                .filter((r) => r.source === source)
                .map((r) => (
                  <option value={r.root} key={r.root}>
                    {r.name}
                  </option>
                ))}
            </select>
            <button className="button secondary" onClick={() => chooseRoot(source === 'icloud')}>
              <Folder size={16} /> Choose folder
            </button>
          </>
        )}
        <span className="fb-source-state">
          {source === 'backup'
            ? 'Read-only snapshot'
            : source === 'device'
              ? 'Media access via Apple AFC'
              : source === 'icloud'
                ? 'Synced through iCloud for Windows'
                : 'Selected folder only'}
        </span>
      </div>
      <div className="fb-toolbar">
        <div className="fb-navigation">
          <button
            className="icon-button"
            aria-label="Up one folder"
            disabled={path === '/' || trash}
            onClick={() => navigate(parent)}
          >
            <ArrowUp size={17} />
          </button>
          <button
            className="icon-button"
            aria-label="Refresh files"
            disabled={loading || !available}
            onClick={() => setRefresh((value) => value + 1)}
          >
            <RefreshCw size={17} className={loading ? 'fb-spin' : ''} />
          </button>
        </div>
        <div className="fb-breadcrumb" aria-label="Folder path">
          <button onClick={() => navigate('/')}>{sourceText}</button>
          {trash ? (
            <>
              <ChevronRight size={14} />
              <span>Phosphor Trash</span>
            </>
          ) : (
            breadcrumb.map((p, index) => (
              <span key={index}>
                <ChevronRight size={14} />
                <button onClick={() => navigate('/' + breadcrumb.slice(0, index + 1).join('/'))}>
                  {p}
                </button>
              </span>
            ))
          )}
        </div>
        <div className="fb-views">
          <button
            className={'icon-button ' + (mode === 'list' ? 'is-active' : '')}
            aria-label="List view"
            aria-pressed={mode === 'list'}
            onClick={() => setMode('list')}
          >
            <List size={17} />
          </button>
          <button
            className={'icon-button ' + (mode === 'grid' ? 'is-active' : '')}
            aria-label="Grid view"
            aria-pressed={mode === 'grid'}
            onClick={() => setMode('grid')}
          >
            <Grid2X2 size={17} />
          </button>
          <select
            aria-label="Item density"
            value={density}
            onChange={(e) => setDensity(e.target.value)}
          >
            <option value="small">Small</option>
            <option value="medium">Medium</option>
            <option value="large">Large</option>
          </select>
        </div>
      </div>
      <form
        className="fb-path"
        onSubmit={(e) => {
          e.preventDefault();
          navigate(pathInput.startsWith('/') ? pathInput : '/' + pathInput);
        }}
      >
        <label htmlFor="fb-path">Path</label>
        <input
          id="fb-path"
          value={pathInput}
          onChange={(e) => setPathInput(e.target.value)}
          disabled={trash}
          spellCheck={false}
        />
        <button type="submit" className="button secondary" disabled={!available || trash}>
          Go
        </button>
      </form>
      <div className="fb-filterbar">
        <label className="fb-search">
          <Search size={16} />
          <input
            ref={searchRef}
            aria-label="Search this folder"
            value={query}
            placeholder="Search this folder"
            onChange={(e) => setQuery(e.target.value)}
          />
          {query && (
            <button className="icon-button" onClick={() => setQuery('')} aria-label="Clear search">
              <X size={14} />
            </button>
          )}
        </label>
        <select aria-label="File type" value={kind} onChange={(e) => setKind(e.target.value)}>
          <option value="">All types</option>
          <option value="folder">Folders</option>
          <option value="photo">Images</option>
          <option value="video">Videos</option>
          <option value="audio">Audio</option>
          <option value="file">Other files</option>
        </select>
        <label>
          From
          <input
            aria-label="Modified after"
            type="date"
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
          />
        </label>
        <label>
          To
          <input
            aria-label="Modified before"
            type="date"
            value={dateTo}
            min={dateFrom}
            onChange={(e) => setDateTo(e.target.value)}
          />
        </label>
        {mode === 'grid' && (
          <select
            aria-label="Sort files"
            value={sort + ':' + direction}
            onChange={(e) => {
              const [s, d] = e.target.value.split(':');
              setSort(s);
              setDirection(d);
            }}
          >
            <option value="name:asc">Name A–Z</option>
            <option value="name:desc">Name Z–A</option>
            <option value="size:desc">Largest first</option>
            <option value="size:asc">Smallest first</option>
            <option value="date:desc">Newest first</option>
            <option value="date:asc">Oldest first</option>
            <option value="kind:asc">File type</option>
          </select>
        )}
      </div>
      <div className="fb-actionbar">
        <span aria-live="polite">
          {working ? (
            <>
              <Loader2 size={14} className="fb-spin" /> Working…
            </>
          ) : selected.size ? (
            `${selected.size} selected`
          ) : available ? (
            `${result.total?.toLocaleString() || 0} items`
          ) : (
            sourceText
          )}
        </span>
        <div>
          <button
            className="button secondary"
            disabled={!selected.size || working || trash || !capability.download}
            onClick={download}
          >
            <ArrowDownToLine size={16} /> Download
          </button>
          {!trash && capability.upload && (
            <button className="button secondary" disabled={working || !available} onClick={upload}>
              <Upload size={16} /> Upload
            </button>
          )}
          {!trash && capability.mkdir && (
            <button
              className="button secondary"
              disabled={working || !available}
              onClick={() => ask('mkdir')}
            >
              <FolderPlus size={16} /> New folder
            </button>
          )}
          {!trash && capability.rename && (
            <button
              className="icon-button"
              disabled={selected.size !== 1 || working}
              aria-label="Rename selected item"
              title="Rename (F2)"
              onClick={() => ask('rename')}
            >
              <Pencil size={17} />
            </button>
          )}
          {!trash && capability.trash && (
            <button
              className="icon-button fb-danger"
              disabled={!selected.size || working}
              aria-label="Move selected items to trash"
              title="Move to trash"
              onClick={() => ask('trash')}
            >
              <Trash2 size={17} />
            </button>
          )}
          {source === 'device' && (
            <button
              className={'button secondary ' + (trash ? 'is-active' : '')}
              disabled={!deviceId || working}
              onClick={() => {
                setTrash(!trash);
                setSelected(new Set());
                setQuery('');
              }}
            >
              <Trash2 size={16} />
              {trash ? 'Back to files' : 'Phosphor Trash'}
            </button>
          )}
          {trash && (
            <>
              <button
                className="button secondary"
                disabled={!selected.size || working}
                onClick={() => operate('restore')}
              >
                <ArrowLeft size={16} /> Restore
              </button>
              <button
                className="button secondary fb-danger"
                disabled={!selected.size || working}
                onClick={() => ask('purge')}
              >
                Delete permanently
              </button>
            </>
          )}
        </div>
      </div>
      {source === 'icloud' && (
        <div className="fb-cloudnote">
          <Cloud size={17} />
          <p>
            Browse your synced iCloud Drive folder. Cloud-only items download when you preview or
            copy them. Changes here sync to your other devices.
          </p>
          <button onClick={() => api.external('https://www.icloud.com/iclouddrive')}>
            Recently Deleted on iCloud.com
          </button>
        </div>
      )}
      {error && (
        <div className="fb-error" role="alert">
          <Info size={18} />
          <div>
            <b>Files could not be opened</b>
            <p>{error}</p>
          </div>
          <button className="button secondary" onClick={() => setRefresh((value) => value + 1)}>
            Retry
          </button>
        </div>
      )}
      {!available ? (
        <div className="fb-empty">
          {source === 'device' ? (
            <Smartphone size={34} />
          ) : source === 'icloud' ? (
            <Cloud size={34} />
          ) : (
            <Folder size={34} />
          )}
          <h3>
            {source === 'device'
              ? 'Connect an iPhone'
              : source === 'backup'
                ? backupId
                  ? 'Unlock this backup'
                  : 'Choose a backup'
                : source === 'icloud'
                  ? 'Connect iCloud Drive'
                  : 'Choose a PC folder'}
          </h3>
          <p>
            {source === 'device'
              ? 'Connect by USB or a saved Wi-Fi connection. This browser accesses the Media folder, rather than every location in the iPhone Files app.'
              : source === 'backup'
                ? 'Browse the original domain and folder structure of a local backup.'
                : source === 'icloud'
                  ? 'Set up iCloud for Windows, then choose its iCloud Drive folder. iCloud sign-in stays with Apple.'
                  : 'Choose a folder to browse its files and manage copies.'}
          </p>
          {source === 'backup' && backupId && (
            <button className="button primary" onClick={onUnlock}>
              Unlock backup
            </button>
          )}
          {(source === 'icloud' || source === 'local') && (
            <div>
              <button className="button primary" onClick={() => chooseRoot(source === 'icloud')}>
                Choose folder
              </button>
              {source === 'icloud' && (
                <button
                  className="button secondary"
                  onClick={() =>
                    api.external(
                      'https://support.apple.com/guide/icloud-windows/set-up-icloud-drive-icw0144825a5/icloud',
                    )
                  }
                >
                  Set up iCloud for Windows
                </button>
              )}
            </div>
          )}
        </div>
      ) : (
        <div className="fb-workspace">
          <div
            className={'fb-files ' + mode + ' ' + density}
            ref={table}
            tabIndex={0}
            role="region"
            aria-label={trash ? 'Phosphor Trash contents' : 'Folder contents'}
            onKeyDown={keydown}
            aria-busy={loading}
          >
            {mode === 'list' && (
              <div className="fb-listhead">
                <input
                  type="checkbox"
                  aria-label="Select all visible files"
                  checked={!!rows.length && rows.every((r) => selected.has(r.id))}
                  onChange={(e) =>
                    setSelected(e.target.checked ? new Set(rows.map((r) => r.id)) : new Set())
                  }
                />
                {[
                  ['name', 'Name'],
                  ['size', 'Size'],
                  ['date', trash ? 'Deleted' : 'Modified'],
                  ['kind', 'Type'],
                ].map(([value, label]) => (
                  <button key={value} onClick={() => toggleSort(value)}>
                    {label}
                    {sort === value ? (
                      direction === 'asc' ? (
                        <ArrowUp size={13} />
                      ) : (
                        <ArrowDown size={13} />
                      )
                    ) : (
                      <ArrowUpDown size={13} />
                    )}
                  </button>
                ))}
              </div>
            )}
            {loading && !rows.length ? (
              <div className="fb-loading" role="status">
                <Loader2 size={24} className="fb-spin" /> Opening folder…
              </div>
            ) : !rows.length ? (
              <div className="fb-empty compact">
                <Folder size={31} />
                <h3>
                  {trash
                    ? 'Phosphor Trash is empty'
                    : debounced || kind || dateFrom || dateTo
                      ? 'No matching files'
                      : 'This folder is empty'}
                </h3>
                <p>
                  {trash
                    ? 'Only files moved to trash by Phosphor appear here. iPhone Photos and Files Recently Deleted remain on the device.'
                    : 'Try a different folder or change the filters.'}
                </p>
              </div>
            ) : (
              rows.map((row, index) => {
                const Icon = icons[row.kind as keyof typeof icons] || File;
                return (
                  <div
                    key={row.id}
                    data-index={index}
                    className={
                      'fb-item ' +
                      (selected.has(row.id) ? 'selected ' : '') +
                      (focused === row.id ? 'focused' : '')
                    }
                    onClick={(e) => {
                      choose(row, e);
                      table.current?.focus();
                    }}
                    onDoubleClick={() => open(row)}
                    title={row.name}
                  >
                    <input
                      type="checkbox"
                      aria-label={'Select ' + row.name}
                      checked={selected.has(row.id)}
                      onClick={(e) => e.stopPropagation()}
                      onChange={() => {
                        setFocused(row.id);
                        setSelected((values) => {
                          const next = new Set(values);
                          next.has(row.id) ? next.delete(row.id) : next.add(row.id);
                          return next;
                        });
                      }}
                    />
                    <span className={'fb-file-icon ' + row.kind}>
                      <Icon
                        size={
                          mode === 'grid'
                            ? density === 'small'
                              ? 28
                              : density === 'large'
                                ? 48
                                : 38
                            : 19
                        }
                        strokeWidth={1.65}
                      />
                      {row.onlineOnly && <Cloud size={12} className="fb-cloudbadge" />}
                    </span>
                    <div className="fb-name">
                      <span>{row.name}</span>
                      {mode === 'grid' && (
                        <small>{row.directory ? 'Folder' : size(row.size)}</small>
                      )}
                    </div>
                    <span className="fb-size">{row.directory ? '—' : size(row.size)}</span>
                    <span className="fb-date">{date(row.date)}</span>
                    <span className="fb-type">
                      {row.onlineOnly
                        ? 'Cloud only'
                        : row.link
                          ? 'Link'
                          : row.kind === 'file'
                            ? PathExtension(row.name)
                            : row.kind}
                    </span>
                  </div>
                );
              })
            )}
          </div>
          <aside className="fb-inspector" aria-label="File details">
            {item ? (
              <>
                <div className="fb-inspector-icon">
                  {item.directory ? <Folder size={36} /> : <FileText size={36} />}
                </div>
                <h3>{item.name}</h3>
                <dl>
                  <dt>Type</dt>
                  <dd>
                    {item.directory
                      ? 'Folder'
                      : item.kind === 'file'
                        ? PathExtension(item.name)
                        : item.kind}
                  </dd>
                  <dt>Size</dt>
                  <dd>{size(item.size)}</dd>
                  <dt>{trash ? 'Deleted' : 'Modified'}</dt>
                  <dd>{date(item.date)}</dd>
                  <dt>{trash ? 'Original path' : 'Path'}</dt>
                  <dd className="fb-fullpath">{item.original || item.path}</dd>
                  {item.onlineOnly && (
                    <>
                      <dt>Availability</dt>
                      <dd>Cloud only · downloads when opened</dd>
                    </>
                  )}
                </dl>
                {!trash && !item.directory && (
                  <button className="button secondary" onClick={() => open(item)}>
                    Preview
                  </button>
                )}
                {!trash && (
                  <button
                    className="button secondary"
                    onClick={() => {
                      setSelected(new Set([item.id]));
                      downloadSingle(item);
                    }}
                  >
                    Download
                  </button>
                )}
              </>
            ) : (
              <>
                <Info size={25} />
                <h3>File details</h3>
                <p>
                  Select an item for its size, date and path. Double-click folders to open them.
                </p>
                <div className="fb-shortcuts">
                  <span>↑ ↓</span> Select item<span>Enter</span> Open / preview<span>Ctrl + A</span>{' '}
                  Select this page<span>F2</span> Rename<span>Backspace</span> Parent folder
                </div>
              </>
            )}
          </aside>
        </div>
      )}
      {available && (
        <footer className="fb-footer">
          <span>
            {result.truncated
              ? result.limitNotice
              : `${offset + Math.min(1, rows.length)}–${offset + rows.length} of ${(result.total || 0).toLocaleString()}`}
          </span>
          <div>
            <button
              className="button secondary"
              disabled={!offset || loading}
              onClick={() => setOffset(Math.max(0, offset - 200))}
            >
              Previous
            </button>
            <button
              className="button secondary"
              disabled={offset + rows.length >= result.total || loading}
              onClick={() => setOffset(offset + 200)}
            >
              Next
            </button>
          </div>
        </footer>
      )}
      {source === 'device' && (
        <p className="fb-scope-note">
          Apple AFC exposes Media storage. iCloud Drive, app-private documents and the iPhone Files
          app’s Recently Deleted are separate. Photos and Music library folders can be exported
          here; manage their originals on the iPhone.
        </p>
      )}
      {(prompt || preview) && (
        <div
          className="fb-modal-backdrop"
          onMouseDown={(e) => {
            if (e.target === e.currentTarget && !working) {
              setPrompt(null);
              closePreview();
            }
          }}
        >
          <div
            className={'fb-modal ' + (preview ? 'fb-preview' : '')}
            role="dialog"
            aria-modal="true"
            aria-labelledby="fb-dialog-title"
            ref={modalRef}
          >
            <header>
              <h2 id="fb-dialog-title">{prompt?.title || preview?.name}</h2>
              <button
                className="icon-button"
                disabled={working}
                aria-label="Close dialog"
                onClick={() => {
                  setPrompt(null);
                  closePreview();
                }}
              >
                <X size={19} />
              </button>
            </header>
            {prompt ? (
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  operate(prompt.action, { name, confirmed: true });
                }}
              >
                {prompt.description && <p>{prompt.description}</p>}
                {(prompt.action === 'rename' || prompt.action === 'mkdir') && (
                  <label>
                    Name
                    <input
                      required
                      maxLength={180}
                      autoComplete="off"
                      value={name}
                      onChange={(e) => setName(e.target.value)}
                    />
                  </label>
                )}
                {promptError && (
                  <p className="fb-prompt-error" role="alert">
                    {promptError}
                  </p>
                )}
                <footer>
                  <button
                    type="button"
                    className="button secondary"
                    disabled={working}
                    onClick={() => setPrompt(null)}
                  >
                    Cancel
                  </button>
                  <button
                    className={
                      'button ' +
                      (['trash', 'purge'].includes(prompt.action) ? 'danger' : 'primary')
                    }
                    type="submit"
                    disabled={
                      working || (['rename', 'mkdir'].includes(prompt.action) && !name.trim())
                    }
                  >
                    {working && <Loader2 size={16} className="fb-spin" />}
                    {working
                      ? 'Working…'
                      : prompt.action === 'purge'
                        ? 'Delete permanently'
                        : prompt.action === 'trash'
                          ? 'Move to trash'
                          : 'Save'}
                  </button>
                </footer>
              </form>
            ) : previewLoading ? (
              <div className="fb-loading" role="status">
                <Loader2 size={26} className="fb-spin" /> Preparing preview…
              </div>
            ) : preview?.error ? (
              <div className="fb-preview-empty">
                <Info size={30} />
                <p role="alert">{preview.error}</p>
              </div>
            ) : (
              preview && <FilePreviewContent preview={preview} />
            )}
            {preview && !previewLoading && !prompt && (
              <div className="fb-preview-footer">
                <span>
                  {preview.sourceSize != null ? size(preview.sourceSize) : ''}
                  {preview.raw ? ' · RAW rendition' : ''}
                  {preview.cacheHours ? ' · Cached for up to 1 hour' : ''}
                </span>
                <button
                  className="button secondary"
                  disabled={!preview.previewPath}
                  onClick={() => downloadSingle({ name: preview.name, id: preview.previewPath })}
                >
                  <ArrowDownToLine size={16} />
                  Save original copy
                </button>
              </div>
            )}
          </div>
        </div>
      )}
    </section>
  );
  async function downloadSingle(row: Row) {
    try {
      const picked = await api.choose('folder', { title: 'Download ' + row.name + ' to' });
      if (picked) await operate('download', { localPath: picked, paths: [row.id] });
    } catch (e) {
      report(cleanError(e), true);
    }
  }
}

function FilePreviewContent({ preview }: { preview: Row }) {
  const [ready, setReady] = useState(false),
    [error, setError] = useState(''),
    [zoom, setZoom] = useState(false);
  useEffect(() => {
    setReady(false);
    setError('');
    setZoom(false);
  }, [preview.url]);
  const failed = () => {
    setReady(false);
    setError(
      'This media codec could not be decoded in the app. The original copy remains available to save.',
    );
  };
  if (preview.kind === 'pdf')
    return (
      <Suspense
        fallback={
          <div className="fb-loading" role="status">
            <Loader2 className="fb-spin" size={24} />
            Opening PDF viewer…
          </div>
        }
      >
        <PdfPreview url={preview.url} name={preview.name} />
      </Suspense>
    );
  if (['text', 'document', 'binary'].includes(preview.kind))
    return (
      <div className="fb-document-preview">
        <div className="fb-document-heading">
          <b>{preview.previewLabel || 'Text preview'}</b>
          {preview.encoding && <span>{preview.encoding}</span>}
        </div>
        {preview.notice && <p className="fb-preview-notice">{preview.notice}</p>}
        <pre className={preview.kind === 'binary' ? 'fb-hex-preview' : ''} tabIndex={0}>
          {preview.text}
        </pre>
        {preview.truncated && (
          <p className="fb-preview-notice">
            This content preview is bounded for responsiveness. Save the original copy for its
            complete contents.
          </p>
        )}
      </div>
    );
  if (!['image', 'video', 'audio'].includes(preview.kind))
    return (
      <div className="fb-preview-empty">
        <File size={34} />
        <p>This format does not contain a supported image, media track or readable document.</p>
      </div>
    );
  return (
    <div className={'fb-media-preview ' + (zoom ? 'zoomed' : '')}>
      {error ? (
        <div className="fb-preview-empty">
          <Info size={30} />
          <p role="alert">{error}</p>
        </div>
      ) : (
        <>
          {!ready && (
            <div className="fb-media-loading" role="status">
              <Loader2 className="fb-spin" size={24} />
              <span>Decoding {preview.kind === 'image' ? 'image' : 'media'}…</span>
            </div>
          )}
          {preview.kind === 'image' ? (
            <>
              <div className="fb-image-controls">
                <button
                  className="button secondary"
                  disabled={!ready}
                  onClick={() => setZoom((value) => !value)}
                >
                  {zoom ? 'Fit image' : 'Actual size'}
                </button>
              </div>
              <div className="fb-image-surface">
                <img
                  key={preview.url}
                  src={preview.url}
                  alt={preview.name}
                  onLoad={() => setReady(true)}
                  onError={failed}
                  style={{ visibility: ready ? 'visible' : 'hidden' }}
                />
              </div>
            </>
          ) : preview.kind === 'video' ? (
            <video
              key={preview.url}
              src={preview.url}
              controls
              playsInline
              preload="metadata"
              onLoadedData={() => setReady(true)}
              onError={failed}
              aria-label={preview.name}
            />
          ) : (
            <div className="fb-audio-surface">
              <Music2 size={44} />
              <p>{preview.name}</p>
              <audio
                key={preview.url}
                src={preview.url}
                controls
                preload="metadata"
                onLoadedMetadata={() => setReady(true)}
                onError={failed}
                aria-label={preview.name}
              />
            </div>
          )}
        </>
      )}
    </div>
  );
}
function PathExtension(name: string) {
  const suffix = name.includes('.') ? name.split('.').at(-1)?.toUpperCase() : '';
  return suffix ? `${suffix} file` : 'File';
}
