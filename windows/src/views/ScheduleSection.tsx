import { api } from '../api';
import { useApp } from '../appModel';
import BackupSchedules from '../BackupSchedules';

/** Saved backup schedules, shown on the Backups page and in Settings. */
export default function ScheduleSection() {
  const { status, devices, device, jobs, busy, openDialog, perform, confirm, refresh } = useApp();
  return (
    <BackupSchedules
      schedules={status.schedules || []}
      devices={devices}
      jobs={jobs}
      busy={busy}
      canAdd={!!device?.paired}
      onAdd={() => openDialog('schedule')}
      onEdit={(schedule) => openDialog('schedule', schedule)}
      onToggle={(schedule) =>
        perform(async () => {
          await api.call('toggleSchedule', { id: schedule.id, enabled: !schedule.enabled });
          await refresh();
        })
      }
      onRemove={(schedule) =>
        confirm(
          'Remove this schedule?',
          `Automatic backups for ${schedule.name} will stop. Your existing backups will remain available.`,
          async () => {
            await api.call('deleteSchedule', { id: schedule.id });
            await refresh();
          },
        )
      }
    />
  );
}
