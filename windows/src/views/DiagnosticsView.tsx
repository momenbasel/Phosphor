import { useEffect, useState } from 'react';
import { Copy, Info, Moon, RefreshCw } from 'lucide-react';
import { api, type Row } from '../api';
import { useApp } from '../appModel';
import BatteryPanel from '../BatteryPanel';
import ConsolePanel from '../ConsolePanel';
import ScreenshotPanel from '../ScreenshotPanel';
import StoragePanel from '../StoragePanel';
import { Badge, Button, Empty, Loading, errorMessage } from '../ui';

const identityLabels: Record<string, string> = {
  DeviceName: 'Device name',
  ProductType: 'Model identifier',
  ProductVersion: 'iOS version',
  SerialNumber: 'Serial number',
  UniqueDeviceID: 'Device identifier',
  InternationalMobileEquipmentIdentity: 'IMEI',
  WiFiAddress: 'Wi-Fi address',
  BluetoothAddress: 'Bluetooth address',
};

export default function DiagnosticsView() {
  const {
    device,
    devices,
    deviceId,
    jobs,
    busy,
    revision,
    notify,
    perform,
    confirm,
    openDialog,
    reload,
  } = useApp();
  const [readings, setReadings] = useState<Row>({});
  const [identity, setIdentity] = useState<Row>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError('');
    Promise.all([
      api.call('diagnostics', { udid: deviceId }),
      api.call('deviceInfo', { udid: deviceId }),
    ])
      .then(([diagnostics, info]) => {
        if (!alive) return;
        setReadings(diagnostics);
        setIdentity(info);
      })
      .catch((reason) => {
        if (alive) setError(errorMessage(reason));
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [deviceId, revision]);

  if (loading) return <Loading label="Reading device diagnostics…" />;
  const consolePanel = <ConsolePanel deviceId={deviceId} jobs={jobs} notify={notify} />;
  if (error)
    return (
      <>
        <section className="panel">
          <Empty
            icon={Info}
            title="Device diagnostics couldn’t be opened"
            description={error}
            action={
              <Button icon={RefreshCw} onClick={reload}>
                Try again
              </Button>
            }
          />
        </section>
        {consolePanel}
      </>
    );
  const name = device?.name || 'device';
  return (
    <>
      <div className="toolbar">
        <Badge good>{name}</Badge>
        <span className="toolbar-count">Live device information</span>
        <Button
          icon={Copy}
          disabled={busy}
          onClick={() =>
            perform(async () => {
              await navigator.clipboard.writeText(
                JSON.stringify({ device: identity, diagnostics: readings }, null, 2),
              );
            }, 'Device details copied')
          }
        >
          Copy details
        </Button>
        <Button icon={RefreshCw} onClick={reload}>
          Refresh readings
        </Button>
      </div>
      <div className="diagnostic-grid">
        <BatteryPanel reading={readings.battery || {}} />
        <StoragePanel reading={readings.storage || {}} />
      </div>
      <section className="panel device-details">
        <div className="section-heading">
          <h3>Device identity</h3>
          <span className="muted">iOS {device?.ios}</span>
        </div>
        <dl>
          {Object.keys(identityLabels)
            .filter((key) => identity[key] != null)
            .map((key) => (
              <div key={key}>
                <dt>{identityLabels[key]}</dt>
                <dd>{String(identity[key])}</dd>
              </div>
            ))}
        </dl>
        <div className="inline-actions">
          <Button
            icon={RefreshCw}
            disabled={busy}
            onClick={() =>
              confirm(
                'Restart ' + name + '?',
                'Your device will disconnect briefly while it restarts.',
                () => api.call('deviceAction', { udid: deviceId, action: 'restart' }),
              )
            }
          >
            Restart
          </Button>
          <Button
            icon={Moon}
            disabled={busy}
            onClick={() =>
              perform(() => api.call('deviceAction', { udid: deviceId, action: 'sleep' }))
            }
          >
            Sleep
          </Button>
          <Button
            icon={Copy}
            disabled={devices.filter((value) => value.paired).length < 2 || busy}
            onClick={() => openDialog('clone')}
          >
            Clone device
          </Button>
        </div>
      </section>
      <ScreenshotPanel
        deviceId={deviceId}
        busy={busy || jobs.some((job) => job.status === 'running')}
        notify={notify}
        revision={revision}
      />
      {consolePanel}
    </>
  );
}
