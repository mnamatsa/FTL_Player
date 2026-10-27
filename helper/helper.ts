// FTL Player helper: talks to YouTube through youtubei.js.
// Protocol: one JSON object per line on stdin ({id, cmd, ...args}), one JSON reply per line on stdout
// ({id, ok: true, ...result} or {id, ok: false, error}). Everything else (logs) goes to stderr.
import { Constants, Innertube, Log, Parser, Platform, UniversalCache } from 'youtubei.js';

const out = (o: unknown) => Deno.stdout.writeSync(new TextEncoder().encode(JSON.stringify(o) + '\n'));
for (const k of ['log', 'info', 'warn', 'debug'] as const) (console as any)[k] = console.error;
Log.setLevel(Log.Level.ERROR);

const dataDir = Deno.args[0] ?? '.';
const debug = Deno.args.includes('--debug'); // logs proxy traffic to stderr (Data/helper.log)

// YouTube's player code (signature / n deciphering) runs in a worker that has no permissions at all.
const workerSrc = `self.onmessage = (e) => {
  const { id, code } = e.data;
  try { self.postMessage({ id, result: new Function(code)() }); }
  catch (err) { self.postMessage({ id, error: String(err) }); }
};`;
const worker = new Worker(URL.createObjectURL(new Blob([workerSrc], { type: 'application/javascript' })),
  { type: 'module', deno: { permissions: 'none' } } as any);
let evalSeq = 0;
const evalPending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
worker.onmessage = (e: MessageEvent) => {
  const p = evalPending.get(e.data.id);
  evalPending.delete(e.data.id);
  if (e.data.error) p?.reject(new Error(e.data.error)); else p?.resolve(e.data.result);
};
Platform.shim.eval = (data: any) => new Promise((resolve, reject) => {
  const id = ++evalSeq;
  evalPending.set(id, { resolve, reject });
  worker.postMessage({ id, code: data.output });
});

// Session. Without a PO token YouTube serves only the first minute of each stream, so the session carries
// a visitor ID plus a PO token bound to it. Both are kept in Data/cache/session.json for the token's
// lifetime (~12 h), so BotGuard only has to run when the saved token is about to expire.
const sessionFile = `${dataDir}/cache/session.json`;
type Saved = { visitorData: string; poToken: string; expires: number };
let sessionExpires = 0;
let hasPoToken = false;
let poToken = '';

// Environment variables the bundled jsdom/undici code reads while loading.
const TOKEN_ENV = ['UNDICI_NO_WASM_SIMD', 'UNDICI_USE_MILO', 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy', 'JEST_WORKER_ID', 'CI'];

function mintPoToken(visitorData: string): Promise<{ poToken: string; ttl: number }> {
  const script = new URL('./potoken.js', import.meta.url);
  const scriptPath = decodeURIComponent(script.pathname).replace(/^\/([A-Za-z]:)/, '$1');
  const w = new Worker(script.href, {
    type: 'module',
    deno: { permissions: { net: ['www.youtube.com', 'jnn-pa.googleapis.com', 'www.google.com', 'www.gstatic.com'], read: [scriptPath], env: TOKEN_ENV } },
  } as any);
  return new Promise<{ poToken: string; ttl: number }>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('PO token generation timed out')), 30000);
    w.onmessage = (e: MessageEvent) => { clearTimeout(timer); e.data.ok ? resolve(e.data) : reject(new Error(e.data.error)); };
    w.onerror = (e: ErrorEvent) => { clearTimeout(timer); e.preventDefault(); reject(new Error(e.message)); };
    w.postMessage({ visitorData });
  }).finally(() => w.terminate());
}

async function createSession() {
  const cache = new UniversalCache(true, `${dataDir}/cache`);
  let saved: Saved | null = null;
  try { saved = JSON.parse(await Deno.readTextFile(sessionFile)); } catch { /* none yet */ }
  if (!saved || saved.expires < Date.now() + 15 * 60_000) {
    try {
      const anon = await Innertube.create({ cache, lang: 'en', retrieve_player: false });
      const visitorData = anon.session.context.client.visitorData!;
      const { poToken, ttl } = await mintPoToken(visitorData);
      saved = { visitorData, poToken, expires: Date.now() + ttl * 1000 };
      await Deno.writeTextFile(sessionFile, JSON.stringify(saved));
    } catch (e) {
      console.error('PO token unavailable, streams will stop after about a minute:', e);
      saved = null;
    }
  }
  hasPoToken = !!saved;
  poToken = saved?.poToken ?? '';
  sessionExpires = saved?.expires ?? Date.now() + 3600_000;
  return Innertube.create(saved ? { cache, lang: 'en', visitor_data: saved.visitorData, po_token: saved.poToken } : { cache, lang: 'en' });
}

let ytPromise: Promise<Innertube> | null = null;
const yt = () => {
  if (ytPromise && Date.now() > sessionExpires - 5 * 60_000 && sessionExpires) ytPromise = null; // renew in time
  return ytPromise ??= createSession().catch((e) => { ytPromise = null; throw e; });
};

const text = (v: any): string => (v == null ? '' : typeof v === 'string' ? v : v.text ?? v.toString?.() ?? '');

function videoItem(v: any) {
  const id = v.video_id ?? v.id;
  if (!id) return null;
  const badges = (v.badges ?? []).map((b: any) => text(b.label ?? b.text)).join(' ').toLowerCase();
  return {
    videoId: id,
    title: text(v.title),
    channel: v.author?.name ?? '',
    channelId: v.author?.id ?? '',
    duration: v.duration?.text ?? '',
    views: (text(v.short_view_count) || text(v.view_count)).replace(/ (views?|watching|waiting)$/i, ""),   // (the card adds the word)
    published: text(v.published),
    live: !!v.is_live || badges.includes('live'),
    upcoming: !!v.is_upcoming,
    short: false,
    publishedAt: 0,
    thumbnail: `https://i.ytimg.com/vi/${id}/mqdefault.jpg`,
  };
}

// Search, with YouTube's filters: {type: video | channel | playlist, upload_date: all | today | week | month |
// year, duration: all | under_three_mins | three_to_twenty_mins | over_twenty_mins, prioritize: relevance |
// popularity, features: [hd, 4k, live, subtitles, creative_commons, 360, hdr, vr180 ...]}. Results by kind:
// videos as everywhere, channels {id, name, thumbnail, subscribers, handle}, playlists as on channel pages.
let lastSearch: any = null;
let lastSearchType = 'video';
const FILTER_VALUES: Record<string, string[]> = {
  type: ['video', 'channel', 'playlist'], upload_date: ['all', 'today', 'week', 'month', 'year'],
  duration: ['all', 'under_three_mins', 'three_to_twenty_mins', 'over_twenty_mins'], prioritize: ['relevance', 'popularity'],
};
const FEATURES = ['hd', '4k', 'live', 'subtitles', 'creative_commons', '360', 'hdr', 'vr180', '3d', 'location', 'purchased'];

function searchFilters(f: any) {
  const out: any = { type: 'video' };
  for (const [k, values] of Object.entries(FILTER_VALUES))
    if (values.includes(f?.[k])) out[k] = f[k];
  const features = (Array.isArray(f?.features) ? f.features : []).filter((x: string) => FEATURES.includes(x));
  if (features.length && out.type === 'video') out.features = features;
  return out;
}

function channelResult(c: any) {
  if (!c.id) return null;
  // (YouTube's search result has the handle where the subscriber count belongs, and the count in video_count)
  const a = text(c.subscriber_count), b = text(c.video_count);
  const thumb = c.author?.thumbnails?.[0]?.url ?? '';
  return { id: c.id, name: c.author?.name ?? text(c.title), thumbnail: thumb.startsWith('//') ? 'https:' + thumb : thumb,
           handle: a.startsWith('@') ? a : '', subscribers: a.startsWith('@') ? b : a };
}

function searchPage(s: any) {
  lastSearch = s;
  let results: any[];
  if (lastSearchType === 'channel') results = (s.results ?? []).filter((n: any) => n.type === 'Channel').map(channelResult);
  else if (lastSearchType === 'playlist')
    results = (s.results ?? []).filter((n: any) => n.type === 'LockupView').map((lv: any) => {
      const p = playlistItem(lv);
      const parts = (lv.metadata?.metadata?.metadata_rows ?? []).flatMap((r: any) => (r.metadata_parts ?? []).map((m: any) => text(m.text)));
      return p && { ...p, channel: parts.find((t: string) => t && !/^(view full|updated|\d)/i.test(t)) ?? '' };
    });
  else results = (s.videos ?? []).filter((v: any) => v.type === 'Video').map(videoItem);
  return { results: results.filter(Boolean), kind: lastSearchType, more: !!s.has_continuation };
}

