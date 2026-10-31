const { contextBridge, ipcRenderer, webUtils } = require('electron');
contextBridge.exposeInMainWorld('phosphor', {
  call: (method, params = {}) => ipcRenderer.invoke('engine:call', method, params),
  choose: (kind, options = {}) => ipcRenderer.invoke('dialog:choose', kind, options),
  reveal: (path) => ipcRenderer.invoke('shell:reveal', path),
  external: (url) => ipcRenderer.invoke('shell:external', url),
  window: (action) => ipcRenderer.send('window:action', action),
  droppedPath: (file) => webUtils.getPathForFile(file),
  onEvent: (callback) => {
    const listener = (_, event) => callback(event);
    ipcRenderer.on('engine:event', listener);
    return () => ipcRenderer.removeListener('engine:event', listener);
  },
});
