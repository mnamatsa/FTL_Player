// Runs YouTube's BotGuard attestation in a simulated page and mints a PO token bound to a visitor ID.
// Started as a worker that may only reach Google's attestation server; it is terminated after one token,
// which frees the memory the simulated page (jsdom) needs.
import { BotGuardClient, getChallenge } from 'bgutils-js/botguard';
import { buildURL, getHeaders, USER_AGENT } from 'bgutils-js/utils';
import { WebPoMinter } from 'bgutils-js/webpo';
import { JSDOM } from 'jsdom';

const REQUEST_KEY = 'O43z0dpjhgX20SCx4KAo'; // YouTube web player's attestation key

async function mint(visitorData: string) {
  const dom = new JSDOM('<!DOCTYPE html><html lang="en"><head><title></title></head><body></body></html>',
    { url: 'https://www.youtube.com/', referrer: 'https://www.youtube.com/', userAgent: USER_AGENT });
  // A worker's location/navigator are read-only built-ins, so shadow them with the page's own.
  const page = { window: dom.window, document: dom.window.document, location: dom.window.location,
                 origin: dom.window.origin, navigator: dom.window.navigator };
  for (const [name, value] of Object.entries(page))
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });

  const challenge: any = await getChallenge({ fetchFunction: fetch, requestKey: REQUEST_KEY });
  const interpreter = challenge.interpreterJavascript?.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (!interpreter) throw new Error('BotGuard interpreter not available');
  new Function(interpreter)();

  const client = await BotGuardClient.create({ program: challenge.program, globalName: challenge.globalName, globalObject: globalThis });
  const signals: any[] = [];
  const response = await client.snapshot({ webPoSignalOutput: signals });
  const r = await fetch(buildURL('GenerateIT', true), { method: 'POST', headers: getHeaders(), body: JSON.stringify([REQUEST_KEY, response]) });
  if (!r.ok) throw new Error(`integrity token request failed: HTTP ${r.status}`);
  const [integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken] = await r.json();
  const minter = await WebPoMinter.create({ integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken }, signals);
  return { poToken: await minter.mintAsWebsafeString(visitorData), ttl: Number(estimatedTtlSecs) || 21600 };
}

self.onmessage = async (e: MessageEvent) => {
  try { self.postMessage({ ok: true, ...(await mint(e.data.visitorData)) }); }
  catch (err) { self.postMessage({ ok: false, error: String((err as Error)?.message ?? err) }); }
};
