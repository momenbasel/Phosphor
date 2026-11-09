const {
  app,
  BrowserWindow,
  ipcMain,
  dialog,
  shell,
  Menu,
  Tray,
  nativeImage,
  powerSaveBlocker,
  protocol,
  net,
} = require('electron');
const { mediaHandler } = require('./preview-protocol.cjs');
protocol.registerSchemesAsPrivileged([
  {
    scheme: 'phosphor-media',
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      corsEnabled: true,
      stream: true,
    },
  },
]);
const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const readline = require('node:readline');
const os = require('node:os');
let win,
  engine,
  tray,
  quit = false,
  sequence = 0,
  blocker;
const pending = new Map();
const trustedPaths = new Set();
let lastStatus = {};
const root = path.resolve(__dirname, '..');
const selfTest = process.argv.includes('--self-test');
let rendererLoaded = false,
  rendererBridge = false,
  selfTestFinished = false;
const selfTestDiagnostics = [];
let protocolVerified = !process.env.PHOSPHOR_SELF_TEST_FIXTURE,
  protocolTesting = false,
  pdfVerified = true,
  selfTestPdfUrl = '';
if (selfTest) app.setPath('userData', path.join(os.tmpdir(), 'Phosphor-self-test-' + process.pid));
else if (process.argv.includes('--profile-test'))
  app.setPath('userData', path.join(root, '.test-profile'));
