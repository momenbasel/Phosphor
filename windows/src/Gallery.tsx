import { useCallback, useEffect, useRef, useState, type PointerEvent } from 'react';
import {
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  Check,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Copy,
  Download,
  Grid2X2,
  Image,
  ListChecks,
  Loader2,
  Play,
  Search,
  Trash2,
  Undo2,
  X,
} from 'lucide-react';
import { api, type Row } from './api';
import './gallery.css';

type Collection = 'all' | 'unreviewed' | 'kept' | 'bin';
type Tab = 'library' | 'review' | 'duplicates';
type Decision = 'keep' | 'bin' | 'reset';
const PAGE_SIZE = 120;
const thumbnailCache = new Map<string, string>();
const thumbnailQueue: (() => Promise<void>)[] = [];
let thumbnailActive = 0;
function queueThumbnail(task: () => Promise<void>) {
  thumbnailQueue.push(task);
  const run = () => {
    while (thumbnailActive < 4 && thumbnailQueue.length) {
      const next = thumbnailQueue.shift()!;
      thumbnailActive++;
      next().finally(() => {
        thumbnailActive--;
        run();
      });
    }
  };
  run();
}
function humanBytes(value?: number) {
  if (value == null) return 'Size unavailable';
  if (value < 1024) return `${value} B`;
  const power = Math.min(4, Math.floor(Math.log(value) / Math.log(1024)));
  return `${(value / 1024 ** power).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${['B', 'KB', 'MB', 'GB', 'TB'][power]}`;
}
function humanDate(value?: string) {
  if (!value) return 'Date unavailable';
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? 'Date unavailable'
    : date.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}
function message(error: unknown) {
  return String(error instanceof Error ? error.message : error).replace(
    /^Error invoking remote method '[^']+': Error: /,
    '',
  );
}

function Tile({
  row,
  backup,
  selected,
  onSelect,
  onPreview,
}: {
  row: Row;
  backup: string;
  selected: boolean;
  onSelect: () => void;
  onPreview: () => void;
}) {
  const ref = useRef<HTMLButtonElement>(null);
  const key = backup + '\0' + row.id;
  const [url, setUrl] = useState(() => thumbnailCache.get(key) || '');
  useEffect(() => {
    setUrl(thumbnailCache.get(key) || '');
    let alive = true;
    const observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        observer.disconnect();
        if (row.video || thumbnailCache.has(key)) return;
        queueThumbnail(async () => {
          if (!alive) return;
          try {
            const result = await api.call('thumbnail', { backup, file: row.id });
            if (!alive) return;
            thumbnailCache.set(key, result);
            while (thumbnailCache.size > 240)
              thumbnailCache.delete(thumbnailCache.keys().next().value!);
            setUrl(result);
          } catch {
            /* Unsupported original formats retain a useful placeholder. */
          }
        });
      },
      { rootMargin: '120px' },
    );
    if (ref.current) observer.observe(ref.current);
    return () => {
      alive = false;
      observer.disconnect();
    };
  }, [backup, key, row.id, row.video]);
  return (
    <article className={'gallery-tile ' + (selected ? 'is-selected' : '')}>
      <button
        ref={ref}
        className="gallery-tile-open"
        onClick={onSelect}
        onDoubleClick={onPreview}
        onKeyDown={(event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            onPreview();
          }
        }}
        aria-label={`${row.name}. ${humanBytes(row.size)}. Select, or press Enter to preview.`}
        aria-pressed={selected}
      >
        <span className="gallery-tile-image">
          {url ? (
            <img src={url} alt="" loading="lazy" draggable={false} />
          ) : row.video ? (
            <Play size={30} />
          ) : (
            <Image size={30} />
          )}
        </span>
        <span className="gallery-tile-copy">
          <b title={row.name}>{row.name}</b>
          <span>
            {humanDate(row.date)} · {humanBytes(row.size)}
          </span>
        </span>
        {selected && (
          <span className="gallery-selection">
            <Check size={15} />
          </span>
        )}
        {row.video && (
          <span className="gallery-video-label">
            <Play size={10} /> Video
          </span>
        )}
        {row.decision === 'keep' && (
          <span className="gallery-kept-label">
            <CheckCircle2 size={14} />
            <span className="sr-only">Kept</span>
          </span>
        )}
      </button>
      <button
        className="gallery-tile-preview"
        aria-label={'Preview ' + row.name}
        onClick={onPreview}
      >
        <Image size={14} />
      </button>
    </article>
  );
}

