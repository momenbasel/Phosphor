import { useEffect, useMemo, useState } from 'react';
import { ArrowLeft, ArrowRight, Download, Info, List, CalendarDays, Search } from 'lucide-react';
import { api, type Row } from './api';
import { Button, Empty, Loading, Modal, Pager, date, errorMessage } from './ui';

const dayKey = (value: Date) =>
  `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, '0')}-${String(value.getDate()).padStart(2, '0')}`;
const isAllDay = (row: Row) => row.allDay === true || Number(row.allDay) === 1;
function eventRange(row: Row) {
  if (!isAllDay(row)) return date(row.date) + (row.end ? ` — ${date(row.end)}` : '');
  const start = String(row.date || '').slice(0, 10),
    end = String(row.end || '').slice(0, 10);
  const last = end ? new Date(end + 'T12:00:00') : null;
  if (last) last.setDate(last.getDate() - 1);
  return `All day · ${start}${last && !Number.isNaN(last.getTime()) && dayKey(last) > start ? ' — ' + dayKey(last) : ''}`;
}
export default function CalendarView({
  backup,
  revision = 0,
  onNotify,
}: {
  backup: string;
  revision?: number;
  onNotify: (message: string, error?: boolean) => void;
}) {
  const [month, setMonth] = useState(
      () => new Date(new Date().getFullYear(), new Date().getMonth(), 1),
    ),
    [mode, setMode] = useState('month'),
    [query, setQuery] = useState(''),
    [rows, setRows] = useState<Row[]>([]),
    [total, setTotal] = useState(0),
    [loading, setLoading] = useState(true),
    [error, setError] = useState(''),
    [availability, setAvailability] = useState(''),
    [detail, setDetail] = useState<Row | null>(null),
    [exporting, setExporting] = useState(false);
  const [offset, setOffset] = useState(0);
  const start = new Date(month.getFullYear(), month.getMonth(), 1),
    end = new Date(month.getFullYear(), month.getMonth() + 1, 1),
    monthKey = dayKey(start).slice(0, 7),
    from = start.toISOString(),
    to = end.toISOString();
  useEffect(() => {
    setOffset(0);
    setDetail(null);
  }, [backup, from, mode, query]);
  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError('');
    setAvailability('');
    const timer = setTimeout(
      () =>
        api
          .call('backupData', {
            backup,
            kind: 'calendar',
            query,
            filters: { dayFrom: dayKey(start), dayTo: dayKey(end) },
            dateFrom: from,
            dateTo: to,
            offset: mode === 'agenda' ? offset : 0,
            limit: mode === 'agenda' ? 200 : 1000,
            order: 'asc',
          })
          .then((result) => {
            if (alive) {
              setRows(result.rows || []);
              setTotal(result.total || 0);
              if (result.available === false)
                setAvailability(
                  result.availability?.message || 'Calendar data is absent from this backup.',
                );
            }
          })
          .catch((e) => {
            if (alive) setError(errorMessage(e));
          })
          .finally(() => {
            if (alive) setLoading(false);
          }),
      180,
    );
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [backup, from, to, query, mode, offset, revision]);
  const grid = useMemo(() => {
    const first = new Date(month.getFullYear(), month.getMonth(), 1),
      shift = (first.getDay() + 6) % 7;
    return Array.from(
      { length: 42 },
      (_, i) => new Date(month.getFullYear(), month.getMonth(), i - shift + 1),
    );
  }, [month]);
  const eventsByDay = useMemo(() => {
    const groups = new Map<string, Row[]>(grid.map((day) => [dayKey(day), []]));
    for (const row of rows) {
      const begin = new Date(row.date || ''),
        finish = new Date(row.end || row.date || '');
      if (Number.isNaN(begin.getTime())) continue;
      for (const day of grid) {
        const key = dayKey(day),
          next = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
        const first = String(row.date).slice(0, 10),
          last = String(row.end || '').slice(0, 10);
        const includes = isAllDay(row)
          ? key === first || (key > first && !!last && key < last)
          : begin < next &&
            (Number.isNaN(finish.getTime()) || finish <= begin ? begin >= day : finish > day);
        if (includes) groups.get(key)?.push(row);
      }
    }
    return groups;
  }, [grid, rows]);
  const eventsFor = (day: Date) => eventsByDay.get(dayKey(day)) || [];
  const move = (delta: number) =>
    setMonth(new Date(month.getFullYear(), month.getMonth() + delta, 1));
  const exportMonth = async () => {
    setExporting(true);
    try {
      const destination = await api.choose('save', {
        name: `Calendar-${monthKey}.ics`,
        filters: [{ name: 'iCalendar', extensions: ['ics'] }],
      });
      if (destination) {
        await api.call('exportData', {
          backup,
          kind: 'calendar',
          destination,
          format: 'ics',
          dateFrom: from,
          dateTo: to,
          query,
          filters: { dayFrom: dayKey(start), dayTo: dayKey(end) },
          order: 'asc',
        });
        onNotify('Calendar export added to Activity');
      }
    } catch (e) {
      onNotify(errorMessage(e), true);
    } finally {
      setExporting(false);
    }
  };
  return (
    <div className="calendar-view">
      <div className="toolbar">
        <div className="calendar-navigation">
          <Button icon={ArrowLeft} onClick={() => move(-1)}>
            Previous
          </Button>
          <h2>{month.toLocaleDateString(undefined, { month: 'long', year: 'numeric' })}</h2>
          <Button icon={ArrowRight} onClick={() => move(1)}>
            Next
          </Button>
        </div>
        <Button
          onClick={() => setMonth(new Date(new Date().getFullYear(), new Date().getMonth(), 1))}
        >
          Today
        </Button>
        <label className="visually-hidden" htmlFor="calendar-month">
          Choose month
        </label>
        <input
          id="calendar-month"
          type="month"
          value={monthKey}
          onChange={(e) => {
            if (e.target.value) {
              const [year, monthNumber] = e.target.value.split('-').map(Number);
              const picked = new Date(year, monthNumber - 1, 1);
              if (!Number.isNaN(picked.getTime())) setMonth(picked);
            }
          }}
        />
        <div className="segmented" role="group" aria-label="Calendar view">
          <button aria-pressed={mode === 'month'} onClick={() => setMode('month')}>
            <CalendarDays size={16} />
            Month
          </button>
          <button aria-pressed={mode === 'agenda'} onClick={() => setMode('agenda')}>
            <List size={16} />
            Agenda
          </button>
        </div>
        <Button
          icon={Download}
          loading={exporting}
          disabled={!total || loading || !!error || !!availability}
          onClick={exportMonth}
        >
          Export month
        </Button>
      </div>
      <div className="toolbar">
        <label className="search-field">
          <Search size={16} />
          <input
            aria-label="Search events"
            placeholder="Search events in this month"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
        <span className="muted">
          {total.toLocaleString()} events
          {mode === 'month' && total > rows.length
            ? ' · first 1,000 shown; narrow your search or use Agenda'
            : ''}
        </span>
      </div>
      {loading ? (
        <Loading label="Reading events…" />
      ) : error || availability ? (
        <div className="panel">
          <Empty
            icon={Info}
            title={error ? 'Couldn’t read calendar' : 'Calendar unavailable'}
            description={error || availability}
          />
        </div>
      ) : mode === 'month' ? (
        <div className="calendar-grid panel">
          <div className="calendar-weekdays">
            {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((day) => (
              <span key={day}>{day}</span>
            ))}
          </div>
          <div className="calendar-days">
            {grid.map((day) => {
              const events = eventsFor(day),
                key = dayKey(day);
              return (
                <div
                  key={key}
                  className={
                    'calendar-day ' +
                    (day.getMonth() !== month.getMonth() ? 'outside ' : '') +
                    (key === dayKey(new Date()) ? 'today' : '')
                  }
                >
                  <span className="calendar-day-number">{day.getDate()}</span>
                  {events.slice(0, 3).map((row) => (
                    <button
                      key={row.id}
                      title={eventRange(row) + ' · ' + (row.name || 'Untitled event')}
                      aria-label={(row.name || 'Untitled event') + ' · ' + eventRange(row)}
                      className="calendar-event"
                      onClick={() => setDetail(row)}
                    >
                      <span className="event-dot" />
                      {isAllDay(row)
                        ? ''
                        : new Date(row.date).toLocaleTimeString(undefined, {
                            hour: 'numeric',
                            minute: '2-digit',
                          }) + ' '}
                      {row.name || 'Untitled event'}
                    </button>
                  ))}
                  {events.length > 3 && (
                    <button
                      className="calendar-more"
                      onClick={() => {
                        setMode('agenda');
                      }}
                    >
                      +{events.length - 3} more · agenda
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      ) : !rows.length ? (
        <div className="panel">
          <Empty
            icon={CalendarDays}
            title="No events this month"
            description="Choose another month or adjust the search."
          />
        </div>
      ) : (
        <div className="panel agenda-list">
          {rows.map((row) => (
            <button key={row.id} className="agenda-event" onClick={() => setDetail(row)}>
              <time>{isAllDay(row) ? String(row.date).slice(0, 10) : date(row.date)}</time>
              <div>
                <b>{row.name || 'Untitled event'}</b>
                <small>
                  {isAllDay(row) ? 'All day' : row.end ? `Until ${date(row.end)}` : ''}
                  {row.location ? ' · ' + row.location : ''}
                </small>
              </div>
            </button>
          ))}
        </div>
      )}
      {mode === 'agenda' && !loading && !error && !availability && total > 0 && (
        <Pager offset={offset} total={total} limit={200} onChange={setOffset} />
      )}
      {detail && (
        <Modal title={detail.name || 'Event'} onClose={() => setDetail(null)}>
          <div className="detail-content">
            <p>{eventRange(detail)}</p>
            {detail.location && <p>{detail.location}</p>}
            <div className="note-body">
              {detail.body || detail.detail || 'No additional details.'}
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