async function search(r: any) {
  const filters = searchFilters(r.filters);
  lastSearchType = filters.type;
  return searchPage(await (await yt()).search(String(r.query ?? ''), filters));
}

// Channel tabs (subscriptions feed). Channel pages list videos as LockupView components.
const TAB_PARAMS: Record<string, string> = { videos: 'EgZ2aWRlb3PyBgQKAjoA', streams: 'EgdzdHJlYW1z8gYECgJ6AA==',
                                             playlists: 'EglwbGF5bGlzdHPyBgQKAkIA' };
const UNIT_MS: Record<string, number> = { s: 1e3, m: 6e4, h: 36e5, d: 864e5, w: 6048e5, mo: 2592e6, y: 31536e6 };

// "5mo ago", "Streamed 2 days ago", "3 weeks ago" -> approximate timestamp (ms), used only for sorting.
function approxTime(published: string, now: number) {
  const m = published.toLowerCase().match(/(\d+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wk|w|months?|mo|years?|yrs?|y)\b/);
  if (!m) return 0;
  const u = m[2];
  const unit = u.startsWith('mo') ? 'mo' : u.startsWith('mi') || u === 'm' ? 'm' : u[0];
  return now - Number(m[1]) * (UNIT_MS[unit] ?? 0);
}

function lockupItem(lv: any, now: number) {
  const id = lv.content_id;
  if (!id || (lv.content_type && lv.content_type !== 'VIDEO')) return null;
  const parts: string[] = (lv.metadata?.metadata?.metadata_rows ?? [])
    .flatMap((r: any) => (r.metadata_parts ?? []).map((p: any) => text(p.text)));
  const badges = (lv.content_image?.overlays ?? []).flatMap((o: any) => o.badges ?? []);
  const badgeText = badges.map((b: any) => `${b.text ?? ''} ${b.badge_style ?? ''}`).join(' ');
  // An upcoming stream has both "3 waiting" and "Scheduled for …": the date line is the one wanted.
  const published = parts.find((t) => /^(scheduled|premieres?)\b/i.test(t)) ?? parts.find((t) => /ago|streamed/i.test(t)) ?? '';
  const views = parts.find((t) => t !== published && /^[\d.,]+\s*[KMB]?( views?| watching| waiting)?$/i.test(t)) ?? '';
  const channel = parts.find((t) => t !== published && t !== views && !/^[\d.,]+\s*[KMB]?\b/.test(t)) ?? '';
  const live = /\bLIVE\b/.test(badgeText) && !/UPCOMING/.test(badgeText);
  const upcoming = /UPCOMING/i.test(badgeText) || /^(scheduled|premieres?)/i.test(published);
  // "Streamed 2 days ago" = an ended live stream; "Premieres ..." / a plain "2 days ago" = a premiere.
  const stream = live || /^streamed/i.test(published) || (upcoming && /^scheduled/i.test(published));
  const duration = badges.map((b: any) => b.text ?? '').find((t: string) => /^\d+(:\d\d)+$/.test(t)) ?? '';
  return {
    videoId: id, title: text(lv.metadata?.title), channel, channelId: '',
    duration, views: views.replace(/ (views?|watching|waiting)$/i, ''), published, live, upcoming, stream, short: false,
    publishedAt: live || upcoming ? now : approxTime(published, now),
    thumbnail: `https://i.ytimg.com/vi/${id}/mqdefault.jpg`,
  };
}

// YouTube answers bursts of channel requests with HTTP 429, so channel requests are paced, and a 429 pauses
// all of them (doubling each time) before retrying.
let browseRate = 20;           // requests per second; 20/s refreshed 545 channels in ~33 s without a 429
let nextSlot = 0;
let pausedUntil = 0;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function browsePaced(y: Innertube, payload: any) {
  for (let attempt = 0; ; attempt++) {
    for (;;) {
      const now = Date.now();
      const wait = Math.max(pausedUntil, nextSlot) - now;
      if (wait <= 0) { nextSlot = now + 1000 / browseRate; break; }
      await sleep(wait);
    }
    try {
      return await y.actions.execute('/browse', payload);
    } catch (e) {
      // a passing server error: once more (a channel page opened from a link once got a 500, then loaded)
      if (/status code 5\d\d/.test(String(e)) && attempt === 0) { await sleep(500); continue; }
      if (!/status code 429/.test(String(e)) || attempt >= 4) throw e;
      pausedUntil = Math.max(pausedUntil, Date.now() + 2000 * 2 ** attempt);
      if (debug) console.error('429 from YouTube, pausing channel requests for', 2 * 2 ** attempt, 's');
    }
  }
}