function MediaView({ row, backup }: { row: Row; backup: string }) {
  const [preview, setPreview] = useState<Row | null>(null);
  const [error, setError] = useState('');
  useEffect(() => {
    let alive = true;
    let token = '';
    setPreview(null);
    setError('');
    api
      .call('galleryPreview', { backup, file: row.id })
      .then((result) => {
        token = result.token;
        if (alive) setPreview(result);
        else if (token) api.call('galleryRelease', { token }).catch(() => {});
      })
      .catch((error) => {
        if (alive) setError(message(error));
      });
    return () => {
      alive = false;
      if (token) api.call('galleryRelease', { token }).catch(() => {});
    };
  }, [backup, row.id]);
  if (error)
    return (
      <div className="gallery-media-message" role="alert">
        <Image size={28} />
        <b>Preview unavailable</b>
        <p>{error}</p>
        <p>Export the original to open it in a compatible Windows app.</p>
      </div>
    );
  if (!preview)
    return (
      <div className="gallery-media-message" role="status">
        <Loader2 className="gallery-spinner" size={28} />
        <span>Opening preview…</span>
      </div>
    );
  const url = preview.url || `phosphor-media://preview/${preview.token}`;
  return row.video ? (
    <video
      key={row.id}
      controls
      preload="metadata"
      src={url}
      onError={() => setError('This video uses a codec that the preview player cannot decode.')}
      aria-label={row.name}
    />
  ) : (
    <img
      src={url}
      alt={row.name}
      draggable={false}
      onError={() => setError('This image format could not be decoded.')}
    />
  );
}

function Preview({
  row,
  backup,
  onClose,
  onMove,
  onExport,
  position,
  total,
}: {
  row: Row;
  backup: string;
  onClose: () => void;
  onMove: (direction: number) => void;
  onExport: () => void;
  position: number;
  total: number;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  const moveRef = useRef(onMove);
  moveRef.current = onMove;
  useEffect(() => {
    const previous = document.activeElement as HTMLElement;
    ref.current?.querySelector<HTMLButtonElement>('.gallery-preview-close')?.focus();
    const keys = (event: KeyboardEvent) => {
      if (event.key === 'Escape') closeRef.current();
      if (event.key === 'ArrowLeft') {
        event.preventDefault();
        moveRef.current(-1);
      }
      if (event.key === 'ArrowRight') {
        event.preventDefault();
        moveRef.current(1);
      }
      if (event.key === 'Tab' && ref.current) {
        const controls = [
          ...ref.current.querySelectorAll<HTMLElement>(
            'button:not(:disabled),video,[tabindex="0"]',
          ),
        ];
        const first = controls[0],
          last = controls.at(-1);
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last?.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first?.focus();
        }
      }
    };
    document.addEventListener('keydown', keys);
    return () => {
      document.removeEventListener('keydown', keys);
      previous?.focus();
    };
  }, []);
  return (
    <div
      className="gallery-preview-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div
        ref={ref}
        role="dialog"
        aria-modal="true"
        aria-label={'Preview ' + row.name}
        className="gallery-preview-dialog"
      >
        <header>
          <div>
            <b>{row.name}</b>
            <span>
              {humanDate(row.date)} · {humanBytes(row.size)}
            </span>
          </div>
          <button className="button" onClick={onExport}>
            <Download size={16} /> Export original
          </button>
          <button
            className="icon-button gallery-preview-close"
            aria-label="Close preview"
            onClick={onClose}
          >
            <X size={20} />
          </button>
        </header>
        <div className="gallery-preview-stage">
          <button
            className="gallery-preview-arrow previous"
            aria-label="Previous item"
            disabled={position === 0}
            onClick={() => onMove(-1)}
          >
            <ChevronLeft size={25} />
          </button>
          <MediaView backup={backup} row={row} />
          <button
            className="gallery-preview-arrow next"
            aria-label="Next item"
            disabled={position >= total - 1}
            onClick={() => onMove(1)}
          >
            <ChevronRight size={25} />
          </button>
        </div>
        <footer>
          <span>
            {position + 1} of {total.toLocaleString()}
          </span>
          <span>← → Browse · Esc Close</span>
          {row.dateSource && !['capture', 'captured'].includes(row.dateSource) && (
            <span>Date from backup file metadata</span>
          )}
        </footer>
      </div>
    </div>
  );
}

