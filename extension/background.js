// Open in FTL Player: hands YouTube links to the app through ftlplayer://<link>, which the app registers
// for itself when it starts (main.cpp). A running app opens the link in its window; otherwise it starts with it.

// Links the app opens (see openLink in Main.qml): watch, youtu.be, shorts, live, embed, playlist, channel.
const LINK_PATTERNS = [
  '*://*.youtube.com/watch*',
  '*://*.youtube.com/shorts/*',
  '*://*.youtube.com/live/*',
  '*://*.youtube.com/embed/*',
  '*://*.youtube.com/playlist*',
  '*://*.youtube.com/channel/*',
  '*://*.youtube.com/@*',
  '*://*.youtube-nocookie.com/embed/*',
  '*://youtu.be/*',
];

// Pages (or embedded players) where "this video" means the one playing there.
const VIDEO_PAGE_PATTERNS = [
  '*://*.youtube.com/watch*',
  '*://*.youtube.com/shorts/*',
  '*://*.youtube.com/live/*',
  '*://*.youtube.com/embed/*',
  '*://*.youtube-nocookie.com/embed/*',
];

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: 'open-link',
      title: 'Open in FTL Player',
      contexts: ['link'],
      targetUrlPatterns: LINK_PATTERNS,
    });
    chrome.contextMenus.create({
      id: 'open-current',
      title: 'Open this video in FTL Player',
      contexts: ['page', 'video', 'frame'],
      documentUrlPatterns: VIDEO_PAGE_PATTERNS,
    });
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab?.id) return;
  if (info.menuItemId === 'open-link') {
    // A link's own timestamp (e.g. &t=754s from a comment or "continue watching") is kept as it is.
    openInFtlPlayer(tab.id, info.linkUrl);
  } else if (info.menuItemId === 'open-current') {
    openInFtlPlayer(tab.id, await currentVideoUrl(tab.id, info.frameId ?? 0, info.frameUrl || info.pageUrl));
  }
});

// The toolbar button: the video on this page (or just the page's link, e.g. a playlist or channel).
chrome.action.onClicked.addListener(async (tab) => {
  if (!tab?.id || !tab.url || !/^https?:\/\/([\w-]+\.)?(youtube\.com|youtu\.be|youtube-nocookie\.com)\//i.test(tab.url)) return;
  const isVideoPage = /^\/(watch|shorts\/|live\/|embed\/)/.test(new URL(tab.url).pathname);
  openInFtlPlayer(tab.id, isVideoPage ? await currentVideoUrl(tab.id, 0, tab.url) : tab.url);
});

// Reads the playback position from the page (or embedded player), pauses the browser's copy so it doesn't keep
// playing alongside the app, and returns the video's URL with t=<seconds>s (not for live streams).
async function currentVideoUrl(tabId, frameId, fallbackUrl) {
  try {
    const [{ result }] = await chrome.scripting.executeScript({
      target: { tabId, frameIds: [frameId] },
      world: 'MAIN',
      func: () => {
        const videos = [...document.querySelectorAll('video')];
        const video = videos.find((v) => !v.paused) ?? document.querySelector('#movie_player video') ?? videos[0];
        const isLive = document.getElementById('movie_player')?.getVideoData?.().isLive ?? false;
        const seconds = video && !isLive ? Math.floor(video.currentTime) : 0;
        video?.pause();
        return { href: location.href, seconds };
      },
    });
    const url = new URL(result.href);
    if (result.seconds >= 1) url.searchParams.set('t', `${result.seconds}s`);
    else url.searchParams.delete('t');
    return url.href;
  } catch (err) {
    console.warn('Open in FTL Player: could not read the playback position, opening without a timestamp.', err);
    return fallbackUrl;
  }
}

function openInFtlPlayer(tabId, youtubeUrl) {
  // The browser hands ftlplayer:// over to the app without leaving the page (it asks the first time).
  chrome.tabs.update(tabId, { url: `ftlplayer://${youtubeUrl}` });
}