// A playlist card (channel Playlists tab): LockupView with content_type PLAYLIST or SHOW.
function playlistItem(lv: any) {
  if (!lv.content_id || !['PLAYLIST', 'SHOW', 'PODCAST'].includes(lv.content_type)) return null;
  const json = JSON.stringify(lv.content_image ?? {});
  const count = json.match(/"text":"(\d[\d,]* (?:videos?|episodes?|lessons?))"/)?.[1] ?? '';
  const thumb = json.match(/https:\/\/i\.ytimg\.com\/[^"]+/)?.[0] ?? '';
  return { playlistId: lv.content_id, title: text(lv.metadata?.title), count, thumbnail: thumb };
}

// "Load more" pages of channel tabs, by token handed to the app.
const continuations = new Map<string, any>();

function pageItems(page: any, channelId: string, tab: string) {
  const now = Date.now();
  const memos = [page.contents_memo, page.on_response_received_actions_memo].filter(Boolean);
  const lockups = memos.flatMap((m: any) => m.get('LockupView') ?? []);
  if (tab === 'playlists') {
    const cont = memos.flatMap((m: any) => m.get('ContinuationItem') ?? [])[0];
    let continuation = '';
    if (cont?.endpoint) {
      continuation = crypto.randomUUID();
      continuations.set(continuation, { endpoint: cont.endpoint, channelId, tab });
    }
    return { items: lockups.map(playlistItem).filter(Boolean), continuation };
  }
  let items = lockups.map((lv: any) => lockupItem(lv, now)).filter(Boolean);
  if (tab === 'streams')
    items = items.filter((v: any) => v.stream);
  for (const it of items) it.channelId = channelId;
  const cont = memos.flatMap((m: any) => m.get('ContinuationItem') ?? [])[0];
  let continuation = '';
  if (cont?.endpoint) {
    continuation = crypto.randomUUID();
    continuations.set(continuation, { endpoint: cont.endpoint, channelId, tab });
    while (continuations.size > 50) continuations.delete(continuations.keys().next().value!);
  }
  return { items, continuation };
}

function channelDetails(page: any, channelId: string) {
  // Name, avatar and description come from the page's microformat; handle and subscriber count from the
  // header's metadata rows (e.g. ["@LofiGirl"], ["15.8M subscribers", "474 videos"]).
  const mf = page.microformat;
  const rows: string[] = (page.header_memo?.get('ContentMetadataView')?.[0]?.metadata_rows ?? [])
    .flatMap((r: any) => (r.metadata_parts ?? []).map((p: any) => text(p.text)));
  return {
    id: channelId,
    name: text(mf?.title),
    avatar: mf?.thumbnail?.[0]?.url ?? '',
    subscribers: rows.find((t) => /subscriber/i.test(t)) ?? '',
    videoCount: rows.find((t) => /videos?$/i.test(t)) ?? '',
    handle: rows.find((t) => t.startsWith('@')) ?? '',
    description: text(mf?.description),
  };
}

async function channelTab(channelId: string, tab: string) {
  const y = await yt();
  const raw = await browsePaced(y, { browseId: channelId, params: TAB_PARAMS[tab] ?? TAB_PARAMS.videos });
  return pageItems(Parser.parseResponse(raw.data), channelId, tab);
}

// Channel page: details plus the first page of a tab, or the next page of a tab via its continuation.
async function channelPage(r: any) {
  const y = await yt();
  if (r.continuation) {
    const c = continuations.get(String(r.continuation));
    if (!c) throw new Error('This list needs to be reloaded.');
    continuations.delete(String(r.continuation));
    const token = c.endpoint.payload?.token ?? c.endpoint.payload?.continuation;
    const raw = await browsePaced(y, { continuation: token });
    return pageItems(Parser.parseResponse(raw.data), c.channelId, c.tab);
  }
  const channelId = String(r.channelId);
  const raw = await browsePaced(y, { browseId: channelId, params: TAB_PARAMS[r.tab] ?? TAB_PARAMS.videos });
  const page: any = Parser.parseResponse(raw.data);
  return { info: channelDetails(page, channelId), ...pageItems(page, channelId, String(r.tab ?? 'videos')) };
}

// Videos of a playlist, page by page: {playlistId} -> {info, items, continuation}; {continuation} -> more.
const playlists = new Map<string, any>();

function playlistPage(pl: any) {
  const now = Date.now();
  const ownerId = pl.info?.author?.id ?? '';
  const owner = pl.info?.author?.name ?? '';
  const items = (pl.videos ?? []).map((v: any) => (v.type === 'LockupView' ? lockupItem(v, now) : videoItem(v)))
    .filter(Boolean)
    .map((v: any) => Object.assign(v, { channelId: v.channelId || (v.channel === owner ? ownerId : '') }));
  let continuation = '';
  if (pl.has_continuation) {
    continuation = crypto.randomUUID();
    playlists.set(continuation, pl);
    while (playlists.size > 30) playlists.delete(playlists.keys().next().value!);
  }
  return { items, continuation };
}

async function playlist(r: any) {
  if (r.continuation) {
    const pl = playlists.get(String(r.continuation));
    if (!pl) throw new Error('This playlist needs to be reopened.');
    playlists.delete(String(r.continuation));
    return playlistPage(await pl.getContinuation());
  }
  const pl: any = await (await yt()).getPlaylist(String(r.playlistId));
  return {
    info: { playlistId: String(r.playlistId), title: text(pl.info?.title), channel: pl.info?.author?.name ?? '',
            channelId: pl.info?.author?.id ?? '', count: text(pl.info?.total_items) },
    ...playlistPage(pl),
  };
}

// Comments. Pages and threads are kept (keyed by a token / the comment ID) so that the next page and the
// replies can be fetched; only the most recent ones stay.
const commentPages = new Map<string, any>();      // continuation token -> Comments page
const commentThreads = new Map<string, any>();    // comment ID -> thread, or its last page of replies

function keep(map: Map<string, any>, key: string, value: any, max: number) {
  map.delete(key);
  map.set(key, value);
  while (map.size > max) map.delete(map.keys().next().value!);
}

function commentItem(t: any) {
  const c = t?.comment;
  if (!c?.comment_id) return null;
  if (t.has_replies) keep(commentThreads, c.comment_id, t, 2000);
  const a = c.author;
  return {
    commentId: c.comment_id,
    author: a?.name ?? '',
    authorId: a?.id ?? '',
    avatar: a?.best_thumbnail?.url ?? a?.thumbnails?.[0]?.url ?? '',
    text: text(c.content),
    published: c.published_time ?? '',
    likes: c.like_count && c.like_count !== '0' ? c.like_count : '',
    hasReplies: !!t.has_replies,
    replyCount: t.has_replies ? String(c.reply_count ?? '') : '',
    pinned: !!c.is_pinned,
    owner: !!c.author_is_channel_owner,
    hearted: !!c.is_hearted,
    member: !!c.is_member,
  };
}

function commentPage(page: any) {
  const more = page.has_continuation ? crypto.randomUUID() : '';
  if (more) keep(commentPages, more, page, 32);
  return { items: (page.contents ?? []).map(commentItem).filter(Boolean), more };
}

// {videoId, sort: 'top' | 'new'} -> {count, items, more}; {more} -> {items, more}
async function comments(r: any) {
  if (r.more) {
    const page = commentPages.get(String(r.more));
    if (!page) throw new Error('Reopen the video to load more comments.');
    commentPages.delete(String(r.more));
    return commentPage(await page.getContinuation());
  }
  const page: any = await (await yt()).getComments(String(r.videoId), r.sort === 'new' ? 'NEWEST_FIRST' : 'TOP_COMMENTS');
  return { count: text(page.header?.count) || text(page.header?.comments_count), ...commentPage(page) };
}

// {commentId} -> {items, more}: replies to a comment; {commentId, more: true} -> the next replies
// (not "id": that is the request's own number)
async function replies(r: any) {
  const id = String(r.commentId);
  const known = commentThreads.get(id);
  if (!known) throw new Error('Reopen the video to see these replies.');
  const page = r.more ? await known.getContinuation() : await known.getReplies();
  keep(commentThreads, id, page, 2000);
  return { items: (page.replies ?? []).map(commentItem).filter(Boolean), more: !!page.has_continuation };
}

// {ids} -> {states: {id: {upcoming, premiere, live, start}}}: whether videos have started (scheduled streams
// and premieres look like normal uploads in the RSS feed); start = the scheduled start time (ms), when given.
// A premiere is upcoming but not live content ("Premieres in …"); a scheduled stream is ("Live in …").
async function videoStates(r: any) {
  const y = await yt();
  const ids: string[] = (r.ids ?? []).map(String).slice(0, 300);
  const states: Record<string, { upcoming: boolean; premiere: boolean; live: boolean; start: number }> = {};
  let next = 0;
  await Promise.all(Array.from({ length: 4 }, async () => {
    while (next < ids.length) {
      const id = ids[next++];
      try {
        const info: any = await y.getBasicInfo(id, { client: 'WEB' } as any);
        const b = info.basic_info ?? {};
        const start = b.start_timestamp ? new Date(b.start_timestamp).getTime() : 0;
        states[id] = { upcoming: !!b.is_upcoming, premiere: !!b.is_upcoming && !b.is_live_content, live: !!b.is_live,
                       start: Number.isFinite(start) ? start : 0 };
      } catch { /* left out: looked up again next time */ }
    }
  }));
  return { states };
}

// RSS feed of a channel's latest 15 uploads: about twice as fast and 20x smaller than the channel tab,
// with exact publish times, but no durations and no live/upcoming flags.
let rssRate = 60;              // feeds per second; 545 feeds at 100/s drew no refusals
let rssNextSlot = 0;
const XML_ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
const unxml = (s: string) => s.replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e: string) =>
  e[0] === '#' ? String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : Number(e.slice(1)))
               : XML_ENTITIES[e] ?? m);

function compactCount(n: number) {
  if (n >= 1e9) return `${+(n / 1e9).toFixed(n < 1e10 ? 1 : 0)}B`;
  if (n >= 1e6) return `${+(n / 1e6).toFixed(n < 1e7 ? 1 : 0)}M`;
  if (n >= 1e3) return `${+(n / 1e3).toFixed(n < 1e4 ? 1 : 0)}K`;
  return String(n);
}

async function rssFeed(channelId: string) {
  for (;;) {
    const now = Date.now();
    const wait = rssNextSlot - now;
    if (wait <= 0) { rssNextSlot = now + 1000 / rssRate; break; }
    await sleep(wait);
  }
  // YouTube's RSS fails for many channels at times (in October 2026 it answered 404 or 500 for about 70 % of
  // them, also when asked slowly); those channels are read from their Videos tab instead (slower, with
  // durations, approximate dates).
  let r: Response | null = null;
  try { r = await fetch(`https://www.youtube.com/feeds/videos.xml?channel_id=${encodeURIComponent(channelId)}`); }
  catch { /* network error: try the tab */ }
  if (!r?.ok) {
    await r?.body?.cancel();
    try {
      const tab = await channelTab(channelId, 'videos');
      return { items: tab.items.slice(0, 15), channel: tab.items[0]?.channel ?? '', via: 'tab' };
    } catch (e) {
      throw new Error(`RSS feed: ${r ? 'HTTP ' + r.status : 'no connection'}; channel page: ${e instanceof Error ? e.message : e}`);
    }
  }
  const xml = await r.text();
  const tag = (e: string, re: RegExp) => unxml(e.match(re)?.[1] ?? '');
  const channel = tag(xml, /<author>\s*<name>([^<]*)<\/name>/);
  const items = [...xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)].map(([, e]) => {
    const id = tag(e, /<yt:videoId>([^<]+)</);
    return {
      videoId: id, title: tag(e, /<title>([^<]*)</), channel, channelId,
      duration: '', views: compactCount(Number(tag(e, /<media:statistics views="(\d+)"/)) || 0), published: '',
      live: false, upcoming: false, short: /\/shorts\//.test(tag(e, /<link rel="alternate" href="([^"]+)"/)),
      publishedAt: Date.parse(tag(e, /<published>([^<]+)</)) || 0,
      thumbnail: `https://i.ytimg.com/vi/${id}/mqdefault.jpg`,
    };
  }).filter((v) => v.videoId);
  return { items, channel };
}