function finishSelfTest(error) {
  if (!selfTest || selfTestFinished || (!error && (!rendererLoaded || !rendererBridge))) return;
  if (!error && !protocolVerified) {
    if (!protocolTesting) {
      protocolTesting = true;
      verifyMediaProtocol()
        .then(() => {
          protocolVerified = true;
          finishSelfTest();
        })
        .catch((e) => finishSelfTest('Media integration failed: ' + e.message));
    }
    return;
  }
  if (!error && !pdfVerified) return;
  selfTestFinished = true;
  const report = {
    packaged: app.isPackaged,
    rendererLoaded,
    rendererBridge,
    engine: !!lastStatus.engine,
    driver: !!lastStatus.driver,
    version: app.getVersion(),
    mediaProtocol: protocolVerified && !!process.env.PHOSPHOR_SELF_TEST_FIXTURE,
    pdfPreview: pdfVerified && !!selfTestPdfUrl,
    diagnostics: selfTestDiagnostics,
    error: error || null,
  };
  fs.writeFileSync(
    process.env.PHOSPHOR_SELF_TEST_REPORT || path.join(app.getPath('userData'), 'self-test.json'),
    JSON.stringify(report, null, 2),
  );
  quit = true;
  app.quit();
}
async function verifyMediaProtocol() {
  const fixture = JSON.parse(process.env.PHOSPHOR_SELF_TEST_FIXTURE),
    backup = fixture.backup;
  await rpc('addBackupRoot', { path: path.dirname(backup) });
  await rpc('openBackup', { backup });
  const preview = await rpc('galleryPreview', { backup, file: fixture.photo }),
    url = 'phosphor-media://preview/' + preview.token;
  const original = fs.readFileSync(path.join(backup, fixture.photo.slice(0, 2), fixture.photo));
  const response = await net.fetch(url, { headers: { Range: 'bytes=5-27' } });
  if (
    response.status !== 206 ||
    response.headers.get('Content-Range') !== `bytes 5-27/${original.length}` ||
    !Buffer.from(await response.arrayBuffer()).equals(original.subarray(5, 28))
  )
    throw new Error('Range bytes did not match the synthetic original.');
  const head = await net.fetch(url, { method: 'HEAD' });
  if (head.status !== 200 || head.headers.get('Content-Length') !== String(original.length))
    throw new Error('Media HEAD failed.');
  if ((await net.fetch(url, { headers: { Range: 'bytes=999999-' } })).status !== 416)
    throw new Error('Invalid range was not rejected.');
  if (!(await rpc('fileList', { source: 'backup', backup, path: '/' })).rows.length)
    throw new Error('Backup file hierarchy did not load.');
  await rpc('lockBackup', { backup });
  if ((await net.fetch(url)).status !== 404) throw new Error('Locked preview remained readable.');
}
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) app.quit();
app.on('second-instance', () => {
  if (win) {
    win.show();
    win.focus();
  }
});
function command() {
  if (app.isPackaged)
    return [path.join(process.resourcesPath, 'engine', 'phosphor-engine.exe'), []];
  return [
    path.join(root, '.venv', 'Scripts', 'python.exe'),
    ['-u', path.join(root, 'backend', 'worker.py')],
  ];
}
function startEngine() {
  const [bin, args] = command();
  engine = spawn(bin, args, {
    windowsHide: true,
    stdio: ['pipe', 'pipe', 'pipe'],
    env: {
      ...process.env,
      PHOSPHOR_DATA: app.getPath('userData'),
      PHOSPHOR_ISOLATED_TEST: selfTest ? '1' : '0',
      PYTHONIOENCODING: 'utf-8',
      PYTHONUNBUFFERED: '1',
    },
  });
  engine.on('error', (e) => {
    for (const p of pending.values())
      p.reject(new Error('The local engine could not start: ' + e.message));
    pending.clear();
  });
  engine.stdin.on('error', () => {});
  engine.stderr.on('data', (data) => {
    if (!app.isPackaged) console.error(data.toString().slice(0, 2000));
  });
  readline.createInterface({ input: engine.stdout }).on('line', (line) => {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (msg.event) {
      rememberPaths(msg.data);
      if (msg.event === 'job') {
        const active = ['running', 'queued'].includes(msg.data.status);
        if (active && blocker === undefined)
          blocker = powerSaveBlocker.start('prevent-app-suspension');
        if (!active)
          rpc('status')
            .then((s) => {
              lastStatus = s;
              if (
                !s.jobs.some((j) => ['running', 'queued'].includes(j.status)) &&
                blocker !== undefined
              ) {
                powerSaveBlocker.stop(blocker);
                blocker = undefined;
              }
            })
            .catch(() => {});
      }
      if (win && !win.isDestroyed()) win.webContents.send('engine:event', msg);
    } else {
      const p = pending.get(msg.id);
      if (!p) return;
      clearTimeout(p.timer);
      pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error));
      else p.resolve(msg.result);
    }
  });
  engine.on('exit', () => {
    for (const p of pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error('The device engine stopped. Restart Phosphor to reconnect.'));
    }
    pending.clear();
    if (win && !win.isDestroyed())
      win.webContents.send('engine:event', { event: 'engine-stopped' });
  });
}
function rpc(method, params = {}) {
  return new Promise((resolve, reject) => {
    if (!engine?.stdin?.writable)
      return reject(new Error('The local device engine is unavailable. Restart Phosphor.'));
    const id = ++sequence;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error('The operation timed out. Check the device connection and retry.'));
    }, 120000);
    pending.set(id, { resolve, reject, timer });
    engine.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
}
function checkSender(event) {
  if (!win || event.sender !== win.webContents) throw new Error('Untrusted request');
  const url = event.senderFrame?.url ?? '';
  if (!(url.startsWith('file://') || (!app.isPackaged && url.startsWith('http://127.0.0.1:5173/'))))
    throw new Error('Untrusted origin');
}
function rememberPaths(value) {
  if (!value || typeof value !== 'object') return;
  for (const [key, v] of Object.entries(value)) {
    if (
      ['path', 'backupRoot', 'output', 'localPath'].includes(key) &&
      typeof v === 'string' &&
      /^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\)/.test(v) &&
      path.isAbsolute(v)
    )
      trustedPaths.add(path.resolve(v));
    else if (typeof v === 'object') rememberPaths(v);
  }
}
const methods = new Set([
  'status',
  'devices',
  'connectWifi',
  'forgetWifi',
  'pair',
  'deviceInfo',
  'deviceAction',
  'apps',
  'installApp',
  'removeApp',
  'files',
  'pushFile',
  'pullFile',
  'deleteFile',
  'diagnostics',
  'screenshot',
  'backups',
  'addBackupRoot',
  'setBackupRoot',
  'openBackup',
  'lockBackup',
  'renameBackup',
  'deleteBackup',
  'backupFiles',
  'backupData',
  'thumbnail',
  'exportData',
  'extractFiles',
  'archive',
  'importArchive',
  'createBackup',
  'restoreBackup',
  'clone',
  'jobs',
  'cancelJob',
  'schedule',
  'toggleSchedule',
  'deleteSchedule',
  'logs',
  'startLogs',
  'stopLogs',
  'convertPhotos',
  'createRingtone',
  'encryption',
  'galleryList',
  'galleryReviewState',
  'galleryReviewSet',
  'galleryPreview',
  'galleryMediaInfo',
  'galleryMediaRead',
  'galleryScan',
  'galleryGroups',
  'galleryRelease',
  'fileSources',
  'fileRoot',
  'fileList',
  'fileOperation',
  'filePreview',
]);
for (const method of [
  'prepareScreenshot',
  'fileMediaInfo',
  'fileMediaRead',
  'fileRelease',
  'screenshotCapabilities',
  'backupStats',
  'backupMeasure',
  'consoleClear',
  'consoleSave',
  'consoleSaved',
  'consoleOpen',
])
  methods.add(method);
