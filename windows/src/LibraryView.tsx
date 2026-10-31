import { useEffect, useState } from 'react';
import { Download, FileText, Info, MessageCircle, Search, X } from 'lucide-react';
import { api, type Row } from './api';
import { Button, Empty, Loading, Modal, Pager, date, errorMessage } from './ui';

function boundary(value: string, through = false) {
  if (!value) return undefined;
  const stamp = new Date(value + 'T00:00:00');
  if (Number.isNaN(stamp.getTime())) return undefined;
  if (through) stamp.setDate(stamp.getDate() + 1);
  return stamp.toISOString();
}
function duration(value: number) {
  const seconds = Math.max(0, Math.round(Number(value) || 0));
  return seconds >= 3600
    ? `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m ${seconds % 60}s`
    : seconds >= 60
      ? `${Math.floor(seconds / 60)}m ${seconds % 60}s`
      : `${seconds}s`;
}
function noteStatus(row: Row) {
  if (row.bodyStatus === 'locked' || row.locked === true || Number(row.locked) === 1)
    return row.previewMessage || 'This note has its own password. Open it on your Apple device.';
  if (row.bodyStatus === 'snippet')
    return row.previewMessage || 'Only the stored preview is available.';
  if (row.bodyStatus === 'unavailable')
    return row.previewMessage || 'This note’s text is not readable in this backup.';
  return 'Plain text from this backup. Formatting and attachments remain in the original files.';
}
function fields(row: Row, kind: string): [string, string][] {
  if (kind === 'contacts')
    return [
      ['First name', row.first],
      ['Last name', row.last],
      ['Organization', row.organization],
      ['Phone', row.phones?.join(' · ')],
      ['Email', row.emails?.join(' · ')],
    ].filter((entry): entry is [string, string] => !!entry[1]);
  if (kind === 'calls')
    return [
      ['Duration', duration(row.duration)],
      ['Call type', row.type == null ? 'Not reported' : String(row.type)],
    ];
  if (kind === 'safari')
    return [
      ['Address', row.detail || ''],
      ['Visits', String(row.count ?? 0)],
    ];
  if (['music', 'watch', 'health'].includes(kind))
    return [
      ['Backup domain', row.domain || ''],
      ['Original path', row.path || ''],
    ];
  return [];
}

function availabilityTitle(data: Row, kind: string) {
  const status = data.availability?.status;
  if (kind === 'whatsapp') {
    if (status === 'cloud_only' || status === 'empty') return 'WhatsApp chat contents are missing';
    if (status === 'protected') return 'WhatsApp archive is protected';
    if (status === 'unreadable') return 'The chat archive couldn’t be read';
  }
  return status === 'unsupported'
    ? 'This format isn’t supported yet'
    : 'Not available in this backup';
}
function availabilityDetail(data: Row, kind: string) {
  const details = data.availability?.details;
  if (!details) return '';
  if (kind === 'whatsapp')
    return [
      details.emptyChatArchives
        ? `${details.emptyChatArchives} empty chat archive${details.emptyChatArchives === 1 ? '' : 's'}`
        : '',
      details.auxiliaryDatabases ? `${details.auxiliaryDatabases} auxiliary databases` : '',
      details.unreadableDatabases
        ? `${details.unreadableDatabases} other databases couldn’t be inspected`
        : '',
    ]
      .filter(Boolean)
      .join(' · ');
  return typeof details === 'string' ? details : JSON.stringify(details);
}