// Clients that return plain stream URLs, best first. With the session's PO token TV_SIMPLY streams play to
// the end; the others are fallbacks that work for some videos only.
const CLIENTS = ['TV_SIMPLY', 'MWEB', 'IOS', 'ANDROID_VR'] as const;
const DESKTOP_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
const CODEC_RANK: Record<string, number> = { vp9: 3, vp09: 3, avc1: 2, av01: 1 };
const codecOf = (f: any) => (f.mime_type?.match(/codecs="([^".]+)/)?.[1] ?? '').toLowerCase();
const isHdr = (f: any) => /PQ|HLG|SMPTE2084|ARIB/i.test(f.color_info?.transfer_characteristics ?? '')
  || /codecs="vp09\.02/.test(f.mime_type ?? '') || (f.quality_label ?? '').includes('HDR');

// The codec setting: "vp9" | "h264" | "av1" ("" / "auto": none). A preferred codec is used whenever the video
// has it up to the quality limit, even at a lower resolution than another codec offers.
const CODEC_FAMILY: Record<string, string[]> = { vp9: ['vp9', 'vp09'], h264: ['avc1'], av1: ['av01'] };
const isCodec = (f: any, codec: string) => (CODEC_FAMILY[codec] ?? []).includes(codecOf(f));

function pickVideo(fmts: any[], maxHeight: number, codec = '') {
  let vids = fmts.filter((f) => f.has_video && !f.has_audio && f.height <= maxHeight && !isHdr(f));
  const preferred = vids.filter((f) => isCodec(f, codec));
  if (preferred.length) vids = preferred;
  vids.sort((a, b) => b.height - a.height || (b.fps ?? 0) - (a.fps ?? 0)
    || (CODEC_RANK[codecOf(b)] ?? 0) - (CODEC_RANK[codecOf(a)] ?? 0) || b.bitrate - a.bitrate);
  return vids[0];
}

// One entry per resolution/frame rate, using the best codec available for it (the preferred one, else
// VP9 > H.264 > AV1).
function qualityList(fmts: any[], codec = '') {
  const rank = (f: any) => (isCodec(f, codec) ? 10 : 0) + (CODEC_RANK[codecOf(f)] ?? 0);
  const best = new Map<string, any>();
  for (const f of fmts) {
    if (!f.has_video || f.has_audio || isHdr(f)) continue;
    const key = `${f.height}p${(f.fps ?? 30) > 30 ? f.fps : ''}`;
    const cur = best.get(key);
    if (!cur || rank(f) > rank(cur) || (rank(f) === rank(cur) && f.bitrate > cur.bitrate))
      best.set(key, f);
  }
  return [...best.entries()]
    .map(([label, f]) => ({ itag: f.itag, label, height: f.height, fps: f.fps ?? 30, codec: codecOf(f) }))
    .sort((a, b) => b.height - a.height || b.fps - a.fps);
}

function videoInfo(f: any, url: string, ua: string) {
  return { url: proxy(f, url, ua), itag: f.itag, height: f.height, fps: f.fps ?? 0, codec: codecOf(f),
           label: `${f.height}p${(f.fps ?? 30) > 30 ? f.fps : ''}` };
}

// One entry per audio track (dubbed languages), using its best format (Opus first).
function audioTrackList(fmts: any[]) {
  const best = new Map<string, any>();
  for (const f of fmts) {
    if (!f.has_audio || f.has_video || f.is_drc) continue;
    const key = f.audio_track?.id ?? 'main';
    const cur = best.get(key);
    const better = !cur || (codecOf(f) === 'opus' ? 1 : 0) - (codecOf(cur) === 'opus' ? 1 : 0) > 0
      || ((codecOf(f) === 'opus') === (codecOf(cur) === 'opus') && f.bitrate > cur.bitrate);
    if (better) best.set(key, f);
  }
  return [...best.values()].map((f) => ({
    itag: f.itag, track: f.audio_track?.id ?? 'main', label: f.audio_track?.display_name ?? 'Original',
    // The original language; YouTube's own "default" can be a dub chosen for the viewer's region.
    original: !f.audio_track || !!f.is_original || /original/i.test(f.audio_track?.display_name ?? ''),
  }));
}

function audioInfo(f: any, url: string, ua: string) {
  return { url: proxy(f, url, ua), itag: f.itag, track: f.audio_track?.id ?? 'main', codec: codecOf(f),
           bitrate: f.bitrate, label: f.audio_track?.display_name ?? 'Original' };
}

function pickAudio(fmts: any[]) {
  const auds = fmts.filter((f) => f.has_audio && !f.has_video && !f.is_drc);
  const main = auds.filter((f) => !f.audio_track || f.audio_track.audio_is_default || f.is_original);
  const pool = main.length ? main : auds;
  pool.sort((a, b) => (codecOf(b) === 'opus' ? 1 : 0) - (codecOf(a) === 'opus' ? 1 : 0) || b.bitrate - a.bitrate);
  return pool[0];
}

// Local stream proxy. googlevideo refuses open-ended byte ranges (what mpv sends), and also any single
// range covering more than roughly a minute of media, so mpv reads from 127.0.0.1 and the proxy fetches
// the requested span from YouTube in chunks of ~45 s of playback (at most 8 MB).
const proxied = new Map<string, { url: string; ua: string; size: number; mime: string; chunk: number }>();
const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, proxyHandler);

function proxy(f: any, url: string, ua: string) {
  const token = crypto.randomUUID();
  const size = Number(f.content_length) || 0;
  const seconds = Number(f.approx_duration_ms) / 1000 || 0;
  const bytesPerSecond = seconds > 0 ? size / seconds : (Number(f.bitrate) || 1_000_000) / 8;
  const chunk = Math.round(Math.min(8 << 20, Math.max(256 << 10, bytesPerSecond * 45)));
  proxied.set(token, { url, ua, size, chunk, mime: f.mime_type?.split(';')[0] ?? 'application/octet-stream' });
  while (proxied.size > 32) proxied.delete(proxied.keys().next().value!); // only recent videos stay reachable
  return `http://127.0.0.1:${server.addr.port}/s/${token}`;
}

// `patience` (ms): how long network errors (no connection, a reset) keep being retried, beyond the usual three
// tries: the PC waking up from sleep has no network for a while, and the video should go on once it's back.
async function fetchChunk(url: string, ua: string, signal: AbortSignal, patience = 0) {
  const deadline = Date.now() + patience;
  for (let attempt = 0; ; attempt++) {
    let network = false;
    try {
      const r = await fetch(url, { headers: { 'User-Agent': ua }, signal }).catch((e) => { network = true; throw e; });
      if (debug) console.error('upstream', r.status, url.match(/itag=(\d+)/)?.[1], url.match(/&range=[\d-]+$/)?.[0], url.length);
      if (r.ok) return r;
      await r.body?.cancel();
      if (r.status < 500 || attempt >= 2) throw new Error(`upstream HTTP ${r.status}`);
    } catch (e) {
      if (signal.aborted || (attempt >= 2 && !(network && Date.now() < deadline))) throw e;
    }
    await new Promise((res) => setTimeout(res, Math.min(500 * (attempt + 1), 3000)));
  }
}

// Caption tracks, served as WebVTT so mpv can load them as subtitles.
const captionTracks = new Map<string, { url: string; ua: string; body?: string }>();

function captionList(info: any, ua: string) {
  const tracks = (info.captions?.caption_tracks ?? []).map((t: any) => {
    const token = crypto.randomUUID();
    captionTracks.set(token, { url: `${t.base_url}&fmt=vtt`, ua });
    return { label: text(t.name), lang: t.language_code ?? '', auto: t.kind === 'asr',
             url: `http://127.0.0.1:${server.addr.port}/c/${token}` };
  });
  while (captionTracks.size > 64) captionTracks.delete(captionTracks.keys().next().value!);
  return tracks.sort((a: any, b: any) => Number(a.auto) - Number(b.auto)); // made by people first
}

async function captionResponse(token: string) {
  const c = captionTracks.get(token);
  if (!c) return new Response('not found', { status: 404 });
  if (c.body === undefined) {
    const r = await fetch(c.url, { headers: { 'User-Agent': c.ua } });
    if (!r.ok) { await r.body?.cancel(); return new Response('caption download failed', { status: 502 }); }
    c.body = await r.text();
  }
  return new Response(c.body, { headers: { 'Content-Type': 'text/vtt; charset=utf-8' } });
}