ipcMain.handle('engine:call', async (event, method, params) => {
  checkSender(event);
  if (method === 'selfTestPreviewComplete') {
    if (!selfTest || !selfTestPdfUrl) throw new Error('Unknown operation');
    if (params?.error) {
      finishSelfTest('PDF rendering failed: ' + String(params.error).slice(0, 500));
      return true;
    }
    if (
      params?.page !== 1 ||
      params?.width < 100 ||
      params?.height < 100 ||
      params?.ink !== true ||
      !params?.text?.includes('Phosphor PDF fixture')
    )
      throw new Error('PDF rendering fixture failed.');
    pdfVerified = true;
    finishSelfTest();
    return true;
  }
  if (!methods.has(method)) throw new Error('Unknown operation');
  if (method === 'fileRoot' && (!params?.path || !trustedPaths.has(path.resolve(params.path))))
    throw new Error('Choose this folder using Phosphor’s folder picker first.');
  if (
    method === 'fileOperation' &&
    params?.localPath &&
    !trustedPaths.has(path.resolve(params.localPath))
  )
    throw new Error('Choose the transfer location using Phosphor’s picker first.');
  if (['screenshot', 'consoleSave'].includes(method)) {
    const destination = params?.path;
    if (destination && !trustedPaths.has(path.resolve(destination)))
      throw new Error('Choose this location using Phosphor’s picker first.');
  }
  const result = await rpc(method, params);
  if (method === 'filePreview' && result.token)
    result.url = 'phosphor-media://file-preview/' + result.token;
  if (method === 'galleryPreview') result.url = 'phosphor-media://preview/' + result.token;
  if (method === 'status') {
    result.version = app.getVersion();
    result.startup = app.getLoginItemSettings().openAtLogin;
    lastStatus = result;
    if (selfTest) {
      result.selfTestPdfUrl = selfTestPdfUrl;
      rendererBridge = true;
      setTimeout(() => finishSelfTest(), 1000);
    }
  }
  rememberPaths(result);
  return result;
});
ipcMain.handle('dialog:choose', async (event, kind, options = {}) => {
  checkSender(event);
  let selected;
  if (kind === 'save') {
    selected = (
      await dialog.showSaveDialog(win, {
        title: options.title || 'Export from Phosphor',
        defaultPath: options.name,
        filters: options.filters || [],
      })
    ).filePath;
  } else {
    const result = await dialog.showOpenDialog(win, {
      title: options.title || 'Choose a folder',
      properties: kind === 'folder' ? ['openDirectory', 'createDirectory'] : ['openFile'],
      filters: options.filters || [],
    });
    selected = result.canceled ? null : result.filePaths[0];
  }
  if (selected) trustedPaths.add(path.resolve(selected));
  return selected || null;
});
ipcMain.handle('shell:reveal', async (event, target) => {
  checkSender(event);
  const resolved = path.resolve(target);
  if (!trustedPaths.has(resolved)) throw new Error('Choose this location in Phosphor first.');
  if (fs.existsSync(resolved) && fs.statSync(resolved).isDirectory())
    await shell.openPath(resolved);
  else shell.showItemInFolder(resolved);
});
ipcMain.handle('shell:external', async (event, url) => {
  checkSender(event);
  const parsed = new URL(url);
  if (
    parsed.protocol !== 'https:' ||
    ![
      'github.com',
      'support.apple.com',
      'apps.microsoft.com',
      'www.moamenbasel.com',
      'www.icloud.com',
      'icloud.com',
      'www.apple.com',
    ].includes(parsed.hostname)
  )
    throw new Error('Unsupported link');
  await shell.openExternal(parsed.toString());
});
ipcMain.on('window:action', (event, action) => {
  checkSender(event);
  if (action === 'minimize') win.minimize();
  if (action === 'maximize') win.isMaximized() ? win.unmaximize() : win.maximize();
  if (action === 'close') win.close();
  if (action === 'startup-on') app.setLoginItemSettings({ openAtLogin: true, args: ['--hidden'] });
  if (action === 'startup-off') app.setLoginItemSettings({ openAtLogin: false });
});
function createWindow() {
  win = new BrowserWindow({
    width: 1400,
    height: 940,
    minWidth: 960,
    minHeight: 680,
    backgroundColor: '#f5f6f8',
    show: false,
    frame: false,
    icon: path.join(root, 'assets', 'icon.ico'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  if (selfTest) {
    win.webContents.on('console-message', (event, ...args) => {
      const message = event.details?.message ?? args[0]?.message ?? args[1];
      if (typeof message === 'string' && selfTestDiagnostics.length < 12)
        selfTestDiagnostics.push(message.slice(0, 800));
    });
    win.webContents.once('did-finish-load', () => {
      rendererLoaded = true;
      finishSelfTest();
    });
    win.webContents.on('preload-error', (_, file, error) =>
      finishSelfTest('Preload failed: ' + error.message),
    );
    win.webContents.on('did-fail-load', (_, code, description) =>
      finishSelfTest('Renderer failed: ' + description),
    );
  }
  win.webContents.on('render-process-gone', (_, details) => {
    dialog.showErrorBox(
      'Phosphor needs to restart',
      'The interface stopped unexpectedly (' +
        details.reason +
        '). Your backups are kept on this PC. Restart Phosphor to continue.',
    );
  });
  win.webContents.on('will-navigate', (event, url) => {
    if (url !== win.webContents.getURL()) event.preventDefault();
  });
  win.on('close', async (event) => {
    if (quit) return;
    event.preventDefault();
    try {
      lastStatus = await rpc('status');
      const active = lastStatus.jobs?.some((j) => ['running', 'queued'].includes(j.status));
      if (active || lastStatus.schedules?.some((s) => s.enabled)) {
        win.hide();
        return;
      }
    } catch {}
    quit = true;
    app.quit();
  });
  win.once('ready-to-show', () => {
    if (!selfTest && !process.argv.includes('--hidden')) win.show();
  });
  if (process.argv.includes('--dev')) win.loadURL('http://127.0.0.1:5173');
  else win.loadFile(path.join(root, 'dist', 'index.html'));
}
app.whenReady().then(async () => {
  if (selfTest)
    setTimeout(() => finishSelfTest('Startup integration test timed out.'), 30000).unref();
  Menu.setApplicationMenu(null);
  startEngine();
  if (selfTest && process.env.PHOSPHOR_SELF_TEST_FIXTURE) {
    const fixture = JSON.parse(process.env.PHOSPHOR_SELF_TEST_FIXTURE);
    if (fixture.files) {
      const folder = await rpc('fileRoot', { path: fixture.files }),
        preview = await rpc('filePreview', {
          source: 'local',
          root: folder.root,
          path: '/fixture.pdf',
        });
      selfTestPdfUrl = 'phosphor-media://file-preview/' + preview.token;
      pdfVerified = false;
    }
  }
  protocol.handle('phosphor-media', mediaHandler(rpc));
  createWindow();
  tray = new Tray(nativeImage.createFromPath(path.join(root, 'assets', 'icon.ico')));
  tray.setToolTip('Phosphor — your iPhone, at home on Windows');
  tray.on('double-click', () => {
    win.show();
    win.focus();
  });
  tray.setContextMenu(
    Menu.buildFromTemplate([
      {
        label: 'Open Phosphor',
        click: () => {
          win.show();
          win.focus();
        },
      },
      { type: 'separator' },
      {
        label: 'Quit Phosphor',
        click: async () => {
          let active = false;
          try {
            active = (await rpc('status')).jobs.some((j) =>
              ['running', 'queued'].includes(j.status),
            );
          } catch {}
          if (active) {
            const result = await dialog.showMessageBox(win, {
              type: 'warning',
              title: 'An operation is running',
              message: 'Quit Phosphor and cancel the current operation?',
              detail:
                'An interrupted backup is kept separate and will not appear as a completed backup.',
              buttons: ['Keep working', 'Quit and cancel'],
              defaultId: 0,
              cancelId: 0,
            });
            if (result.response === 0) return;
          }
          quit = true;
          app.quit();
        },
      },
    ]),
  );
});
app.on('before-quit', () => {
  quit = true;
  if (engine?.stdin?.writable) engine.stdin.end();
  setTimeout(() => engine?.kill(), 2000).unref();
});
app.on('window-all-closed', () => {
  if (quit) app.quit();
});
