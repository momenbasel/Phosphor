import { Clock3, Pause, Pencil, Play, Plus, Trash2 } from 'lucide-react';
import type { Row } from './api';

const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
export function scheduleLabel(schedule: Row) {
  const frequency = schedule.frequency;
  const cadence =
    frequency === 'interval'
      ? `Every ${schedule.hours} ${schedule.hours === 1 ? 'hour' : 'hours'}`
      : frequency === 'hourly'
        ? 'Every hour'
        : frequency === 'daily'
          ? 'Every day'
          : frequency === 'weekly'
            ? `Every ${schedule.atTime ? days[schedule.weekday ?? 0] : 'week'}`
            : 'Every 30 days';
  if (!schedule.atTime || !['daily', 'weekly'].includes(frequency)) return cadence;
  const [hours, minutes] = schedule.atTime.split(':').map(Number);
  const display = new Date(2000, 0, 1, hours, minutes).toLocaleTimeString(undefined, {
    hour: 'numeric',
    minute: '2-digit',
  });
  return `${cadence} at ${display}`;
}
function nextDate(value: number) {
  return new Date(value * 1000).toLocaleString(undefined, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
}

export default function BackupSchedules({
  schedules,
  devices,
  jobs,
  canAdd,
  busy,
  onAdd,
  onEdit,
  onToggle,
  onRemove,
}: {
  schedules: Row[];
  devices: Row[];
  jobs: Row[];
  canAdd: boolean;
  busy: boolean;
  onAdd: () => void;
  onEdit: (schedule: Row) => void;
  onToggle: (schedule: Row) => void;
  onRemove: (schedule: Row) => void;
}) {
  return (
    <section className="panel backup-schedules">
      <div className="section-heading">
        <div>
          <span className="eyebrow">AUTOMATIC BACKUPS</span>
          <h3>{schedules.length ? 'Your backup schedules' : 'Choose when to back up'}</h3>
        </div>
        <button className="button secondary" disabled={!canAdd || busy} onClick={onAdd}>
          <Plus size={16} /> {schedules.length ? 'Add or edit' : 'Set a schedule'}
        </button>
      </div>
      {schedules.length ? (
        schedules.map((s) => {
          const job = jobs.find((j) => j.id === s.jobId && j.status === 'running');
          const connected = devices.some((d) => d.id === s.udid && d.paired);
          const due = s.next <= Date.now() / 1000;
          const detail = job
            ? job.detail
            : !s.enabled
              ? 'Paused'
              : s.lastError
                ? `${s.lastError} · Will retry when available`
                : due && !connected
                  ? 'Due · Waiting for this device to connect'
                  : due
                    ? 'Due · Waiting for the device to be available'
                    : `Next: ${nextDate(s.next)}${connected ? '' : ' · Runs when this device reconnects'}`;
          return (
            <article className="schedule-item" key={s.id}>
              <span className="schedule-icon">
                <Clock3 size={20} />
              </span>
              <div className="schedule-copy">
                <b>{s.name}</b>
                <span>{scheduleLabel(s)}</span>
                <small role="status">{detail}</small>
                {s.lastCompleted && <small>Last completed: {nextDate(s.lastCompleted)}</small>}
              </div>
              <div className="schedule-actions">
                <button
                  className="button secondary"
                  disabled={busy || !!job}
                  onClick={() => onEdit(s)}
                >
                  <Pencil size={15} /> Edit
                </button>
                <button
                  className="icon-button"
                  disabled={busy}
                  aria-label={s.enabled ? 'Pause backup schedule' : 'Resume backup schedule'}
                  title={s.enabled ? 'Pause' : 'Resume'}
                  onClick={() => onToggle(s)}
                >
                  {s.enabled ? <Pause size={17} /> : <Play size={17} />}
                </button>
                <button
                  className="icon-button danger-text"
                  disabled={busy}
                  aria-label={'Remove schedule for ' + s.name}
                  title="Remove schedule"
                  onClick={() => onRemove(s)}
                >
                  <Trash2 size={17} />
                </button>
              </div>
            </article>
          );
        })
      ) : (
        <p className="setting-note">
          Back up daily, weekly, or every number of hours you choose. Missed runs wait until your
          device is connected and available.
        </p>
      )}
      <p className="schedule-note">
        Keep Phosphor running in the system tray. Your iPhone may ask you to enter its passcode
        before a scheduled backup can continue.
      </p>
    </section>
  );
}