export default function LibraryView({
  backup,
  kind,
  revision = 0,
  onNotify,
}: {
  backup: string;
  kind: string;
  revision?: number;
  onNotify: (message: string, error?: boolean) => void;
}) {
  const [query, setQuery] = useState(''),
    [term, setTerm] = useState(''),
    [offset, setOffset] = useState(0),
    [data, setData] = useState<Row>({ rows: [], total: 0 }),
    [loading, setLoading] = useState(true),
    [error, setError] = useState('');
  const [from, setFrom] = useState(''),
    [to, setTo] = useState(''),
    [minimum, setMinimum] = useState(''),
    [maximum, setMaximum] = useState(''),
    [sort, setSort] = useState(kind === 'contacts' ? 'asc' : 'desc');
  const [selected, setSelected] = useState<Set<string>>(new Set()),
    [detail, setDetail] = useState<Row | null>(null),
    [chat, setChat] = useState<Row | null>(null),
    [chatData, setChatData] = useState<Row>({ rows: [], total: 0 }),
    [chatOffset, setChatOffset] = useState(0),
    [chatLoading, setChatLoading] = useState(false),
    [chatError, setChatError] = useState(''),
    [format, setFormat] = useState(''),
    [exporting, setExporting] = useState(false);
  const conversations = ['messages', 'whatsapp'].includes(kind),
    files = ['music', 'watch', 'health'].includes(kind),
    dated = ['calls', 'safari', 'notes'].includes(kind);
  const [exportConversation, setExportConversation] = useState(false);
  const filters = {
    dateFrom: boundary(from),
    dateTo: boundary(to, true),
    minDuration: minimum === '' ? undefined : Number(minimum),
    maxDuration: maximum === '' ? undefined : Number(maximum),
  };
  const filterError =
    from && to && from > to
      ? 'Choose an end date on or after the start date.'
      : Number(minimum) < 0 || Number(maximum) < 0
        ? 'Call duration cannot be negative.'
        : minimum !== '' && maximum !== '' && Number(minimum) > Number(maximum)
          ? 'Maximum duration must be at least the minimum duration.'
          : '';
  useEffect(() => {
    setChat(null);
    setDetail(null);
    setSelected(new Set());
    setFormat('');
    setChatData({ rows: [], total: 0 });
    setChatOffset(0);
  }, [backup, kind]);
  useEffect(() => {
    const id = setTimeout(() => {
      setTerm(query);
      setOffset(0);
      setSelected(new Set());
    }, 250);
    return () => clearTimeout(id);
  }, [query]);
  useEffect(() => {
    setOffset(0);
    setSelected(new Set());
  }, [from, to, minimum, maximum, sort]);
  useEffect(() => {
    let alive = true;
    if (filterError) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError('');
    api
      .call('backupData', {
        backup,
        kind,
        query: term,
        offset,
        limit: 100,
        ...filters,
        sort: kind === 'contacts' ? 'name' : 'date',
        order: sort,
      })
      .then((result) => {
        if (alive) {
          setData(result);
          if (result.total && offset >= result.total) setOffset(0);
        }
      })
      .catch((e) => {
        if (alive) setError(errorMessage(e));
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [backup, kind, term, offset, from, to, minimum, maximum, sort, revision, filterError]);
  useEffect(() => {
    let alive = true;
    if (!chat) return;
    setChatLoading(true);
    setChatError('');
    api
      .call('backupData', { backup, kind, chat: chat.id, offset: chatOffset, limit: 200 })
      .then((result) => {
        if (alive) {
          setChatData(result);
          if (result.available === false)
            setChatError(
              result.availability?.message ||
                'This conversation uses an unsupported message format.',
            );
        }
      })
      .catch((e) => {
        if (alive) setChatError(errorMessage(e));
      })
      .finally(() => {
        if (alive) setChatLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [backup, kind, chat, chatOffset, revision]);
  const toggle = (id: string) =>
    setSelected((old) => {
      const next = new Set(old);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  const exportItems = async () => {
    setExporting(true);
    try {
      const destination = await api.choose(
        files ? 'folder' : 'save',
        files
          ? { title: 'Extract selected files' }
          : {
              name: `Phosphor-${kind}.${format}`,
              filters: [{ name: format.toUpperCase(), extensions: [format] }],
            },
      );
      if (destination) {
        await api.call(
          files ? 'extractFiles' : 'exportData',
          files
            ? { backup, ids: [...selected], destination }
            : {
                backup,
                kind,
                destination,
                format,
                ids: selected.size ? [...selected] : undefined,
                chat: exportConversation ? chat?.id : undefined,
                query: exportConversation ? '' : term,
                ...filters,
                sort: kind === 'contacts' ? 'name' : 'date',
                order: exportConversation ? 'asc' : sort,
              },
        );
        onNotify('Export added to Activity');
        setFormat('');
      }
    } catch (e) {
      onNotify(errorMessage(e), true);
    } finally {
      setExporting(false);
    }
  };
  return (
    <div className="library-view">
      {['watch', 'health'].includes(kind) && (
        <div className="notice">
          <Info size={17} />
          <span>
            {kind === 'health'
              ? 'Health data is available as original files for extraction. This view does not interpret HealthKit records.'
              : 'Original Watch files from this iPhone backup are available for extraction.'}
          </span>
        </div>
      )}
      <div className="toolbar">
        <label className="search-field">
          <Search size={16} />
          <input
            aria-label="Search library"
            placeholder={conversations ? 'Search conversations' : 'Search'}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
        <span className="toolbar-count" aria-live="polite">
          {data.available === false
            ? 'Data unavailable'
            : `${(data.total || 0).toLocaleString()} ${conversations ? 'conversations' : 'items'}`}
          {selected.size ? ` · ${selected.size} selected` : ''}
        </span>
        <Button
          icon={Download}
          variant="primary"
          loading={exporting && files}
          disabled={
            loading ||
            !!error ||
            !!filterError ||
            data.available === false ||
            query !== term ||
            (files ? !selected.size : !data.total)
          }
          onClick={() => {
            setExportConversation(false);
            if (files) exportItems();
            else setFormat(kind === 'contacts' ? 'vcf' : 'html');
          }}
        >
          {files ? 'Extract selected' : selected.size ? 'Export selected' : 'Export matching'}
        </Button>
      </div>
      {dated && (
        <div className="filter-bar">
          <label>
            From
            <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
          </label>
          <label>
            Through
            <input
              type="date"
              min={from || undefined}
              value={to}
              onChange={(e) => setTo(e.target.value)}
            />
          </label>
          {kind === 'calls' && (
            <>
              <label>
                Min. seconds
                <input
                  type="number"
                  min={0}
                  value={minimum}
                  onChange={(e) => setMinimum(e.target.value)}
                />
              </label>
              <label>
                Max. seconds
                <input
                  type="number"
                  min={0}
                  value={maximum}
                  onChange={(e) => setMaximum(e.target.value)}
                />
              </label>
            </>
          )}
          <label>
            Order
            <select value={sort} onChange={(e) => setSort(e.target.value)}>
              <option value="desc">Newest first</option>
              <option value="asc">Oldest first</option>
            </select>
          </label>
          <Button
            disabled={!from && !to && !minimum && !maximum}
            onClick={() => {
              setFrom('');
              setTo('');
              setMinimum('');
              setMaximum('');
            }}
          >
            Reset
          </Button>
        </div>
      )}
      {filterError && (
        <div className="notice error" role="alert">
          <Info size={17} />
          {filterError}
        </div>
      )}
      {loading ? (
        <Loading label="Reading backup data…" />
      ) : error ? (
        <div className="panel">
          <Empty icon={Info} title="Couldn’t read this data" description={error} />
        </div>
      ) : data.available === false ? (
        <div className="panel">
          <Empty
            icon={Info}
            title={availabilityTitle(data, kind)}
            description={
              data.availability?.message || 'This optional data is absent from the backup.'
            }
          />
          {availabilityDetail(data, kind) && (
            <p className="availability-detail">{availabilityDetail(data, kind)}</p>
          )}
        </div>
      ) : !data.total ? (
        <div className="panel">
          <Empty
            icon={Search}
            title="No matching items"
            description={
              query || from || to || minimum || maximum
                ? 'Adjust the search or filters.'
                : 'This backup contains no items in this category.'
            }
          />
        </div>
      ) : conversations ? (
        <div className="conversation-layout panel">
          <div className="conversation-list">
            {data.rows.map((row: Row) => (
              <button
                key={row.id}
                className={'conversation ' + (chat?.id === row.id ? 'active' : '')}
                onClick={() => {
                  setChat(row);
                  setChatOffset(0);
                }}
              >
                <span className="avatar">{row.name?.slice(0, 2).toUpperCase()}</span>
                <div>
                  <b>{row.name}</b>
                  <small>{row.count} messages</small>
                </div>
              </button>
            ))}
          </div>
          <div className="conversation-body">
            {chat ? (
              <>
                <div className="conversation-header">
                  <div>
                    <b>{chat.name}</b>
                    <small>{chat.detail}</small>
                  </div>
                  <Button
                    icon={Download}
                    disabled={chatLoading || !!chatError || !chatData.total}
                    onClick={() => {
                      setExportConversation(true);
                      setFormat('html');
                    }}
                  >
                    Export conversation
                  </Button>
                  <button
                    className="icon-button"
                    aria-label="Close conversation"
                    onClick={() => setChat(null)}
                  >
                    <X size={17} />
                  </button>
                </div>
                {chatLoading ? (
                  <Loading label="Reading conversation…" />
                ) : chatError ? (
                  <Empty title="Couldn’t read conversation" description={chatError} />
                ) : (
                  <div className="chat-scroll">
                    {chatData.rows.map((row: Row) => (
                      <div className={'message ' + (row.outgoing ? 'outgoing' : '')} key={row.id}>
                        <small>
                          {row.outgoing ? 'You' : row.sender || chat.name || 'Unknown sender'} ·{' '}
                          {date(row.date)}
                        </small>
                        <div>{row.body || '[Attachment]'}</div>
                      </div>
                    ))}
                    {!chatData.total && (
                      <Empty
                        title="No messages"
                        description="There are no backed-up messages in this conversation."
                      />
                    )}
                  </div>
                )}
                <Pager
                  offset={chatOffset}
                  total={chatData.total}
                  limit={200}
                  onChange={setChatOffset}
                />
              </>
            ) : (
              <Empty
                icon={MessageCircle}
                title="Select a conversation"
                description="Read messages here or export a local copy."
              />
            )}
          </div>
        </div>
      ) : (
        <div className="panel table-panel">
          <table>
            <thead>
              <tr>
                <th className="check-cell">
                  <input
                    type="checkbox"
                    aria-label="Select visible items"
                    checked={
                      data.rows.length > 0 &&
                      data.rows.every((row: Row) => selected.has(String(row.id)))
                    }
                    onChange={(e) =>
                      setSelected(
                        e.target.checked
                          ? new Set(data.rows.map((row: Row) => String(row.id)))
                          : new Set(),
                      )
                    }
                  />
                </th>
                <th>{kind === 'calls' ? 'Contact' : kind === 'safari' ? 'Page' : 'Name'}</th>
                <th>{kind === 'calls' ? 'Duration & type' : 'Details'}</th>
                {dated && <th>Date</th>}
                <th className="table-action">Preview</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((row: Row) => (
                <tr
                  key={row.id}
                  className={selected.has(String(row.id)) ? 'selected' : ''}
                  onDoubleClick={() => setDetail(row)}
                >
                  <td className="check-cell">
                    <input
                      type="checkbox"
                      aria-label={'Select ' + (row.name || row.path)}
                      checked={selected.has(String(row.id))}
                      onChange={() => toggle(String(row.id))}
                    />
                  </td>
                  <td>
                    <b className="table-name">{row.name || row.path || 'Untitled'}</b>
                    {row.body && <p className="table-snippet">{row.body}</p>}
                  </td>
                  <td>
                    <span className="table-detail">
                      {kind === 'calls' && row.duration != null
                        ? duration(row.duration) + (row.type != null ? ' · Type ' + row.type : '')
                        : row.domain || row.detail || row.organization || '—'}
                    </span>
                  </td>
                  {dated && <td className="date-cell">{date(row.date)}</td>}
                  <td>
                    <button
                      className="icon-button"
                      aria-label={'Preview ' + (row.name || 'item')}
                      onClick={() => setDetail(row)}
                    >
                      <FileText size={16} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {!loading && data.total > 0 && (
        <Pager
          offset={offset}
          total={data.total}
          limit={100}
          onChange={(value) => {
            setOffset(value);
            setSelected(new Set());
          }}
        />
      )}
      {detail && (
        <Modal title={detail.name || 'Item details'} onClose={() => setDetail(null)}>
          <div className="detail-content">
            {kind === 'notes' && <p className="muted">{noteStatus(detail)}</p>}
            {detail.date && (
              <p className="detail-meta">
                {kind === 'notes' ? 'Modified · ' : ''}
                {date(detail.date)}
              </p>
            )}
            {detail.body ? (
              <div className="note-body">{detail.body}</div>
            ) : kind === 'notes' ? (
              <p className="note-body">
                {detail.bodyStatus === 'locked'
                  ? 'The note’s protected content is unavailable.'
                  : 'No readable text is stored.'}
              </p>
            ) : null}
            <dl className="detail-fields">
              {fields(detail, kind).map(([label, value]) => (
                <div key={label}>
                  <dt>{label}</dt>
                  <dd>{value}</dd>
                </div>
              ))}
            </dl>
          </div>
        </Modal>
      )}
      {!!format && (
        <Modal
          title="Export backup data"
          onClose={() => {
            if (!exporting) setFormat('');
          }}
        >
          <p className="dialog-intro">
            Save{' '}
            {exportConversation
              ? 'this conversation'
              : selected.size
                ? `${selected.size} selected items`
                : 'all matching items'}{' '}
            to a local file.{' '}
            {exportConversation
              ? 'All backed-up messages in this conversation will be included.'
              : 'Your current search and filters apply.'}
          </p>
          <label className="form-label">
            Format
            <select disabled={exporting} value={format} onChange={(e) => setFormat(e.target.value)}>
              {(kind === 'contacts' ? ['vcf', 'csv', 'json'] : ['html', 'csv', 'json', 'txt']).map(
                (value) => (
                  <option key={value} value={value}>
                    {value.toUpperCase()}
                  </option>
                ),
              )}
            </select>
          </label>
          <div className="dialog-actions">
            <Button disabled={exporting} onClick={() => setFormat('')}>
              Cancel
            </Button>
            <Button loading={exporting} variant="primary" icon={Download} onClick={exportItems}>
              Choose location
            </Button>
          </div>
        </Modal>
      )}
    </div>
  );
}
