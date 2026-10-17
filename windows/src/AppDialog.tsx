import type { Dispatch, SetStateAction } from 'react';
import {
  ArrowUpRight,
  Folder,
  Info,
  LockKeyhole,
  RefreshCw,
  ShieldCheck,
  Trash2,
} from 'lucide-react';
import { api, type Row } from './api';
import { useApp, type DialogKind, type DialogState } from './appModel';
import { Button, Modal, date } from './ui';
import WifiSection from './views/WifiSection';

const titles: Partial<Record<DialogKind, string>> = {
  backup: 'Create device backup',
  encryption: 'Backup encryption',
  connect: 'Connect your iPhone',
  unlock: 'Unlock backup',
  restore: 'Restore this snapshot?',
  clone: 'Clone to another device',
  schedule: 'Backup schedule',
  renameBackup: 'Rename backup',
  deleteBackup: 'Move backup to Recycle Bin?',
  about: 'About Phosphor for Windows',
};
const submitLabels: Partial<Record<DialogKind, string>> = {
  backup: 'Create backup',
  encryption: 'Update encryption',
  unlock: 'Unlock backup',
  restore: 'Restore device',
  clone: 'Start clone',
  schedule: 'Save schedule',
  renameBackup: 'Save name',
  deleteBackup: 'Move to Recycle Bin',
  confirm: 'Confirm',
};
const destructive = new Set<DialogKind>(['restore', 'clone', 'confirm', 'deleteBackup']);
const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const timeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;

interface Props {
  dialog: DialogState;
  form: Row;
  setForm: Dispatch<SetStateAction<Row>>;
  scanning: boolean;
  scanError: string;
  onClose: () => void;
  onSubmit: () => void;
}

export default function AppDialog({
  dialog,
  form,
  setForm,
  scanning,
  scanError,
  onClose,
  onSubmit,
}: Props) {
  const { busy, refresh } = useApp();
  const informational = dialog.kind === 'connect' || dialog.kind === 'about';
  return (
    <Modal title={dialog.title || titles[dialog.kind] || 'Phosphor'} onClose={onClose}>
      <form
        aria-busy={busy}
        onSubmit={(e) => {
          e.preventDefault();
          if (!busy) onSubmit();
        }}
      >
        {dialog.kind === 'connect' ? (
          <>
            <ConnectionGuide />
            {scanError && <div className="notice error">{scanError}</div>}
            <div className="dialog-actions">
              <Button
                icon={RefreshCw}
                variant="primary"
                onClick={() => refresh(true)}
                disabled={scanning}
              >
                {scanning ? 'Checking…' : 'Check connection'}
              </Button>
            </div>
          </>
        ) : dialog.kind === 'about' ? (
          <>
            <AboutEdition />
            <div className="dialog-actions">
              <Button variant="primary" onClick={onClose}>
                Close
              </Button>
            </div>
          </>
        ) : null}
        {!informational && (
          <>
            <DialogFields dialog={dialog} form={form} setForm={setForm} />
            <div className="dialog-actions">
              <Button onClick={onClose} disabled={busy}>
                Cancel
              </Button>
              <Button
                type="submit"
                variant={destructive.has(dialog.kind) ? 'danger' : 'primary'}
                disabled={busy}
                loading={busy}
                icon={dialog.kind === 'unlock' ? LockKeyhole : undefined}
              >
                {busy
                  ? dialog.kind === 'unlock'
                    ? 'Unlocking backup…'
                    : 'Working…'
                  : submitLabels[dialog.kind] || 'Continue'}
              </Button>
            </div>
          </>
        )}
      </form>
    </Modal>
  );
}

function ConnectionGuide() {
  return (
    <>
      <p className="dialog-intro">
        Your device connects directly to this PC. Start with these three steps.
      </p>
      <ol className="guide-list">
        <li>
          <span>01</span>
          <div>
            <b>Install Apple Devices</b>
            <p>Apple’s Windows app provides the USB driver and Mobile Device Service.</p>
            <Button
              icon={ArrowUpRight}
              onClick={() => api.external('https://apps.microsoft.com/detail/9np83lwlpz9k')}
            >
              Open Microsoft Store
            </Button>
          </div>
        </li>
        <li>
          <span>02</span>
          <div>
            <b>Connect with a USB data cable</b>
            <p>Unlock your iPhone or iPad and keep it connected.</p>
          </div>
        </li>
        <li>
          <span>03</span>
          <div>
            <b>Tap “Trust This Computer”</b>
            <p>Enter your device passcode. It should appear in Phosphor within a few seconds.</p>
          </div>
        </li>
      </ol>
      <WifiSection />
    </>
  );
}