export default function Gallery({
  backup,
  onNotify,
  onJob,
}: {
  backup: string;
  onNotify?: (text: string, error?: boolean) => void;
  onJob?: () => void;
}) {
  const [tab, setTab] = useState<Tab>('library');
  const [collection, setCollection] = useState<Collection>('all');
  const [query, setQuery] = useState('');
  const [search, setSearch] = useState('');
  const [mediaType, setMediaType] = useState('all');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [sort, setSort] = useState('date');
  const [direction, setDirection] = useState('desc');
  const [tileSize, setTileSize] = useState(
    () => localStorage.getItem('phosphor-gallery-size') || 'medium',
  );
  const [data, setData] = useState<Row>({ rows: [], total: 0, counts: { kept: 0, bin: 0 } });
  const [offset, setOffset] = useState(0);
  const [revision, setRevision] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [preview, setPreview] = useState<Row | null>(null);
  const [reviewIndex, setReviewIndex] = useState(0);
  const [undo, setUndo] = useState<{ file: string; previous: Decision }[]>([]);
  const [acting, setActing] = useState(false);
  const [dragX, setDragX] = useState(0);
  const pointer = useRef<{ id: number; x: number } | null>(null);
  const [scanMode, setScanMode] = useState('exact');
  const [scanLimit, setScanLimit] = useState(20000);
  const [scanJob, setScanJob] = useState<Row | null>(null);
  const [groups, setGroups] = useState<Row>({ groups: [], ready: false, totalGroups: 0 });
  const [groupOffset, setGroupOffset] = useState(0);
  const rows: Row[] = data.rows || [];
  const current = rows[reviewIndex];
  const notify = useCallback(
    (text: string, isError = false) => onNotify?.(text, isError),
    [onNotify],
  );

  useEffect(() => {
    const timer = setTimeout(() => {
      setSearch(query);
      setOffset(0);
    }, 250);
    return () => clearTimeout(timer);
  }, [query]);
  useEffect(() => {
    setSelected(new Set());
    setOffset(0);
    setReviewIndex(0);
  }, [backup, collection, tab, mediaType, dateFrom, dateTo, sort, direction]);
  useEffect(() => {
    setUndo([]);
    setGroups({ groups: [], ready: false, totalGroups: 0 });
    setScanJob(null);
    thumbnailCache.clear();
  }, [backup]);
  useEffect(
    () => () => {
      thumbnailCache.clear();
    },
    [backup],
  );
  useEffect(() => {
    localStorage.setItem('phosphor-gallery-size', tileSize);
  }, [tileSize]);
  useEffect(() => {
    let alive = true;
    if (tab === 'duplicates') return;
    setLoading(true);
    setError('');
    api
      .call('galleryList', {
        backup,
        query: search,
        offset,
        limit: PAGE_SIZE,
        filters: { dateFrom, dateTo, mediaType },
        sort: { key: sort, direction },
        review: tab === 'review' ? 'unreviewed' : collection,
      })
      .then((result) => {
        if (alive) {
          setData(result);
          setReviewIndex(0);
        }
      })
      .catch((error) => {
        if (alive) {
          setData({ rows: [], total: 0, counts: data.counts });
          setError(message(error));
        }
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [
    backup,
    search,
    offset,
    mediaType,
    dateFrom,
    dateTo,
    sort,
    direction,
    collection,
    tab,
    revision,
  ]);
  const refreshGroups = useCallback(async () => {
    try {
      setGroups(
        await api.call('galleryGroups', { backup, mode: scanMode, offset: groupOffset, limit: 40 }),
      );
    } catch (error) {
      notify(message(error), true);
    }
  }, [backup, scanMode, groupOffset, notify]);
  useEffect(() => {
    if (tab === 'duplicates') refreshGroups();
  }, [tab, refreshGroups]);
  useEffect(
    () =>
      api.onEvent((event) => {
        if (event.event !== 'job' || !scanJob?.id || event.data?.id !== scanJob.id) return;
        setScanJob(event.data);
        if (event.data.status === 'completed') {
          refreshGroups();
          notify('Duplicate scan completed.');
        } else if (event.data.status === 'failed') notify(event.data.detail, true);
      }),
    [scanJob?.id, refreshGroups, notify],
  );
  // Recover the job state if it completed before this component subscribed.
  useEffect(() => {
    if (scanJob?.status !== 'running') return;
    const timer = setInterval(
      () =>
        api
          .call('status')
          .then((status) => {
            const job = status.jobs?.find((item: Row) => item.id === scanJob.id);
            if (job) {
              setScanJob(job);
              if (job.status === 'completed') refreshGroups();
            }
          })
          .catch(() => {}),
      2000,
    );
    return () => clearInterval(timer);
  }, [scanJob?.id, scanJob?.status, refreshGroups]);

  const exportFiles = useCallback(
    async (files: string[]) => {
      if (!files.length) return;
      try {
        const destination = await api.choose('folder', { title: 'Export gallery originals' });
        if (!destination) return;
        await api.call('extractFiles', { backup, ids: files, destination });
        notify('Export added to Activity.');
        onJob?.();
      } catch (error) {
        notify(message(error), true);
      }
    },
    [backup, notify, onJob],
  );
  const decide = useCallback(
    async (files: string[], decision: Decision, allowUndo = false) => {
      if (acting || !files.length) return;
      setActing(true);
      try {
        const prior =
          allowUndo && files.length === 1
            ? rows.find((row) => row.id === files[0])?.decision
            : null;
        await api.call('galleryReviewSet', { backup, files, decision });
        if (allowUndo)
          setUndo((stack) => [
            ...stack.slice(-49),
            {
              file: files[0],
              previous: prior === 'keep' ? 'keep' : prior === 'bin' ? 'bin' : 'reset',
            },
          ]);
        setSelected(new Set());
        if (tab === 'duplicates') await refreshGroups();
        else {
          setData((previous) => ({
            ...previous,
            rows: previous.rows.filter((row: Row) => !files.includes(row.id)),
          }));
          setRevision((value) => value + 1);
        }
        if (decision === 'reset') notify('Restored to the gallery.');
        return true;
      } catch (error) {
        notify(message(error), true);
        return false;
      } finally {
        setActing(false);
        setDragX(0);
      }
    },
    [acting, backup, rows, notify, tab, refreshGroups],
  );
  const undoLast = useCallback(async () => {
    const last = undo.at(-1);
    if (!last || acting) return;
    if (await decide([last.file], last.previous)) setUndo((stack) => stack.slice(0, -1));
  }, [undo, acting, decide]);
  const decisionRef = useRef(decide);
  decisionRef.current = decide;
  const currentRef = useRef(current);
  currentRef.current = current;
  const undoRef = useRef(undoLast);
  undoRef.current = undoLast;
  useEffect(() => {
    if (tab !== 'review' || preview) return;
    const keys = (event: KeyboardEvent) => {
      if ((event.target as HTMLElement)?.closest('input,select,textarea,video')) return;
      if (event.key === 'ArrowLeft' && currentRef.current) {
        event.preventDefault();
        decisionRef.current([currentRef.current.id], 'bin', true);
      }
      if (event.key === 'ArrowRight' && currentRef.current) {
        event.preventDefault();
        decisionRef.current([currentRef.current.id], 'keep', true);
      }
      if (event.ctrlKey && event.key.toLowerCase() === 'z') {
        event.preventDefault();
        undoRef.current();
      }
    };
    document.addEventListener('keydown', keys);
    return () => document.removeEventListener('keydown', keys);
  }, [tab, preview]);
  const dragStart = (event: PointerEvent<HTMLDivElement>) => {
    if (
      event.button !== 0 ||
      !current ||
      acting ||
      current.video ||
      (event.target as HTMLElement).closest('button,video')
    )
      return;
    pointer.current = { id: event.pointerId, x: event.clientX };
    event.currentTarget.setPointerCapture(event.pointerId);
  };
  const dragEnd = (event: PointerEvent<HTMLDivElement>) => {
    if (!pointer.current) return;
    const difference = event.clientX - pointer.current.x;
    pointer.current = null;
    setDragX(0);
    if (Math.abs(difference) > 90 && current)
      decide([current.id], difference < 0 ? 'bin' : 'keep', true);
  };
  const startScan = async () => {
    try {
      const result = await api.call('galleryScan', {
        backup,
        mode: scanMode,
        max_items: scanLimit,
      });
      setScanJob({ id: result.job, status: 'running', percent: 0, detail: 'Preparing scan…' });
      onJob?.();
    } catch (error) {
      notify(message(error), true);
    }
  };
  const openPreview = (row: Row) => setPreview(row);
  const movePreview = async (move: number) => {
    if (!preview) return;
    const index = rows.findIndex((row) => row.id === preview.id);
    if (index >= 0 && rows[index + move]) {
      setPreview(rows[index + move]);
      return;
    }
    if (index < 0) return;
    const nextOffset = offset + (move > 0 ? PAGE_SIZE : -PAGE_SIZE);
    if (nextOffset < 0 || nextOffset >= data.total) return;
    try {
      const next = await api.call('galleryList', {
        backup,
        query: search,
        offset: nextOffset,
        limit: PAGE_SIZE,
        filters: { dateFrom, dateTo, mediaType },
        sort: { key: sort, direction },
        review: collection,
      });
      const row = move > 0 ? next.rows[0] : next.rows.at(-1);
      if (row) {
        setOffset(nextOffset);
        setPreview(row);
      }
    } catch (error) {
      notify(message(error), true);
    }
  };
  const resetFilters = () => {
    setQuery('');
    setDateFrom('');
    setDateTo('');
    setMediaType('all');
    setOffset(0);
  };
  const toggle = (id: string) =>
    setSelected((previous) => {
      const next = new Set(previous);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  const pageStart = rows.length ? offset + 1 : 0;
  const pageEnd = offset + rows.length;

  return (
    <section className="gallery-workspace" aria-label="Photo and video gallery">
      <div className="gallery-tabs" role="tablist" aria-label="Gallery views">
        <button role="tab" aria-selected={tab === 'library'} onClick={() => setTab('library')}>
          <Grid2X2 size={16} /> Library
        </button>
        <button role="tab" aria-selected={tab === 'review'} onClick={() => setTab('review')}>
          <ListChecks size={16} /> Snapshot review
        </button>
      </div>
      {tab !== 'duplicates' && (
        <>
          <div className="gallery-toolbar">
            <label className="gallery-search">
              <Search size={16} />
              <input
                type="search"
                aria-label="Find photos and videos"
                placeholder="Find a filename"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
              />
            </label>
            <label className="gallery-control">
              <span>Media</span>
              <select value={mediaType} onChange={(event) => setMediaType(event.target.value)}>
                <option value="all">Photos & videos</option>
                <option value="photos">Photos</option>
                <option value="videos">Videos</option>
              </select>
            </label>
            <label className="gallery-control">
              <span>From</span>
              <input
                type="date"
                value={dateFrom}
                max={dateTo || undefined}
                onChange={(event) => setDateFrom(event.target.value)}
              />
            </label>
            <label className="gallery-control">
              <span>To</span>
              <input
                type="date"
                value={dateTo}
                min={dateFrom || undefined}
                onChange={(event) => setDateTo(event.target.value)}
              />
            </label>
            <label className="gallery-control">
              <span>Sort</span>
              <select value={sort} onChange={(event) => setSort(event.target.value)}>
                <option value="date">Date</option>
                <option value="size">Storage size</option>
                <option value="name">Filename</option>
              </select>
            </label>
            <button
              className="icon-button gallery-sort-direction"
              aria-label={
                direction === 'asc'
                  ? 'Sort ascending. Switch to descending.'
                  : 'Sort descending. Switch to ascending.'
              }
              onClick={() => setDirection((value) => (value === 'asc' ? 'desc' : 'asc'))}
            >
              {direction === 'asc' ? <ArrowUp size={16} /> : <ArrowDown size={16} />}
            </button>
            {(query || dateFrom || dateTo || mediaType !== 'all') && (
              <button className="text-button" onClick={resetFilters}>
                Clear filters
              </button>
            )}
          </div>
          {error ? (
            <div className="gallery-error" role="alert">
              <b>Gallery couldn’t be opened</b>
              <p>{error}</p>
              <button className="button" onClick={() => setRevision((value) => value + 1)}>
                Try again
              </button>
            </div>
          ) : (
            <>
              {tab === 'library' ? (
                <>
                  <div className="gallery-collection-bar">
                    <div className="gallery-collections" aria-label="Gallery collections">
                      {(['all', 'kept', 'bin'] as Collection[]).map((value) => (
                        <button
                          key={value}
                          aria-pressed={collection === value}
                          onClick={() => setCollection(value)}
                        >
                          {value === 'all'
                            ? 'All media'
                            : value === 'kept'
                              ? `Kept (${data.counts?.kept || 0})`
                              : `Review bin (${data.counts?.bin || 0})`}
                        </button>
                      ))}
                    </div>
                    <label className="gallery-control gallery-size-control">
                      <span>Tiles</span>
                      <select
                        value={tileSize}
                        onChange={(event) => setTileSize(event.target.value)}
                      >
                        <option value="small">Small</option>
                        <option value="medium">Medium</option>
                        <option value="large">Large</option>
                      </select>
                    </label>
                  </div>
                  {collection === 'bin' && (
                    <p className="gallery-context-note">
                      This is a reversible review bin. Originals remain in the backup and on your
                      iPhone.
                    </p>
                  )}
                  {selected.size > 0 && (
                    <div className="gallery-selection-bar">
                      <span>{selected.size.toLocaleString()} selected</span>
                      <button className="button" onClick={() => exportFiles([...selected])}>
                        <Download size={15} /> Export originals
                      </button>
                      {collection === 'bin' ? (
                        <button
                          className="button"
                          disabled={acting}
                          onClick={() => decide([...selected], 'reset')}
                        >
                          <Undo2 size={15} /> Restore to gallery
                        </button>
                      ) : (
                        <>
                          <button
                            className="button"
                            disabled={acting}
                            onClick={() => decide([...selected], 'keep')}
                          >
                            <Check size={15} /> Keep
                          </button>
                          <button
                            className="button"
                            disabled={acting}
                            onClick={() => decide([...selected], 'bin')}
                          >
                            <Trash2 size={15} /> Review bin
                          </button>
                        </>
                      )}
                      <button className="text-button" onClick={() => setSelected(new Set())}>
                        Clear selection
                      </button>
                    </div>
                  )}
                  {loading ? (
                    <div className="gallery-loading" role="status">
                      <Loader2 className="gallery-spinner" size={20} /> Loading gallery…
                    </div>
                  ) : rows.length ? (
                    <div className={'gallery-grid size-' + tileSize}>
                      {rows.map((row) => (
                        <Tile
                          key={row.id}
                          row={row}
                          backup={backup}
                          selected={selected.has(row.id)}
                          onSelect={() => toggle(row.id)}
                          onPreview={() => openPreview(row)}
                        />
                      ))}
                    </div>
                  ) : (
                    <div className="gallery-empty">
                      <Image size={30} />
                      <h3>
                        {collection === 'bin'
                          ? 'Review bin is empty'
                          : collection === 'kept'
                            ? 'No kept items yet'
                            : 'No matching media'}
                      </h3>
                      <p>
                        {collection === 'all'
                          ? 'Adjust the filters, or select a backup that contains camera roll files.'
                          : 'Use Review to decide which items to keep.'}
                      </p>
                    </div>
                  )}
                </>
              ) : (
                <>
                  <div className="gallery-review-heading">
                    <div>
                      <h3>Review this backup snapshot</h3>
                      <p>
                        ← Review bin · → Keep · Ctrl Z Undo. Drag a photo left or right with the
                        mouse.
                      </p>
                    </div>
                    <button className="button" disabled={!undo.length || acting} onClick={undoLast}>
                      <Undo2 size={16} /> Undo
                    </button>
                  </div>
                  <p className="gallery-context-note">
                    Review decisions are saved locally. Photos in the review bin can be restored;
                    the original backup and iPhone stay unchanged.
                  </p>
                  {loading ? (
                    <div className="gallery-loading" role="status">
                      <Loader2 className="gallery-spinner" size={20} /> Loading next item…
                    </div>
                  ) : current ? (
                    <div className="gallery-review-card">
                      <div
                        className={
                          'gallery-review-media ' +
                          (dragX < -35 ? 'toward-bin' : dragX > 35 ? 'toward-keep' : '')
                        }
                        onPointerDown={dragStart}
                        onPointerMove={(event) => {
                          if (pointer.current)
                            setDragX(
                              Math.max(-160, Math.min(160, event.clientX - pointer.current.x)),
                            );
                        }}
                        onPointerUp={dragEnd}
                        onPointerCancel={() => {
                          pointer.current = null;
                          setDragX(0);
                        }}
                      >
                        <div
                          className="gallery-review-render"
                          style={{ transform: `translateX(${dragX}px) rotate(${dragX / 35}deg)` }}
                        >
                          <MediaView backup={backup} row={current} />
                        </div>
                        {Math.abs(dragX) > 35 && (
                          <span className="gallery-swipe-label">
                            {dragX < 0 ? 'Review bin' : 'Keep'}
                          </span>
                        )}
                      </div>
                      <div className="gallery-review-details">
                        <div>
                          <b>{current.name}</b>
                          <span>
                            {humanDate(current.date)} · {humanBytes(current.size)}
                          </span>
                        </div>
                        <span>{data.total.toLocaleString()} left to review</span>
                      </div>
                      <div className="gallery-review-actions">
                        <button
                          className="button"
                          disabled={acting}
                          onClick={() => decide([current.id], 'bin', true)}
                        >
                          <ArrowLeft size={16} />
                          <Trash2 size={16} /> Review bin
                        </button>
                        <button className="button" onClick={() => exportFiles([current.id])}>
                          <Download size={16} /> Export
                        </button>
                        <button
                          className="button primary"
                          disabled={acting}
                          onClick={() => decide([current.id], 'keep', true)}
                        >
                          Keep <Check size={16} />
                          <ArrowRight size={16} />
                        </button>
                      </div>
                    </div>
                  ) : (
                    <div className="gallery-empty">
                      <CheckCircle2 size={30} />
                      <h3>Snapshot review complete</h3>
                      <p>
                        No unreviewed items match these filters. Kept items and the reversible
                        review bin are in Library.
                      </p>
                      <button
                        className="button"
                        onClick={() => {
                          setTab('library');
                          setCollection('kept');
                        }}
                      >
                        Open kept items
                      </button>
                    </div>
                  )}
                </>
              )}
              {tab === 'library' && data.total > 0 && (
                <footer className="gallery-pagination">
                  <button
                    className="button"
                    disabled={offset === 0 || loading}
                    onClick={() => {
                      setOffset((value) => Math.max(0, value - PAGE_SIZE));
                      setSelected(new Set());
                    }}
                  >
                    <ChevronLeft size={16} /> Previous
                  </button>
                  <span>
                    {pageStart.toLocaleString()}–{pageEnd.toLocaleString()} of{' '}
                    {data.total.toLocaleString()} · Double-click to preview
                  </span>
                  <button
                    className="button"
                    disabled={pageEnd >= data.total || loading}
                    onClick={() => {
                      setOffset((value) => value + PAGE_SIZE);
                      setSelected(new Set());
                    }}
                  >
                    Next <ChevronRight size={16} />
                  </button>
                </footer>
              )}
            </>
          )}
        </>
      )}
      {tab === 'duplicates' && (
        <div className="gallery-duplicates">
          <div className="gallery-duplicate-header">
            <div>
              <h3>Find duplicate and similar photos</h3>
              <p>
                Exact matches compare file contents. Similar matches use a perceptual fingerprint
                and always need your review.
              </p>
            </div>
          </div>
          <div className="gallery-duplicate-controls">
            <label className="gallery-control">
              <span>Compare</span>
              <select
                disabled={scanJob?.status === 'running'}
                value={scanMode}
                onChange={(event) => {
                  setScanMode(event.target.value);
                  setGroupOffset(0);
                }}
              >
                <option value="exact">Exact duplicates, including videos</option>
                <option value="similar">Similar photos</option>
              </select>
            </label>
            <label className="gallery-control">
              <span>Scan up to</span>
              <select
                value={scanLimit}
                disabled={scanJob?.status === 'running'}
                onChange={(event) => setScanLimit(Number(event.target.value))}
              >
                <option value={5000}>5,000 items</option>
                <option value={20000}>20,000 items</option>
                <option value={100000}>100,000 items</option>
              </select>
            </label>
            <button
              className="button primary"
              disabled={scanJob?.status === 'running'}
              onClick={startScan}
            >
              {scanJob?.status === 'running' ? (
                <Loader2 size={16} className="gallery-spinner" />
              ) : (
                <Search size={16} />
              )}{' '}
              {scanJob?.status === 'running' ? 'Scanning…' : 'Start scan'}
            </button>
            {scanJob?.status === 'running' && (
              <button
                className="button"
                onClick={() =>
                  api
                    .call('cancelJob', { id: scanJob.id })
                    .catch((error) => notify(message(error), true))
                }
              >
                Cancel
              </button>
            )}
          </div>
          {scanJob?.status === 'running' && (
            <div className="gallery-scan-progress" role="status">
              <progress max={100} value={scanJob.percent || 0} />
              <span>{scanJob.detail}</span>
            </div>
          )}
          {scanJob?.status === 'failed' && (
            <div className="gallery-error" role="alert">
              {scanJob.detail}
            </div>
          )}
          <p className="gallery-context-note">
            Scans run locally and can be cancelled. Nothing is removed automatically. Moving a match
            to the review bin changes its gallery annotation only.
          </p>
          {groups.ready ? (
            <>
              <div className="gallery-scan-summary">
                <b>{groups.totalGroups.toLocaleString()} groups</b>
                <span>
                  {groups.scanned?.toLocaleString()} items checked
                  {groups.skipped ? ` · ${groups.skipped} unreadable items skipped` : ''}
                  {groups.comparisonLimited
                    ? ' · Some similar-photo comparisons were capped'
                    : groups.truncated
                      ? ' · Scan limited; increase the limit to check more items'
                      : ''}
                </span>
              </div>
              {groups.groups.length ? (
                groups.groups.map((group: Row) => (
                  <article key={group.id} className="gallery-duplicate-group">
                    <header>
                      <b>
                        {group.kind === 'exact' ? 'Exact duplicates' : 'Similar photo suggestion'}
                      </b>
                      <span>
                        {group.itemCount || group.items.length} items
                        {group.kind === 'exact'
                          ? ` · ${humanBytes(group.bytesRecoverable)} in extra copies`
                          : ' · Compare visually before deciding'}
                      </span>
                    </header>
                    <div className="gallery-duplicate-items">
                      {group.items.map((row: Row) => (
                        <div key={row.id}>
                          <Tile
                            row={row}
                            backup={backup}
                            selected={selected.has(row.id)}
                            onSelect={() => toggle(row.id)}
                            onPreview={() => openPreview(row)}
                          />
                          <button
                            className="button"
                            disabled={acting}
                            onClick={() =>
                              decide([row.id], row.decision === 'bin' ? 'reset' : 'bin')
                            }
                          >
                            {row.decision === 'bin' ? <Undo2 size={14} /> : <Trash2 size={14} />}{' '}
                            {row.decision === 'bin' ? 'Restore to gallery' : 'Review bin'}
                          </button>
                        </div>
                      ))}
                    </div>
                    {group.itemCount > group.items.length && (
                      <p className="gallery-context-note">
                        Showing the first {group.items.length} items in this group. Find the
                        filename in Library to review the remaining copies.
                      </p>
                    )}
                  </article>
                ))
              ) : (
                <div className="gallery-empty">
                  <CheckCircle2 size={30} />
                  <h3>No matches found</h3>
                  <p>
                    {groups.truncated
                      ? 'Increase the scan limit to compare more items.'
                      : 'No duplicate groups were found among the readable items in this scan.'}
                  </p>
                </div>
              )}
              {groups.totalGroups > 40 && (
                <footer className="gallery-pagination">
                  <button
                    className="button"
                    disabled={groupOffset === 0}
                    onClick={() => setGroupOffset((value) => Math.max(0, value - 40))}
                  >
                    <ChevronLeft size={16} /> Previous groups
                  </button>
                  <span>
                    {groupOffset + 1}–{Math.min(groupOffset + 40, groups.totalGroups)} of{' '}
                    {groups.totalGroups}
                  </span>
                  <button
                    className="button"
                    disabled={groupOffset + 40 >= groups.totalGroups}
                    onClick={() => setGroupOffset((value) => value + 40)}
                  >
                    Next groups <ChevronRight size={16} />
                  </button>
                </footer>
              )}
            </>
          ) : (
            <div className="gallery-empty">
              <Copy size={30} />
              <h3>Ready to compare</h3>
              <p>
                Choose a comparison and start a scan. Results remain available while Phosphor is
                open.
              </p>
            </div>
          )}
        </div>
      )}
      {preview && (
        <Preview
          row={preview}
          backup={backup}
          onClose={() => setPreview(null)}
          onMove={movePreview}
          onExport={() => exportFiles([preview.id])}
          position={Math.max(0, offset + rows.findIndex((row) => row.id === preview.id))}
          total={tab === 'duplicates' ? 1 : data.total}
        />
      )}
    </section>
  );
}
