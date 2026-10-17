import { api } from '../api';
import { useApp } from '../appModel';
import WifiConnection from '../WifiConnection';

/** Wi-Fi address entry and saved routes, shown in Settings and the connection guide. */
export default function WifiSection() {
  const { status, busy, perform, refresh, notify, selectDevice } = useApp();
  return (
    <WifiConnection
      saved={status.wifiDevices || []}
      busy={busy}
      onConnect={(address) =>
        perform(async () => {
          const row = await api.call('connectWifi', { address });
          selectDevice(row.id);
          await refresh(true);
          notify(row.serviceWarning || `${row.name} connected over Wi-Fi.`, !!row.serviceWarning);
        })
      }
      onForget={(udid) =>
        perform(async () => {
          await api.call('forgetWifi', { udid });
          await refresh(true);
        })
      }
    />
  );
}
