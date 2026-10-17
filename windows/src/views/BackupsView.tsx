import { useState } from 'react';
import {
  CalendarDays,
  ChartNoAxesCombined,
  Database,
  FileArchive,
  Folder,
  FolderOpen,
  HardDrive,
  LockKeyhole,
  Pencil,
  Plus,
  RefreshCw,
  Smartphone,
  Trash2,
} from 'lucide-react';
import { api, type Row } from '../api';
import { useApp } from '../appModel';
import BackupStorage from '../BackupStorage';
import { Badge, Button, Empty, Modal, bytes, date } from '../ui';
import ScheduleSection from './ScheduleSection';

const archiveFilter = [{ name: 'Phosphor backup', extensions: ['phosphor'] }];

export default function BackupsView() {
  const {
    device,
    backups,
    backup,
    backupId,
    notify,
    perform,
    openDialog,
    selectBackup,
    setBackupId,
    chooseBackupFolder,
  } = useApp();
  const [storageOpen, setStorageOpen] = useState(false);

  const exportArchive = (b: Row) =>
    perform(async () => {
      const destination = await api.choose('save', {
        title: 'Export portable backup',
        name: b.name + '.phosphor',
        filters: archiveFilter,
      });
      if (destination) await api.call('archive', { backup: b.id, destination });
    });
  const importArchive = () =>
    perform(async () => {
      const path = await api.choose('file', {
        title: 'Import a portable backup',
        filters: archiveFilter,
      });
      if (path) await api.call('importArchive', { path });
    });

  return (
    <>
      <div className="toolbar">
        <div className="toolbar-left">
          <Badge good>{backups.filter((b) => b.complete).length} complete snapshots</Badge>
        </div>
        <Button icon={FolderOpen} onClick={chooseBackupFolder}>
          Open folder
        </Button>
        <Button icon={FileArchive} onClick={importArchive}>
          Import archive
        </Button>
        <Button
          icon={LockKeyhole}
          disabled={!device?.paired}
          onClick={() => openDialog('encryption')}
        >
          Device encryption
        </Button>
        <Button
          variant="primary"
          icon={Plus}
          disabled={!device?.paired}
          onClick={() => openDialog('backup')}
        >
          Create backup
        </Button>
      </div>
      <div className="backup-timeline">
        {backups.length ? (
          backups.map((b, i) => (
            <article className={'backup-card ' + (backupId === b.id ? 'active' : '')} key={b.id}>
              <div className="backup-card-top">
                <div className="backup-card-icon">
                  <Smartphone size={28} />
                </div>
                <div>
                  <span className="eyebrow">{i === 0 ? 'Latest snapshot' : 'Snapshot'}</span>
                  <h3>{b.name}</h3>
                  <p>
                    {b.model || 'iPhone'} · iOS {b.ios || '—'}
                  </p>
                </div>
                <Badge good={b.complete}>{b.complete ? 'Complete' : 'Incomplete'}</Badge>
              </div>
              <div className="backup-card-info">
                <span>
                  <CalendarDays size={15} />
                  {date(b.date)}
                </span>
                <span>
                  <LockKeyhole size={15} />
                  {b.encrypted
                    ? b.unlocked
                      ? 'Encrypted · unlocked'
                      : 'Encrypted'
                    : 'Unencrypted'}
                </span>
                <span>
                  <HardDrive size={15} />
                  {b.size != null
                    ? bytes(b.size) + (b.sizeStatus === 'partial' ? ' · partial measurement' : '')
                    : 'Size not measured'}
                </span>
              </div>
              <div className="backup-card-actions">
                <Button icon={FolderOpen} onClick={() => selectBackup(b.id, 'backupfiles')}>
                  Browse
                </Button>
                <Button
                  icon={ChartNoAxesCombined}
                  onClick={() => {
                    setBackupId(b.id);
                    setStorageOpen(true);
                  }}
                >
                  Storage map
                </Button>
                <Button icon={FileArchive} onClick={() => exportArchive(b)}>
                  Export
                </Button>
                <Button
                  icon={RefreshCw}
                  disabled={!device?.paired || !b.complete}
                  onClick={() =>
                    openDialog('restore', { backup: b.id, name: b.name, encrypted: b.encrypted })
                  }
                >
                  Restore
                </Button>
                <Button icon={Pencil} onClick={() => openDialog('renameBackup', b)}>
                  Rename
                </Button>
                <Button icon={Trash2} onClick={() => openDialog('deleteBackup', b)}>
                  Delete
                </Button>
                <button
                  className="icon-button"
                  aria-label="Show backup folder"
                  onClick={() => perform(() => api.reveal(b.path))}
                >
                  <Folder size={17} />
                </button>
              </div>
              <div className="backup-path" title={b.path}>
                {b.path}
              </div>
            </article>
          ))
        ) : (
          <section className="panel">
            <Empty
              icon={Database}
              title="No backups yet"
              description="Create a backup or open an existing Apple Devices, iTunes, or Phosphor backup."
              action={
                <Button icon={FolderOpen} onClick={chooseBackupFolder}>
                  Open backup folder
                </Button>
              }
            />
          </section>
        )}
      </div>
      {backup && (
        <BackupStorage
          key={backupId}
          backup={backupId}
          unlocked={!backup.encrypted || backup.unlocked}
          notify={notify}
        />
      )}
      <ScheduleSection />
      {storageOpen && backup && (
        <Modal title={'Storage · ' + backup.name} onClose={() => setStorageOpen(false)}>
          <BackupStorage
            backup={backupId}
            unlocked={!backup.encrypted || backup.unlocked}
            notify={notify}
          />
          {backup.encrypted && !backup.unlocked && (
            <Button
              variant="primary"
              icon={LockKeyhole}
              onClick={() => {
                setStorageOpen(false);
                openDialog('unlock', { backup: backupId });
              }}
            >
              Unlock for section sizes
            </Button>
          )}
        </Modal>
      )}
    </>
  );
}
