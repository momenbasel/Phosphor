const fs = require('node:fs'),
  path = require('node:path');
const root = path.resolve(__dirname, '..'),
  source = path.join(root, 'node_modules', 'pdfjs-dist');
for (const folder of ['cmaps', 'standard_fonts', 'wasm', 'iccs']) {
  fs.cpSync(path.join(source, folder), path.join(root, 'public', 'pdfjs', folder), {
    recursive: true,
  });
}
const licenses = path.join(root, 'assets', 'licenses');
fs.mkdirSync(licenses, { recursive: true });
fs.copyFileSync(path.join(source, 'LICENSE'), path.join(licenses, 'pdfjs-dist-LICENSE'));
for (const folder of ['standard_fonts', 'wasm', 'iccs'])
  for (const name of fs.readdirSync(path.join(source, folder))) {
    if (
      /LICENSE|COPYING|NOTICE/i.test(name) &&
      fs.statSync(path.join(source, folder, name)).isFile()
    )
      fs.copyFileSync(
        path.join(source, folder, name),
        path.join(licenses, 'pdfjs-' + folder + '-' + name),
      );
  }
