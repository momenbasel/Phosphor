import {
  ArrowRight,
  CalendarDays,
  Clock3,
  Database,
  File,
  FolderOpen,
  Image,
  Info,
  MessageCircle,
  Plus,
  Smartphone,
  Wifi,
} from 'lucide-react';
import { useApp } from '../appModel';
import { scheduleLabel } from '../BackupSchedules';
import type { Page } from '../navigation';
import { Badge, Button, Empty, date } from '../ui';

const shortcuts: { page: Page; title: string; icon: typeof Image }[] = [
  { page: 'photos', title: 'Photos & videos', icon: Image },
  { page: 'messages', title: 'Messages', icon: MessageCircle },
  { page: 'notes', title: 'Notes', icon: File },
  { page: 'calendar', title: 'Calendar', icon: CalendarDays },
];

export default function DevicesView() {
  const {
    status,
    device,
    backups,
    backup,
    openDialog,
    navigate,
    selectBackup,
    chooseBackupFolder,
  } = useApp();
  const recent = backups[0];
  const nextSchedule = [...((status.schedules as typeof backups) || [])]
    .filter((s) => s.enabled)
    .sort((a, b) => a.next - b.next)[0];
  return (
    <>
      <section className="panel device-summary">
        <div className="device-summary-icon">
          <Smartphone size={40} strokeWidth={1.3} />
        </div>
        <div className="device-summary-copy">
          <h2>{device?.name || 'Connect your iPhone'}</h2>
          <p>
            {device
              ? `${device.model || 'iPhone'} · iOS ${device.ios || '—'}`
              : 'Connect with a USB data cable and trust this PC to start.'}
          </p>
          <Badge good={!!device?.paired}>
            {device
              ? device.connection === 'Network'
                ? 'Connected over Wi-Fi'
                : 'Connected over USB'
              : 'No device connected'}
          </Badge>
        </div>
        <div className="inline-actions">
          <Button icon={Wifi} onClick={() => openDialog('connect')}>
            Connection
          </Button>
          <Button
            variant="primary"
            icon={Database}
            disabled={!device?.paired}
            onClick={() => openDialog('backup')}
          >
            Create backup
          </Button>
        </div>
      </section>
      <div className="overview-grid">
        <section className="panel overview-card">
          <div className="section-heading">
            <h3>Latest snapshot</h3>
            <Button icon={ArrowRight} onClick={() => navigate('backups')}>
              All backups
            </Button>
          </div>
          {recent ? (
            <>
              <h2 className="overview-value">{recent.name}</h2>
              <p>{date(recent.date)}</p>
              <div className="inline-actions">
                <Badge good={recent.complete}>{recent.complete ? 'Complete' : 'Incomplete'}</Badge>
                <span className="muted">
                  {recent.encrypted ? 'Encrypted' : 'Unencrypted'} ·{' '}
                  {backups.filter((b) => b.complete).length} complete snapshots
                </span>
              </div>
              <Button icon={FolderOpen} onClick={() => selectBackup(recent.id, 'photos')}>
                Browse library
              </Button>
            </>
          ) : (
            <Empty
              icon={Database}
              title="No local backups"
              description="Open a backup from Apple Devices or create one here."
              action={
                <Button icon={FolderOpen} onClick={chooseBackupFolder}>
                  Open backup folder
                </Button>
              }
            />
          )}
        </section>
        <section className="panel overview-card">
          <div className="section-heading">
            <h3>Next scheduled backup</h3>
            <Button icon={Clock3} onClick={() => navigate('backups')}>
              Manage
            </Button>
          </div>
          {nextSchedule ? (
            <>
              <h2 className="overview-value">{scheduleLabel(nextSchedule)}</h2>
              <p>{nextSchedule.name}</p>
              <p className="muted">{new Date(nextSchedule.next * 1000).toLocaleString()}</p>
              <p>
                {nextSchedule.next < Date.now() / 1000
                  ? 'Due · waits for the device to be available'
                  : 'Runs when the device is available.'}
              </p>
            </>
          ) : (
            <>
              <h2 className="overview-value">No active schedule</h2>
              <p>Choose daily, weekly, or an interval in hours.</p>
              <Button icon={Plus} disabled={!device?.paired} onClick={() => openDialog('schedule')}>
                Set a schedule
              </Button>
            </>
          )}
        </section>
      </div>
      <section className="panel library-shortcuts">
        <div className="section-heading">
          <h3>Backup library</h3>
          <span className="muted">{backup?.name || 'Choose a snapshot to browse'}</span>
        </div>
        <div className="quick-grid">
          {shortcuts.map((item) => (
            <button key={item.page} className="quick-card" onClick={() => navigate(item.page)}>
              <item.icon size={24} />
              <b>{item.title}</b>
              <ArrowRight size={16} />
            </button>
          ))}
        </div>
      </section>
      {!status.driver && (
        <div className="notice caution">
          <Info size={18} />
          <span>Install Apple Devices to provide the Apple device service.</span>
          <Button onClick={() => openDialog('connect')}>Setup guide</Button>
        </div>
      )}
    </>
  );
}