function AboutEdition() {
  return (
    <>
      <p className="dialog-intro">
        Phosphor for Windows 10 and 11, with a bundled Python device engine and Electron interface.
      </p>
      <div className="notice">
        <ShieldCheck size={19} /> Backup passwords and decrypted keys stay in memory. Close Phosphor
        to end the session.
      </div>
      <p className="dialog-intro">
        Device features depend on Apple’s drivers, device trust, and iOS services. The Windows
        edition includes backup browsing and exports, device backup and restore, app management, AFC
        transfers, and diagnostics.
      </p>
      <p className="dialog-intro">
        English interface. Notes show available plain text. Health and Watch data can be extracted
        as original files. Developer screenshots depend on iOS developer services.
      </p>
    </>
  );
}

function PasswordField({
  label,
  value,
  onChange,
  required = true,
  disabled,
}: {
  label: string;
  value?: string;
  onChange: (value: string) => void;
  required?: boolean;
  disabled?: boolean;
}) {
  return (
    <label className="form-label">
      {label}
      <input
        required={required}
        disabled={disabled}
        type="password"
        autoComplete="off"
        value={value || ''}
        onChange={(e) => onChange(e.target.value)}
      />
    </label>
  );
}

function DialogFields({
  dialog,
  form,
  setForm,
}: {
  dialog: DialogState;
  form: Row;
  setForm: Dispatch<SetStateAction<Row>>;
}) {
  const { status, device, devices, deviceId, busy } = useApp();
  const set = (key: string) => (value: unknown) => setForm({ ...form, [key]: value });
  switch (dialog.kind) {
    case 'backup':
      return (
        <>
          <p className="dialog-intro">
            A local snapshot of <b>{device?.name}</b>. Phosphor uses your device’s current backup
            encryption setting. Your iPhone may ask for its device passcode to authorize the backup;
            enter it on the iPhone.
          </p>
          {[
            ['full', 'Full backup', 'Start fresh. Save a complete, independent snapshot.'],
            [
              'incremental',
              'Incremental snapshot',
              'Copy the last snapshot, then update it. Requires space for a second copy.',
            ],
          ].map(([value, title, detail]) => (
            <label key={value} className={'radio-card ' + (form.full === value ? 'active' : '')}>
              <input
                type="radio"
                name="full"
                checked={form.full === value}
                onChange={() => set('full')(value)}
              />
              <div>
                <b>{title}</b>
                <small>{detail}</small>
              </div>
            </label>
          ))}
          <div className="notice">
            <Folder size={17} />
            <span className="break-word">{status.backupRoot}</span>
          </div>
        </>
      );
    case 'encryption':
      return (
        <>
          <p className="dialog-intro">
            Update the backup encryption setting on <b>{device?.name}</b>. Existing snapshots keep
            their original password. Store your password somewhere safe; Apple cannot recover it.
          </p>
          <label className="form-label">
            Operation
            <select value={form.mode} onChange={(e) => setForm({ mode: e.target.value })}>
              <option value="on">Enable encrypted backups</option>
              <option value="off">Disable encrypted backups</option>
              <option value="change">Change the backup password</option>
            </select>
          </label>
          <PasswordField
            label={form.mode === 'on' ? 'New backup password' : 'Current backup password'}
            value={form.password}
            onChange={set('password')}
          />
          {form.mode === 'change' && (
            <PasswordField
              label="New backup password"
              value={form.newPassword}
              onChange={set('newPassword')}
            />
          )}
          {form.mode !== 'off' && (
            <PasswordField
              label="Repeat the new password"
              value={form.repeatPassword}
              onChange={set('repeatPassword')}
            />
          )}
        </>
      );
    case 'unlock':
      return (
        <>
          <p className="dialog-intro">
            Enter the password used when this backup was created. It will not be saved to disk.
          </p>
          <PasswordField
            label="Backup password"
            value={form.password}
            onChange={set('password')}
            disabled={busy}
          />
        </>
      );
    case 'restore':
      return (
        <>
          <div className="notice caution">
            <Info size={19} />
            <span>
              This replaces device data and settings with the selected backup. Your device may
              restart.
            </span>
          </div>
          <p className="dialog-intro">
            Snapshot from <b>{dialog.data?.name}</b> → <b>{device?.name}</b>. iOS may reject a
            backup from a newer iOS version. Disable Find My on the destination if iOS requires it.
          </p>
          {dialog.data?.encrypted && (
            <PasswordField
              label="Backup password"
              value={form.password}
              onChange={set('password')}
            />
          )}
          <label className="check-label">
            <input
              required
              type="checkbox"
              checked={!!form.accepted}
              onChange={(e) => set('accepted')(e.target.checked)}
            />{' '}
            I have preserved any current data I need.
          </label>
        </>
      );
    case 'clone':
      return (
        <>
          <p className="dialog-intro">
            Phosphor saves a full backup of <b>{device?.name}</b>, then restores it to the
            destination.
          </p>
          <label className="form-label">
            Destination device
            <select
              required
              value={form.target || ''}
              onChange={(e) => set('target')(e.target.value)}
            >
              <option value="">Choose a different device</option>
              {devices
                .filter((d) => d.id !== deviceId && d.paired)
                .map((d) => (
                  <option value={d.id} key={d.id}>
                    {d.name} · {d.model}
                  </option>
                ))}
            </select>
          </label>
          <PasswordField
            label="Backup password, if encrypted"
            value={form.password}
            onChange={set('password')}
            required={false}
          />
          <div className="notice caution">
            <Info size={19} /> The destination’s data and settings will be replaced.
          </div>
          <label className="check-label">
            <input
              required
              type="checkbox"
              checked={!!form.accepted}
              onChange={(e) => set('accepted')(e.target.checked)}
            />{' '}
            I have backed up the destination device.
          </label>
        </>
      );
    case 'schedule':
      return (
        <>
          <p className="dialog-intro">
            Back up <b>{dialog.data?.name || device?.name}</b> when it is paired and available over
            USB or Wi-Fi. Each run creates an independent incremental snapshot.
          </p>
          <label className="form-label">
            Frequency
            <select value={form.frequency} onChange={(e) => set('frequency')(e.target.value)}>
              <option value="daily">Every day</option>
              <option value="weekly">Every week</option>
              <option value="interval">Every X hours</option>
              <option value="monthly">Every 30 days</option>
            </select>
          </label>
          {form.frequency === 'interval' && (
            <label className="form-label">
              Hours between completed backups
              <input
                required
                type="number"
                min={1}
                max={720}
                step={1}
                value={form.hours}
                onChange={(e) => set('hours')(e.target.value)}
              />
            </label>
          )}
          {form.frequency === 'weekly' && (
            <label className="form-label">
              Day
              <select value={form.weekday} onChange={(e) => set('weekday')(e.target.value)}>
                {weekdays.map((day, i) => (
                  <option key={day} value={i}>
                    {day}
                  </option>
                ))}
              </select>
            </label>
          )}
          {['interval', 'monthly'].includes(form.frequency) && (
            <label className="form-label">
              First run date and time
              <input
                required
                type="datetime-local"
                value={form.firstAt || ''}
                onChange={(e) => set('firstAt')(e.target.value)}
              />
              <small>{timeZone()} · Later runs occur after the selected interval.</small>
            </label>
          )}
          {['daily', 'weekly'].includes(form.frequency) && (
            <label className="form-label">
              Time
              <input
                required
                type="time"
                value={form.atTime}
                onChange={(e) => set('atTime')(e.target.value)}
              />
              <small>{timeZone()}</small>
            </label>
          )}
          <label className="check-label">
            <input
              type="checkbox"
              checked={!!form.enabled}
              onChange={(e) => set('enabled')(e.target.checked)}
            />{' '}
            Schedule enabled
          </label>
          <div className="notice">
            <Info size={18} />
            <span>
              Missed runs wait for your device to reconnect. Keep Phosphor running in the system
              tray. iOS may require its passcode on the iPhone before each backup can proceed.
            </span>
          </div>
        </>
      );
    case 'renameBackup':
      return (
        <>
          <p className="dialog-intro">
            Give this snapshot a name you can recognize. The device backup files keep their original
            names.
          </p>
          <label className="form-label">
            Backup name
            <input
              required
              maxLength={120}
              value={form.name || ''}
              onChange={(e) => set('name')(e.target.value)}
            />
          </label>
        </>
      );
    case 'deleteBackup':
      return (
        <>
          <p className="dialog-intro">
            <b>{dialog.data?.name}</b>, created {date(dialog.data?.date)}, will be moved to the
            Windows Recycle Bin. You can restore it from there until the bin is emptied.
          </p>
          <div className="notice caution">
            <Trash2 size={18} />
            <span className="break-word">{dialog.data?.path}</span>
          </div>
        </>
      );
    case 'confirm':
      return <p className="dialog-intro">{dialog.description}</p>;
    default:
      return null;
  }
}
