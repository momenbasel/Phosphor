import { ShieldCheck, Smartphone, Usb } from 'lucide-react';
import { api } from '../api';
import { useApp } from '../appModel';
import { Button, Empty } from '../ui';

/** Shown by live-device pages until a trusted device is connected. */
export default function PairPrompt() {
  const { device, deviceId, perform, refresh, openDialog } = useApp();
  return (
    <div className="panel">
      <Empty
        icon={Smartphone}
        title={device ? 'Trust this computer' : 'Connect a device'}
        description={
          device
            ? 'Unlock your device and tap Trust This Computer to continue.'
            : 'Connect your iPhone or iPad using a USB data cable. Your device will appear automatically.'
        }
        action={
          <Button
            icon={device ? ShieldCheck : Usb}
            variant="primary"
            onClick={() =>
              device
                ? perform(async () => {
                    await api.call('pair', { udid: deviceId });
                    await refresh(true);
                  })
                : openDialog('connect')
            }
          >
            {device ? 'Pair device' : 'Connection guide'}
          </Button>
        }
      />
    </div>
  );
}
