import { useState } from 'react';
import { FolderOpen, Upload } from 'lucide-react';
import { api } from './api';
import { Button, Modal, errorMessage } from './ui';
export default function IpaInstall({
  deviceId,
  notify,
}: {
  deviceId: string;
  notify: (message: string, error?: boolean) => void;
}) {
  const [open, setOpen] = useState(false),
    [ipa, setIpa] = useState(''),
    [busy, setBusy] = useState(false),
    [error, setError] = useState('');
  const choose = async () => {
    try {
      const path = await api.choose('file', {
        title: 'Choose an IPA',
        filters: [{ name: 'iOS application', extensions: ['ipa'] }],
      });
      if (path) setIpa(path);
    } catch (error) {
      setError(errorMessage(error));
    }
  };
  const install = async () => {
    setBusy(true);
    setError('');
    try {
      await api.call('installApp', { udid: deviceId, path: ipa });
      notify('Signed IPA installation added to Activity');
      setOpen(false);
      setIpa('');
    } catch (error) {
      setError(errorMessage(error));
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <Button icon={Upload} variant="primary" onClick={() => setOpen(true)}>
        Install IPA
      </Button>
      {open && (
        <Modal
          title="Install an iPhone application"
          onClose={() => {
            if (!busy) setOpen(false);
          }}
        >
          <p className="dialog-intro">
            The IPA must already have a valid signature and provisioning for this device.
          </p>
          <div className="ipa-selection">
            <span>{ipa ? ipa.split(/[\\/]/).at(-1) : 'Choose an IPA file'}</span>
            <Button icon={FolderOpen} disabled={busy} onClick={choose}>
              Choose file
            </Button>
          </div>
          {error && <p className="notice error">{error}</p>}
          <div className="dialog-actions">
            <Button disabled={busy} onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button variant="primary" loading={busy} disabled={!ipa || !deviceId} onClick={install}>
              Install signed IPA
            </Button>
          </div>
        </Modal>
      )}
    </>
  );
}
