import { lazy, Suspense } from 'react';
import { Database, FolderOpen, LockKeyhole } from 'lucide-react';
import { useApp } from '../appModel';
import BackupStorage from '../BackupStorage';
import type { Page } from '../navigation';
import { Button, Empty, Loading } from '../ui';

const Gallery = lazy(() => import('../Gallery'));
const FileBrowser = lazy(() => import('../FileBrowser'));
const LibraryView = lazy(() => import('../LibraryView'));
const CalendarView = lazy(() => import('../CalendarView'));

/** Data sections that read from the selected local backup. */
export default function LibraryPage({ page }: { page: Page }) {
  const { backup, backupId, deviceId, revision, notify, openDialog, chooseBackupFolder } = useApp();
  if (!backup)
    return (
      <section className="panel">
        <Empty
          icon={Database}
          title="Choose a local backup"
          description="Open an existing backup or create one from your connected device."
          action={
            <Button icon={FolderOpen} onClick={chooseBackupFolder}>
              Open backup folder
            </Button>
          }
        />
      </section>
    );
  if (backup.encrypted && !backup.unlocked)
    return (
      <section className="panel">
        <Empty
          icon={LockKeyhole}
          title="Unlock this backup"
          description="Enter the password used to create this snapshot. Unlocked keys stay in memory."
          action={
            <Button
              variant="primary"
              icon={LockKeyhole}
              onClick={() => openDialog('unlock', { backup: backup.id })}
            >
              Unlock backup
            </Button>
          }
        />
      </section>
    );
  return (
    <>
      <BackupStorage
        compact
        key={backupId + page}
        backup={backupId}
        unlocked={true}
        kind={page}
        notify={notify}
      />
      <Suspense fallback={<Loading label="Opening library…" />}>
        {page === 'photos' ? (
          <Gallery backup={backupId} onNotify={notify} />
        ) : page === 'calendar' ? (
          <CalendarView backup={backupId} revision={revision} onNotify={notify} />
        ) : page === 'backupfiles' ? (
          <FileBrowser
            deviceId={deviceId}
            backupId={backupId}
            backupUnlocked={true}
            initialSource="backup"
            notify={notify}
            revision={revision}
          />
        ) : (
          <LibraryView
            key={page + backupId}
            backup={backupId}
            kind={page}
            revision={revision}
            onNotify={notify}
          />
        )}
      </Suspense>
    </>
  );
}
