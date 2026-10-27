// Build step: jsdom reads files from its package folder at runtime, which does not exist once bundled.
// Embed its default stylesheet into build/potoken.js and neutralise the one remaining file lookup.
// usage: deno run --allow-read --allow-write postbundle.ts <bundle> <default-stylesheet.css>
const [bundlePath, cssPath] = Deno.args;
const bundle = await Deno.readTextFile(bundlePath);
const pattern = /fs\.readFileSync\(path\.resolve\(__dirname, "\.\.\/\.\.\/\.\.\/browser\/default-stylesheet\.css"\), \{\s*encoding: "utf-8"\s*\}\)/;
if (!pattern.test(bundle)) throw new Error('jsdom stylesheet read not found in bundle; check after a jsdom update');
const css = await Deno.readTextFile(cssPath);
let out = bundle.replace(pattern, () => JSON.stringify(css));
// Synchronous XHR (which BotGuard does not use) needs a helper script from jsdom's folder; looking it up
// would need read access to the app folder, so give it a name that is never loaded.
out = out.replace('__require.resolve("./xhr-sync-worker.js")', '"xhr-sync-worker.js"');
if (/__dirname|require\.resolve\(/.test(out)) console.warn('warning: bundle still looks up files on disk');
await Deno.writeTextFile(bundlePath, out);
console.log('embedded jsdom assets');