async function proxyHandler(req: Request): Promise<Response> {
  const path = new URL(req.url).pathname;
  const caption = path.match(/^\/c\/([\w-]+)$/)?.[1];
  if (caption) return captionResponse(caption);
  const live = path.match(/^\/l\/([\w-]+)(?:\.m3u8|\/(\d+)(?:\.ts)?)$/);
  if (live) return live[2] ? liveSegment(live[1], live[2], req.signal) : livePlaylist(live[1]);
  const master = liveMasters.get(path.match(/^\/m\/([\w-]+)\.m3u8$/)?.[1] ?? '');
  if (master) return new Response(master.body,{ headers: { 'Content-Type': 'application/vnd.apple.mpegurl' } });
  const e = proxied.get(path.match(/^\/s\/([\w-]+)$/)?.[1] ?? '');
  if (!e || !e.size) return new Response('not found', { status: 404 });
  const size = e.size;
  const range = req.headers.get('range')?.match(/bytes=(\d*)-(\d*)/);
  let start = 0, end = size - 1;
  if (range?.[1]) { start = +range[1]; if (range[2]) end = Math.min(+range[2], size - 1); }
  else if (range?.[2]) start = Math.max(0, size - +range[2]);
  if (start >= size) return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
  const status = range ? 206 : 200;
  const headers: Record<string, string> = { 'Content-Type': e.mime, 'Accept-Ranges': 'bytes', 'Content-Length': String(end - start + 1) };
  if (range) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
  if (req.method === 'HEAD') return new Response(null, { status, headers });

  // A connection to YouTube that breaks mid-chunk (sleep, Wi-Fi dropping) is picked up again from where it
  // stopped (a few times in a row), so the player only sees a pause; network errors wait up to 45 s for the
  // network (fetchChunk), within mpv's 60 s network timeout.
  let pos = start, breaks = 0;
  let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  const abort = new AbortController();
  const body = new ReadableStream<Uint8Array>({
    async pull(ctrl) {
      for (;;) {
        if (!reader) {
          if (pos > end) return ctrl.close();
          const r = await fetchChunk(`${e.url}&range=${pos}-${Math.min(pos + e.chunk - 1, end)}`, e.ua, abort.signal, 45000);
          reader = r.body!.getReader();
        }
        let chunk: ReadableStreamReadResult<Uint8Array>;
        try {
          chunk = await reader.read();
        } catch (err) {
          if (abort.signal.aborted || ++breaks > 5) throw err;
          if (debug) console.error('upstream connection broke at', pos, String(err));
          reader.cancel().catch(() => {});
          reader = null;
          continue;
        }
        if (chunk.done) { reader = null; continue; }
        breaks = 0;
        pos += chunk.value.byteLength;
        return ctrl.enqueue(chunk.value);
      }
    },
    cancel() { abort.abort(); reader?.cancel().catch(() => {}); },
  });
  return new Response(body, { status, headers });
}

// Live DVR. YouTube's live playlists list only the last hour (playlist_duration, which is signed), but
// googlevideo keeps serving the older segments of DVR streams for about 12 hours; their URLs differ only
// in /sq/. The proxy serves the playlist with those segments added in front, as short local URLs.
const LIVE_BACK_SECONDS = 12 * 3600;
// first / target: the sequence number the first playlist served started with (where the player's timeline
// begins) and the segment length, for the seek bar previews (liveTimeline)
// dash: a live DASH format (liveDashProxy) rather than an HLS playlist; head / checked: its newest segment and
// when that was asked.
type LivePlaylist = { url: string; ua: string; template: string; first: number; target: number;
                      dash?: boolean; dvr?: boolean; head?: number; checked?: number };
const livePlaylists = new Map<string, LivePlaylist>();

function liveProxy(url: string, ua: string, dash?: { target: number; dvr: boolean }) {
  const token = crypto.randomUUID();
  livePlaylists.set(token, { url, ua, template: '', first: -1, target: dash?.target ?? 0,
                             ...(dash ? { dash: true, dvr: dash.dvr, head: 0, checked: 0 } : {}) });
  // (a stream with audio of its own takes two per resolution, so room for several open streams)
  while (livePlaylists.size > 256) livePlaylists.delete(livePlaylists.keys().next().value!);
  return `http://127.0.0.1:${server.addr.port}/l/${token}.m3u8`;
}

// A live DASH format as an HLS playlist. Each segment (&sq=N) is a complete WebM / MP4 file, which mpv plays one
// after the other. The newest number is googlevideo's X-Head-Seqnum (a HEAD request, at most every half
// segment); with DVR the playlist reaches 12 h back (as for HLS), otherwise one minute.
async function dashPlaylist(token: string, e: LivePlaylist) {
  if (Date.now() - (e.checked ?? 0) > e.target * 500) {
    const r = await fetch(`${e.url}&sq=${e.head || 0}`, { method: 'HEAD', headers: { 'User-Agent': e.ua } });
    const head = Number(r.headers.get('x-head-seqnum'));
    if (!head) return new Response('playlist download failed', { status: r.ok ? 502 : r.status });
    e.head = head;
    e.checked = Date.now();
  }
  const head = e.head!;
  // with DVR from the stream's first segment (fixed: see liveFirst), else the newest minute
  if (e.dvr && e.first < 0) e.first = Math.max(0, head + 1 - Math.round(LIVE_BACK_SECONDS / e.target));
  const first = e.dvr ? Math.min(e.first, head) : Math.max(0, head + 1 - Math.round(60 / e.target));
  if (e.first < 0) e.first = first;
  const base = `http://127.0.0.1:${server.addr.port}/l/${token}/`;
  const lines = ['#EXTM3U', '#EXT-X-VERSION:3', `#EXT-X-TARGETDURATION:${e.target}`, `#EXT-X-MEDIA-SEQUENCE:${first}`];
  for (let sq = first; sq <= head; sq++) lines.push(`#EXTINF:${e.target}.0,`, `${base}${sq}`);
  return new Response(lines.join('\n') + '\n', { headers: { 'Content-Type': 'application/vnd.apple.mpegurl' } });
}

