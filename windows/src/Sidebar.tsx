import { Settings2, Smartphone } from 'lucide-react';
import appIcon from '../assets/icon.png';
import { useApp } from './appModel';
import { navGroups, navigation, type Page } from './navigation';

/** Device picker and grouped section navigation, laid out like the macOS SidebarView. */
export default function Sidebar({ page }: { page: Page }) {
  const { status, devices, device, deviceId, backups, navigate, openDialog, selectDevice } =
    useApp();
  return (
    <aside className="sidebar">
      <div className="brand">
        <img className="brand-mark" src={appIcon} alt="" />
        <b>Phosphor</b>
        <small>Windows</small>
      </div>
      <button className="device-picker" onClick={() => openDialog('connect')}>
        <Smartphone size={21} />
        <div>
          <b>{device?.name || 'Connect a device'}</b>
          <span>
            {device
              ? device.connection === 'Network'
                ? 'Wi-Fi connected'
                : 'USB connected'
              : 'Connection guide'}
          </span>
        </div>
      </button>
      {devices.length > 1 && (
        <select
          className="sidebar-select"
          aria-label="Selected device"
          value={deviceId}
          onChange={(e) => selectDevice(e.target.value)}
        >
          {devices.map((d) => (
            <option value={d.id} key={d.id}>
              {d.name}
            </option>
          ))}
        </select>
      )}
      <nav aria-label="Main navigation">
        {navGroups.map((group) => (
          <div className="nav-group" key={group}>
            <span className="nav-group-label">{group}</span>
            {navigation
              .filter((item) => item.group === group)
              .map((item) => (
                <button
                  className={'nav-item tint-' + item.tint + (page === item.page ? ' active' : '')}
                  key={item.page}
                  aria-current={page === item.page ? 'page' : undefined}
                  onClick={() => navigate(item.page)}
                >
                  <item.icon size={17} />
                  <span>{item.label}</span>
                  {item.page === 'backups' && backups.length > 0 && (
                    <span className="nav-count">{backups.length}</span>
                  )}
                </button>
              ))}
          </div>
        ))}
      </nav>
      <div className="sidebar-bottom">
        <button
          className={'nav-item ' + (page === 'settings' ? 'active' : '')}
          aria-current={page === 'settings' ? 'page' : undefined}
          onClick={() => navigate('settings')}
        >
          <Settings2 size={17} />
          <span>Settings</span>
        </button>
        <div className="sidebar-version">
          <span>Local engine</span>
          <span>{status.version ? 'v' + status.version : 'Preview'}</span>
        </div>
      </div>
    </aside>
  );
}