async function livePlaylist(token: string) {
  const e = livePlaylists.get(token);
  if (!e) return new Response('not found', { status: 404 });
  if (e.dash) return dashPlaylist(token, e);
  const r = await fetch(e.url, { headers: { 'User-Agent': e.ua } });
  if (!r.ok) { await r.body?.cancel(); return new Response('playlist download failed', { status: r.status }); }
  const text = await r.text();
  const out = (body: string) => new Response(body, { headers: { 'Content-Type': 'application/vnd.apple.mpegurl' } });
  const lines = text.split('\n');
  const seq = Number(/#EXT-X-MEDIA-SEQUENCE:(\d+)/.exec(text)?.[1]);
  const target = Number(/#EXT-X-TARGETDURATION:(\d+)/.exec(text)?.[1]) || 5;
  const segments = lines.filter((l) => l.startsWith('http'));
  if (!Number.isFinite(seq) || !/\/sq\/\d+\//.test(segments[0] ?? '')) return out(text);
  e.template = segments[0];
  // Older segments from the stream's first one: fixed for all its playlists (liveFirst), so the player's timeline
  // stays the same when the quality changes or the stream is opened again; without that, back to 12 h or the
  // start of the stream (sequence 0). (The playlist grows meanwhile: ~720 entries an hour.)
  if (e.first < 0) e.first = Math.max(0, seq + segments.length - Math.round(LIVE_BACK_SECONDS / target));
  if (!e.target) e.target = target;
  const extra = Math.max(0, seq - e.first);
  if (!extra) return out(text);
  let head = 0;
  while (head < lines.length && /^(#EXTM3U|#EXT-X-(VERSION|TARGETDURATION|MEDIA-SEQUENCE|DISCONTINUITY-SEQUENCE|PLAYLIST-TYPE|INDEPENDENT-SEGMENTS|ALLOW-CACHE)|\s*$)/.test(lines[head])) head++;
  const base = `http://127.0.0.1:${server.addr.port}/l/${token}/`;
  const older: string[] = [];
  for (let sq = e.first; sq < seq; sq++) older.push(`#EXTINF:${target}.0,`, `${base}${sq}.ts`);
  const header = lines.slice(0, head).map((l) => (l.startsWith('#EXT-X-MEDIA-SEQUENCE:') ? `#EXT-X-MEDIA-SEQUENCE:${e.first}` : l));
  return out([...header, ...older, ...lines.slice(head)].join('\n'));
}

async function liveSegment(token: string, sq: string, signal: AbortSignal) {
  const e = livePlaylists.get(token);
  if (!e || (!e.dash && !e.template)) return new Response('not found', { status: 404 });
  try {
    // (network errors wait up to 20 s: the player has a few segments ahead)
    const r = await fetchChunk(e.dash ? `${e.url}&sq=${sq}` : e.template.replace(/\/sq\/\d+\//, `/sq/${sq}/`), e.ua, signal, 20000);
    return new Response(r.body, { headers: { 'Content-Type': r.headers.get('content-type') ?? 'video/mp2t' } });
  } catch (err) {
    return new Response(String(err), { status: 502 });
  }
}

// Probes a byte late in the stream: URLs without a valid PO token answer the first minute and then refuse.
async function works(f: any, url: string, ua: string) {
  const at = Math.floor((Number(f.content_length) || 2) * 0.9);
  try {
    const r = await fetch(`${url}&range=${at}-${at + 1}`, { headers: { 'User-Agent': ua } });
    await r.body?.cancel();
    return r.ok;
  } catch { return false; }
}

// Live streams: one picture per segment, numbered like the segments (sheet $M = sequence number / (columns *
// rows)); which numbers the player's timeline covers comes later, from liveTimeline.
function liveStoryboard(info: any) {
  const b = info.storyboards?.type === 'PlayerLiveStoryboardSpec' ? info.storyboards.board : null;
  if (!b?.template_url?.includes('$M') || !b.columns || !b.rows) return null;
  return { live: true, template: b.template_url, width: b.thumbnail_width, height: b.thumbnail_height, columns: b.columns, rows: b.rows };
}

// For a playing live (DVR) stream's playlist URL (/m/ or /l/): the sequence number its timeline starts with and
// the segment length in seconds, once the player has loaded it (first -1 before that, or without DVR).
function liveTimeline(url: string) {
  let token = url.match(/\/m\/([\w-]+)\.m3u8$/)?.[1];
  if (token) url = liveMasters.get(token)?.video ?? '';
  token = url.match(/\/l\/([\w-]+)\.m3u8$/)?.[1] ?? '';
  const e = livePlaylists.get(token);
  return { first: e?.first ?? -1, segment: e?.target ?? 0 };
}

// SponsorBlock (sponsor.ajay.app): the community's segments of a video (sponsor reads, intros, reminders ...).
// Asked by the first 4 hex digits of the video ID's SHA-256, so the server doesn't learn which video plays; the
// answer covers every video with that prefix (~150), and this one is picked out. Segments marked for another
// length of the video (it was edited since) are left out. -> {segments: [{start, end, category, action, uuid}]}
const SB_CATEGORIES = ['sponsor', 'selfpromo', 'interaction', 'intro', 'outro', 'preview', 'music_offtopic', 'filler',
                       'poi_highlight', 'exclusive_access', 'chapter'];

async function sponsorSegments(videoId: string, duration: number) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(videoId));
  const prefix = Array.from(new Uint8Array(digest).slice(0, 2), (b) => b.toString(16).padStart(2, '0')).join('');
  const q = (v: string[]) => encodeURIComponent(JSON.stringify(v));
  const r = await fetch(`https://sponsor.ajay.app/api/skipSegments/${prefix}?categories=${q(SB_CATEGORIES)}` +
                        `&actionTypes=${q(['skip', 'mute', 'poi', 'full', 'chapter'])}`,
                        { headers: { 'User-Agent': 'FTL Player' } });
  if (r.status === 404) { await r.body?.cancel(); return { segments: [] }; }   // none for any video with that prefix
  if (!r.ok) { await r.body?.cancel(); throw new Error(`SponsorBlock HTTP ${r.status}`); }
  const mine = ((await r.json()) as any[]).find((v) => v.videoID === videoId);
  const segments = (mine?.segments ?? [])
    .filter((s: any) => !(duration > 0 && s.videoDuration > 0 && Math.abs(s.videoDuration - duration) > 2))
    .map((s: any) => ({ start: s.segment[0], end: s.segment[1], category: s.category, action: s.actionType,
                        uuid: s.UUID, description: s.description ?? '' }));
  return { segments };
}

// A video's chapters -> [{start (seconds), title}]: YouTube's own (the player bar's chapter markers, also in the
// TV client's answer), else the description's timestamps the way YouTube reads them (at least 3, the first at
// 0:00, in order: one per line, the time anywhere in it, e.g. "0:00 Intro" or "Intro - 0:00").
function chapterList(info: any) {
  const markers = info.player_overlays?.decorated_player_bar?.player_bar?.markers_map ?? [];
  const own = markers.find((m: any) => /CHAPTER/i.test(m.marker_key ?? ''))?.value?.chapters ?? [];
  if (own.length)
    return own.map((c: any) => ({ start: (Number(c.time_range_start_millis) || 0) / 1000, title: text(c.title) || String(c.title ?? '') }));
  const found: { start: number; title: string }[] = [];
  for (const line of String(info.basic_info?.short_description ?? '').split('\n')) {
    const m = line.match(/(?:^|[\s[(])((?:\d{1,2}:)?\d{1,2}:\d{2})(?=$|[\s\])])/);
    if (!m) continue;
    const start = m[1].split(':').reduce((a, p) => a * 60 + Number(p), 0);
    const title = line.replace(m[0], ' ').replace(/^[\s\-–—:|•·.)\]]+|[\s\-–—:|•·([]+$/g, '').trim();
    if (found.length && start <= found[found.length - 1].start) break;    // a second list (or not chapters)
    found.push({ start, title: title || m[1] });
  }
  return found.length >= 3 && found[0].start === 0 ? found : [];
}

// Seek bar preview pictures: YouTube's storyboard sprite sheets. The largest board up to 200 px wide is
// used (the control bar shows previews at most 200 px); boards without an interval cover the whole video.
function storyboard(info: any) {
  const boards = (info.storyboards?.boards ?? []).filter((b: any) => b.template_url?.includes('$M') && b.columns && b.rows);
  if (!boards.length) return null;
  // the sharpest board: the preview's size is a setting (Settings > Player), up to 3x the usual 200 px
  const b = boards.reduce((x: any, y: any) => (y.thumbnail_width > x.thumbnail_width ? y : x));
  const seconds = Number(info.basic_info?.duration) || 0;
  const interval = b.interval > 0 ? b.interval : (seconds * 1000) / Math.max(1, b.thumbnail_count);
  return { template: b.template_url, width: b.thumbnail_width, height: b.thumbnail_height, count: b.thumbnail_count,
           interval, columns: b.columns, rows: b.rows };
}

// Card previews (VideoCard): the storyboard from the iOS client's player response alone (~0.2 s; the web and TV
// clients' basic info has none), kept for the recent videos, so moving over a card again asks nothing.
const cardBoards = new Map<string, any>();
async function cardStoryboard(videoId: string) {
  if (cardBoards.has(videoId)) return cardBoards.get(videoId);
  const info: any = await (await yt()).getBasicInfo(videoId, { client: 'IOS' } as any);
  const board = storyboard(info);
  cardBoards.set(videoId, board);
  while (cardBoards.size > 300) cardBoards.delete(cardBoards.keys().next().value!);
  return board;
}

// The Apple Vision Pro app's client (yt-dlp's "visionos"), which youtubei.js does not know. Its live HLS
// playlists play beyond the first minute without a PO token.
const VISIONOS = {
  context: { clientName: 'VISIONOS', clientVersion: '1.02', deviceMake: 'Apple', deviceModel: 'RealityDevice17,1',
             osName: 'visionOS', osVersion: '26.5.23O471', hl: 'en', gl: 'US' },
  nameId: '101',
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
};

async function visionosHls(y: Innertube, videoId: string): Promise<{ hls: string; dvr: boolean } | null> {
  const visitorData = y.session.context.client.visitorData ?? '';
  const r = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': VISIONOS.userAgent, 'X-Goog-Visitor-Id': visitorData,
               'X-YouTube-Client-Name': VISIONOS.nameId, 'X-YouTube-Client-Version': VISIONOS.context.clientVersion },
    body: JSON.stringify({ videoId, context: { client: { ...VISIONOS.context, visitorData } }, contentCheckOk: true, racyCheckOk: true }),
  });
  if (!r.ok) return null;
  const j = await r.json();
  const hls = j.playabilityStatus?.status === 'OK' ? j.streamingData?.hlsManifestUrl : null;
  return hls ? { hls, dvr: !!j.videoDetails?.isLiveDvrEnabled } : null;
}

// Live variants with separate audio: a master playlist of one resolution and its audio playlist, served by the
// proxy, so mpv plays both together (and keeps them in sync, also when seeking back in DVR streams).
const liveMasters = new Map<string, { body: string; video: string }>();

function liveMaster(audioLine: string, streamLine: string, video: string) {
  const token = crypto.randomUUID();
  liveMasters.set(token, { body: ['#EXTM3U', '#EXT-X-INDEPENDENT-SEGMENTS', audioLine, streamLine, video, ''].join('\n'), video });
  while (liveMasters.size > 128) liveMasters.delete(liveMasters.keys().next().value!);
  return `http://127.0.0.1:${server.addr.port}/m/${token}.m3u8`;
}

// A live stream's resolutions, from its master playlist (one variant playlist per resolution, the highest
// bitrate kept when there are several). The best one up to maxHeight is played; the app switches between
// the others with the quality button. With DVR, the playlists go through the proxy, which adds the older part
// of the stream (see livePlaylist). Since October 2026 VISIONOS's variants are video only (itags 229-232,
// 269, 270) and name an audio group (AUDIO="234": its own playlist, EXT-X-MEDIA); playing just the variant had
// no sound, so those get a master playlist of their own with the audio (liveMaster).
async function liveStream(master: string, userAgent: string, maxHeight: number, dvr: boolean, dash?: LiveDash | null) {
  const qualities: { height: number; label: string; url: string; bandwidth: number; codec: string; via?: string }[] = [];
  const tokens: string[] = [];          // the proxy's playlists of this stream (liveFirst)
  const proxy = (url: string, ua: string, d?: { target: number; dvr: boolean }) => {
    const u = liveProxy(url, ua, d);
    tokens.push(u.match(/\/l\/([\w-]+)\.m3u8$/)![1]);
    return u;
  };
  const own = (url: string) => (dvr ? proxy(url, userAgent) : url);
  try {
    const r = await fetch(master, { headers: { 'User-Agent': userAgent } });
    const lines = r.ok ? (await r.text()).split('\n').map((l) => l.trim()) : [];
    const audio = new Map<string, string>();       // GROUP-ID -> its EXT-X-MEDIA line
    for (const l of lines) {
      const group = l.startsWith('#EXT-X-MEDIA:') && /TYPE=AUDIO/.test(l) ? /GROUP-ID="([^"]+)"/.exec(l)?.[1] : '';
      if (group && /URI="[^"]+"/.test(l) && !audio.has(group)) audio.set(group, l);
    }
    lines.forEach((l, i) => {
      const res = l.startsWith('#EXT-X-STREAM-INF:') ? /RESOLUTION=\d+x(\d+)/.exec(l) : null;
      const url = lines[i + 1] ?? '';
      if (!res || !url.startsWith('http')) return;
      const height = +res[1], bandwidth = +(/BANDWIDTH=(\d+)/.exec(l)?.[1] ?? 0);
      const fps = +(/FRAME-RATE=([\d.]+)/.exec(l)?.[1] ?? 0);
      const same = qualities.findIndex((q) => q.height === height);
      if (same >= 0 && qualities[same].bandwidth >= bandwidth) return;
      const audioLine = audio.get(/AUDIO="([^"]+)"/.exec(l)?.[1] ?? '');
      const play = audioLine
        ? liveMaster(audioLine.replace(/URI="([^"]+)"/, (_, u) => `URI="${own(u)}"`), l, own(url))
        : own(url);
      const q = { height, label: height + 'p' + (fps > 30 ? Math.round(fps) : ''), url: play, bandwidth, codec: 'avc1' };
      if (same >= 0) qualities[same] = q; else qualities.push(q);
    });
  } catch { /* play the master playlist */ }
  // Resolutions above the HLS ones (1440p / 2160p of 4K streams) from the live DASH formats, each with the audio
  // in a master playlist of its own (the DASH playlists always go through the proxy, which writes them).
  const hlsMax = Math.max(0, ...qualities.map((q) => q.height));
  for (const v of dash?.video ?? []) {
    if (v.height <= hlsMax) continue;
    const own = (url: string) => proxy(url, dash!.ua, { target: dash!.target, dvr });
    const audioLine = `#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="dash",NAME="Default",DEFAULT=YES,AUTOSELECT=YES,URI="${own(dash!.audio)}"`;
    const streamLine = `#EXT-X-STREAM-INF:BANDWIDTH=${v.bitrate},RESOLUTION=${v.width}x${v.height},FRAME-RATE=${v.fps},AUDIO="dash"`;
    qualities.push({ height: v.height, label: v.height + 'p' + (v.fps > 30 ? Math.round(v.fps) : ''),
                     url: liveMaster(audioLine, streamLine, own(v.url)), bandwidth: v.bitrate, codec: v.codec, via: 'TV_SIMPLY' });
  }
  if (dvr) await liveFirst(tokens);
  qualities.sort((a, b) => b.height - a.height);
  const pick = qualities.find((q) => q.height <= maxHeight) ?? qualities[qualities.length - 1];
  return { userAgent, hls: pick?.url ?? master, liveHeight: pick?.height ?? 0, liveCodec: pick?.codec ?? 'avc1', liveVia: pick?.via ?? '',
           liveQualities: qualities.map(({ height, label, url, codec, via }) => ({ height, label, url, codec, via: via ?? '' })) };
}

// One first segment for all the proxy's playlists of a DVR stream (all its formats number segments alike): 12 h
// before the newest, found once when the stream opens (one of its playlists, or googlevideo's X-Head-Seqnum).
// The player's timeline starts there in every one of them, so a quality change or opening the stream again keeps
// the position, and the seek bar previews keep their offset.
async function liveFirst(tokens: string[]) {
  for (const t of tokens) {
    const e = livePlaylists.get(t);
    if (!e) continue;
    try {
      let newest = -1, target = e.target;
      if (e.dash) {
        const r = await fetch(e.url, { method: 'HEAD', headers: { 'User-Agent': e.ua } });
        newest = Number(r.headers.get('x-head-seqnum') ?? -1);
      } else {
        const text = await (await fetch(e.url, { headers: { 'User-Agent': e.ua } })).text();
        const seq = Number(/#EXT-X-MEDIA-SEQUENCE:(\d+)/.exec(text)?.[1]);
        target = Number(/#EXT-X-TARGETDURATION:(\d+)/.exec(text)?.[1]) || 5;
        if (Number.isFinite(seq)) newest = seq + text.split('\n').filter((l) => l.startsWith('http')).length - 1;
      }
      if (!(newest >= 0) || !target) continue;
      const first = Math.max(0, newest + 1 - Math.round(LIVE_BACK_SECONDS / target));
      for (const u of tokens) {
        const p = livePlaylists.get(u);
        if (p) { p.first = first; p.target ||= target; }
      }
      return;
    } catch { /* the next playlist */ }
  }
}

// TV_SIMPLY's live adaptive (DASH) formats: one video per resolution (the codec setting first, then as for
// videos) and the best AAC audio. YouTube's live HLS stops at 1080p H.264, also for 4K streams, whose 1440p and
// 2160p (VP9) only come this way. With the PO token their segments keep loading (iOS's are refused after
// ~30 s; ANDROID's formats have no URLs).
type LiveDash = { video: { height: number; width: number; fps: number; bitrate: number; codec: string; url: string }[];
                  audio: string; ua: string; target: number };

async function liveDash(y: Innertube, info: any, ua: string, codec: string): Promise<LiveDash | null> {
  const fmts = info.streaming_data?.adaptive_formats ?? [];
  const audio = fmts.filter((f: any) => f.has_audio && !f.has_video && /mp4/.test(f.mime_type ?? ''))
    .sort((a: any, b: any) => b.bitrate - a.bitrate)[0];
  if (!audio) return null;
  const rank = (f: any) => [isCodec(f, codec) ? 1 : 0, f.fps ?? 0, CODEC_RANK[codecOf(f)] ?? 0, f.bitrate ?? 0];
  const better = (a: any, b: any) => { const x = rank(a), z = rank(b); const i = x.findIndex((v, k) => v !== z[k]); return i >= 0 && x[i] > z[i]; };
  const best = new Map<number, any>();
  for (const f of fmts)
    if (f.has_video && !f.has_audio && !isHdr(f) && (!best.has(f.height) || better(f, best.get(f.height)))) best.set(f.height, f);
  const video = await Promise.all([...best.values()].map(async (f: any) => ({
    height: f.height, width: f.width, fps: f.fps ?? 30, bitrate: f.bitrate ?? 0, codec: codecOf(f),
    url: await f.decipher(y.session.player) })));
  return { video, audio: await audio.decipher(y.session.player), ua, target: Number(audio.target_duration_sec) || 5 };
}

// Formats of recently opened videos, so the quality picker can switch without asking YouTube again.
const recent = new Map<string, { fmts: any[]; ua: string }>();

// When the video came out: the player's exact time (only some clients, e.g. MWEB, give it), else the date on the
// watch page ("Oct 25, 2009", every client), as local noon so no time zone moves it to another day. The words
// before that date ("Premiered", "Streamed live on") go in publishLabel.
function publishedOn(info: any): { publishDate: string; publishLabel: string } {
  const page = text(info.primary_info?.published);
  const m = page.match(/^(.*?)\s*([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4})$/);
  const label = m ? m[1].trim() : '';
  if (info.basic_info?.publish_date) return { publishDate: info.basic_info.publish_date, publishLabel: label };
  const d = m ? new Date(m[2] + ' 12:00') : null;
  if (!d || isNaN(d.getTime())) return { publishDate: '', publishLabel: '' };
  const p = (n: number) => String(n).padStart(2, '0');
  return { publishDate: `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T12:00:00`, publishLabel: label };
}

async function streams(videoId: string, maxHeight: number, codec = '') {
  const y = await yt();
  const errors: string[] = [];
  for (const client of CLIENTS) {
    try {
      const info: any = await y.getInfo(videoId, { client });
      const status = info.playability_status?.status;
      if (status !== 'OK') { errors.push(`${client}: ${info.playability_status?.reason ?? status}`); continue; }
      const ua = (Constants.CLIENTS as any)[client]?.USER_AGENT ?? DESKTOP_UA;
      const meta = {
        title: text(info.basic_info?.title),
        channel: info.basic_info?.author ?? '',
        channelId: info.basic_info?.channel_id ?? '',
        views: info.basic_info?.view_count ?? null,
        likes: Number(info.basic_info?.like_count) || 0,     // (0: hidden by the channel, or not given)
        // the channel's picture (watch page; ANDROID_VR has none), 88 px if offered
        channelThumbnail: (() => {
          const ts: any[] = info.secondary_info?.owner?.author?.thumbnails ?? [];
          const t = ts.find((t) => t.width >= 88 && t.width < 176) ?? ts[0];
          return t?.url ? (t.url.startsWith('//') ? 'https:' + t.url : t.url) : '';
        })(),
        live: !!info.basic_info?.is_live,
        // the description shown under the player (plain text) and the publish date ("2009-10-24T23:57:33-07:00")
        description: info.basic_info?.short_description ?? '',
        ...publishedOn(info),
        lengthSeconds: Number(info.basic_info?.duration) || 0,    // (SponsorBlock checks its segments against it)
        client,
        userAgent: ua,
        poToken: hasPoToken,
      };
      const sd = info.streaming_data;
      // Live: HLS playlist. VISIONOS's playlists keep delivering segments; ANDROID_VR's (the fallback) are
      // refused after about 30 s since August 2026. HLS live needs no PO token (except on iOS).
      if (meta.live) {
        const [vision, dash] = await Promise.all([visionosHls(y, videoId).catch(() => null),
          client === 'TV_SIMPLY' && hasPoToken ? liveDash(y, info, ua, codec).catch(() => null) : null]);
        if (vision) return { ...meta, ...(await liveStream(vision.hls, VISIONOS.userAgent, maxHeight, vision.dvr, dash)),
                             client: 'VISIONOS', storyboard: liveStoryboard(info) };
        let hls = sd?.hls_manifest_url, via = client;
        if (client !== 'ANDROID_VR') {
          const vr: any = await y.getInfo(videoId, { client: 'ANDROID_VR' }).catch(() => null);
          if (vr?.streaming_data?.hls_manifest_url) { hls = vr.streaming_data.hls_manifest_url; via = 'ANDROID_VR'; }
        }
        if (hls) {
          const ua = (Constants.CLIENTS as any)[via]?.USER_AGENT ?? DESKTOP_UA;
          return { ...meta, ...(await liveStream(hls, ua, maxHeight, false)), client: via, storyboard: liveStoryboard(info) };
        }
      }
      const fmts = sd?.adaptive_formats ?? [];
      const v = pickVideo(fmts, maxHeight, codec), a = pickAudio(fmts);
      if (!v || !a) { errors.push(`${client}: no formats`); continue; }
      const [vu, au] = await Promise.all([v.decipher(y.session.player), a.decipher(y.session.player)]);
      const ok = await Promise.all([works(v, vu, ua), works(a, au, ua)]);
      if (!ok[0] || !ok[1]) { errors.push(`${client}: stream URL refused`); continue; }
      recent.set(videoId, { fmts, ua });
      while (recent.size > 8) recent.delete(recent.keys().next().value!);
      return {
        ...meta,
        video: videoInfo(v, vu, ua),
        audio: audioInfo(a, au, ua),
        qualities: qualityList(fmts, codec),
        audioTracks: audioTrackList(fmts),
        captions: captionList(info, ua),
        storyboard: storyboard(info),
        chapters: chapterList(info),
      };
    } catch (e) {
      errors.push(`${client}: ${String((e as Error)?.message ?? e).slice(0, 200)}`);
    }
  }
  // When every client gives the same reason (e.g. "Premieres in 47 hours"), that reason is the message.
  const reasons = new Set(errors.map((e) => e.replace(/^\w+: /, '')));
  if (reasons.size === 1) throw new Error([...reasons][0]);
  throw new Error('No playable streams. ' + errors.join(' | '));
}

const handlers: Record<string, (r: any) => Promise<unknown>> = {
  ping: async () => ({ pong: true }),
  liveTimeline: async (r) => liveTimeline(String(r.url ?? '')),
  sponsorSegments: async (r) => sponsorSegments(String(r.videoId ?? ''), Number(r.duration) || 0),
  search: async (r) => search(r),
  searchMore: async () => {
    if (!lastSearch?.has_continuation) return { results: [], kind: lastSearchType, more: false };
    return searchPage(await lastSearch.getContinuation());
  },
  streams: async (r) => streams(String(r.videoId), Number(r.maxHeight) || 1080, String(r.codec ?? '')),
  // Another format of a video opened with "streams": {videoId, itag} -> {video} or {audio}
  format: async (r) => {
    const known = recent.get(String(r.videoId));
    const f = known?.fmts.find((x) => x.itag === Number(r.itag)
      && (r.track === undefined || (x.audio_track?.id ?? 'main') === r.track));
    if (!known || !f) throw new Error('This video needs to be reopened to change this.');
    const url = await f.decipher((await yt()).session.player);
    return f.has_video ? { video: videoInfo(f, url, known.ua) } : { audio: audioInfo(f, url, known.ua) };
  },
  // A video's seek-bar storyboard alone, for previews on the video cards: {videoId} -> {board} (null: none)
  cardStoryboard: async (r) => ({ board: await cardStoryboard(String(r.videoId)) }),
  // Latest videos of a channel tab: {channelId, tab: 'videos' | 'streams'} -> {items}
  channelTab: async (r) => channelTab(String(r.channelId), String(r.tab ?? 'videos')),
  // A channel link without its ID (youtube.com/@handle, /c/name, /user/name), pasted into the search field
  // (InnerTube's resolve_url: the browse endpoint it points to holds the channel ID)
  resolveChannel: async (r) => {
    const raw: any = await (await yt()).actions.execute('/navigation/resolve_url', { url: String(r.url ?? '') });
    const id = raw?.data?.endpoint?.browseEndpoint?.browseId ?? '';
    if (!/^UC[\w-]{22}$/.test(id)) throw new Error('not a channel link');
    return { channelId: id };   // (not "id": the reply's id is the request's)
  },
  // {channelId, tab} -> {info, items, continuation}; {continuation} -> {items, continuation}
  channelPage: async (r) => channelPage(r),
  // {channelId} -> {items, channel}: latest uploads from the channel's RSS feed
  rssFeed: async (r) => rssFeed(String(r.channelId)),
  playlist: async (r) => playlist(r),
  comments: async (r) => comments(r),
  videoStates: async (r) => videoStates(r),
  replies: async (r) => replies(r),
  setBrowseRate: async (r) => { browseRate = Math.max(1, Number(r.rate) || 8); return { rate: browseRate }; }, // testing
};

async function handle(line: string) {
  let req: any;
  try { req = JSON.parse(line); } catch { return; }
  const h = handlers[req.cmd];
  if (!h) return out({ id: req.id, ok: false, error: `unknown command ${req.cmd}` });
  try { out({ id: req.id, ok: true, ...(await h(req) as object) }); }
  catch (e) { out({ id: req.id, ok: false, error: String((e as Error)?.message ?? e) }); }
}

yt().catch(() => {}); // warm up the session while the UI starts
let buf = '';
const dec = new TextDecoder();
for await (const chunk of Deno.stdin.readable) {
  buf += dec.decode(chunk, { stream: true });
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (line) handle(line);
  }
}
worker.terminate();
Deno.exit(0);
