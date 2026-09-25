import express, { Request, Response } from 'express';
import http from 'http';
import https from 'https';
import { URL } from 'url';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';
import zlib from 'zlib';
import JSZip from 'jszip';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = Number(process.env.PORT) || 3000;

app.use(express.json({ limit: '50mb' }));

const USER_AGENTS = [
  'IPTVSmartersPro/3.1.5.1 (Linux; Android 12; Fire TV)',
  'VLC/3.0.20 LibVLC/3.0.20',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  'AppleCoreMedia/1.0.0.20K5350a (Apple TV; U; CPU OS 16_5 like Mac OS X; en_us)'
];

// Helper to decompress buffer based on content-encoding
function decompressIfNeeded(buffer: Buffer, encoding?: string): Buffer {
  if (!encoding) return buffer;
  const enc = encoding.toLowerCase().trim();
  try {
    if (enc.includes('gzip')) {
      return zlib.gunzipSync(buffer);
    } else if (enc.includes('deflate')) {
      return zlib.inflateSync(buffer);
    } else if (enc.includes('br')) {
      return zlib.brotliDecompressSync(buffer);
    }
  } catch (e) {
    // If decompression fails, return original buffer
    return buffer;
  }
  return buffer;
}

// Resilient helper to fetch remote URLs with redirects, retries, and ECONNRESET mitigation
async function fetchWithRedirects(
  targetUrl: string,
  options: { timeout?: number; headers?: Record<string, string>; method?: string; retryCount?: number } = {},
  maxRedirects = 6
): Promise<{ status: number; headers: http.IncomingHttpHeaders; data: Buffer; finalUrl: string }> {
  if (maxRedirects < 0) {
    throw new Error('Too many HTTP redirects');
  }

  const attempt = options.retryCount || 0;
  const userAgent = USER_AGENTS[attempt % USER_AGENTS.length];

  return new Promise(async (resolve, reject) => {
    let parsedUrl: URL;
    try {
      parsedUrl = new URL(targetUrl);
    } catch {
      return reject(new Error('Invalid URL provided: ' + targetUrl));
    }

    const isHttps = parsedUrl.protocol === 'https:';
    const client = isHttps ? https : http;

    const reqHeaders: Record<string, string> = {
      'User-Agent': userAgent,
      'Accept': '*/*',
      'Accept-Encoding': 'gzip, deflate',
      'Connection': attempt > 0 ? 'close' : 'keep-alive',
      ...(options.headers || {})
    };

    const req = client.request(
      parsedUrl,
      {
        method: options.method || 'GET',
        headers: reqHeaders,
        timeout: options.timeout || 25000,
        rejectUnauthorized: false, // Allow self-signed or legacy IPTV SSL certs
        agent: attempt > 0 ? false : undefined // Disable agent socket reuse on retry
      },
      (res) => {
        // Handle 3xx redirects
        if (
          res.statusCode &&
          [301, 302, 303, 307, 308].includes(res.statusCode) &&
          res.headers.location
        ) {
          const redirectUrl = new URL(res.headers.location, targetUrl).toString();
          return resolve(fetchWithRedirects(redirectUrl, options, maxRedirects - 1));
        }

        const chunks: Buffer[] = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const rawData = Buffer.concat(chunks);
          const decompressed = decompressIfNeeded(rawData, res.headers['content-encoding']);
          resolve({
            status: res.statusCode || 200,
            headers: res.headers,
            data: decompressed,
            finalUrl: targetUrl
          });
        });
        res.on('error', async (err: any) => {
          if (attempt < 2 && (err.code === 'ECONNRESET' || err.code === 'EPIPE' || err.code === 'ETIMEDOUT')) {
            await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
            try {
              const retryRes = await fetchWithRedirects(targetUrl, { ...options, retryCount: attempt + 1 }, maxRedirects);
              return resolve(retryRes);
            } catch (retryErr) {
              return reject(retryErr);
            }
          }
          reject(err);
        });
      }
    );

    req.on('timeout', () => {
      req.destroy(new Error('Request timed out after 25s'));
    });

    req.on('error', async (err: any) => {
      if (attempt < 2 && (err.code === 'ECONNRESET' || err.code === 'EPIPE' || err.code === 'ETIMEDOUT' || err.code === 'ECONNREFUSED')) {
        await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
        try {
          const retryRes = await fetchWithRedirects(targetUrl, { ...options, retryCount: attempt + 1 }, maxRedirects);
          return resolve(retryRes);
        } catch (retryErr) {
          return reject(retryErr);
        }
      }
      reject(err);
    });

    req.end();
  });
}

// 1. Proxy M3U Playlist Endpoint (bypasses browser CORS & mixed-content)
app.get('/api/proxy-playlist', async (req: Request, res: Response) => {
  const urlParam = req.query.url as string;
  if (!urlParam) {
    return res.status(400).json({ error: 'Missing ?url= query parameter' });
  }

  try {
    const remote = await fetchWithRedirects(urlParam);
    if (remote.status >= 400) {
      return res.status(remote.status).json({
        error: `Remote server returned HTTP status ${remote.status}`
      });
    }

    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    return res.send(remote.data);
  } catch (err: any) {
    console.error('Error in /api/proxy-playlist:', err);
    return res.status(500).json({
      error: `Failed to fetch remote playlist: ${err.message || String(err)}`
    });
  }
});

// Helper to sanitize Xtream base URL
function sanitizeServerUrl(rawUrl: string): string {
  let clean = rawUrl.trim();
  if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
    clean = 'http://' + clean;
  }
  return clean.replace(/\/+$/, '');
}

// 2. Xtream Codes Authentication Endpoint
app.post('/api/xtream/authenticate', async (req: Request, res: Response) => {
  const { serverUrl, username, password } = req.body;
  if (!serverUrl || !username || !password) {
    return res.status(400).json({ error: 'Server URL, username, and password are required' });
  }

  const base = sanitizeServerUrl(serverUrl);
  const authUrl = `${base}/player_api.php?username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`;

  try {
    const remote = await fetchWithRedirects(authUrl);
    const text = remote.data.toString('utf8');
    let json: any;
    try {
      json = JSON.parse(text);
    } catch {
      return res.status(502).json({
        error: 'Invalid response from Xtream server. Expected JSON from player_api.php.'
      });
    }

    if (json.user_info) {
      const authSuccess = json.user_info.auth === 1 || json.user_info.status === 'Active';
      return res.json({
        success: authSuccess,
        userInfo: json.user_info,
        serverInfo: json.server_info,
        serverUrl: base
      });
    } else {
      return res.status(401).json({
        error: 'Authentication failed. Please verify your Xtream server, username, and password.',
        raw: json
      });
    }
  } catch (err: any) {
    console.error('Error in /api/xtream/authenticate:', err);
    return res.status(500).json({
      error: `Connection to Xtream Codes server failed: ${err.message || String(err)}`
    });
  }
});

// 3. Xtream Codes Channels Endpoint (Categorizes Live TV, Movies, and TV Shows)
app.post('/api/xtream/channels', async (req: Request, res: Response) => {
  const { serverUrl, username, password, section } = req.body;
  if (!serverUrl || !username || !password) {
    return res.status(400).json({ error: 'Server URL, username, and password are required' });
  }

  const base = sanitizeServerUrl(serverUrl);
  const userEnc = encodeURIComponent(username);
  const passEnc = encodeURIComponent(password);

  try {
    const allChannels: any[] = [];
    const counts = { live: 0, movie: 0, series: 0 };

    // SECTION A: LIVE TV
    try {
      const liveCatUrl = `${base}/player_api.php?username=${userEnc}&password=${passEnc}&action=get_live_categories`;
      const liveStreamUrl = `${base}/player_api.php?username=${userEnc}&password=${passEnc}&action=get_live_streams`;

      const [liveCatRes, liveStreamRes] = await Promise.all([
        fetchWithRedirects(liveCatUrl).catch(() => null),
        fetchWithRedirects(liveStreamUrl).catch(() => null)
      ]);

      const liveCatMap: Record<string, string> = {};
      if (liveCatRes && liveCatRes.status === 200) {
        try {
          const catJson = JSON.parse(liveCatRes.data.toString('utf8'));
          if (Array.isArray(catJson)) {
            catJson.forEach((c: any) => {
              if (c.category_id && c.category_name) {
                liveCatMap[String(c.category_id)] = c.category_name;
              }
            });
          }
        } catch (e) {
          console.warn('Could not parse live categories JSON', e);
        }
      }

      if (liveStreamRes && liveStreamRes.status === 200) {
        const liveStreamsJson = JSON.parse(liveStreamRes.data.toString('utf8'));
        if (Array.isArray(liveStreamsJson)) {
          liveStreamsJson.forEach((s: any) => {
            const streamId = s.stream_id;
            const catName = liveCatMap[String(s.category_id)] || 'Live Channels';
            const m3u8Url = `${base}/live/${userEnc}/${passEnc}/${streamId}.m3u8`;

            allChannels.push({
              id: `xtream-live-${streamId}`,
              name: s.name || `Live Stream #${streamId}`,
              groupTitle: catName,
              logoURL: s.stream_icon || undefined,
              streamURL: m3u8Url,
              tvgID: s.epg_channel_id || undefined,
              tvgName: s.name || undefined,
              contentType: 'live'
            });
            counts.live++;
          });
        }
      }
    } catch (e) {
      console.warn('Error fetching Xtream live streams:', e);
    }

    // SECTION B: MOVIES (VOD)
    try {
      const vodCatUrl = `${base}/player_api.php?username=${userEnc}&password=${passEnc}&action=get_vod_categories`;
      const vodStreamUrl = `${base}/player_api.php?username=${userEnc}&password=${passEnc}&action=get_vod_streams`;

      const [vodCatRes, vodStreamRes] = await Promise.all([
        fetchWithRedirects(vodCatUrl).catch(() => null),
        fetchWithRedirects(vodStreamUrl).catch(() => null)
      ]);

      const vodCatMap: Record<string, string> = {};
      if (vodCatRes && vodCatRes.status === 200) {
        try {
          const catJson = JSON.parse(vodCatRes.data.toString('utf8'));
          if (Array.isArray(catJson)) {
            catJson.forEach((c: any) => {
              if (c.category_id && c.category_name) {
                vodCatMap[String(c.category_id)] = c.category_name;
              }
            });
          }
        } catch (e) {
          console.warn('Could not parse VOD categories JSON', e);
        }
      }

      if (vodStreamRes && vodStreamRes.status === 200) {
        const vodStreamsJson = JSON.parse(vodStreamRes.data.toString('utf8'));
        if (Array.isArray(vodStreamsJson)) {
          vodStreamsJson.forEach((s: any) => {
            const streamId = s.stream_id;
            const ext = s.container_extension || 'mp4';
            const catName = vodCatMap[String(s.category_id)] || 'Movies';
            const movieUrl = `${base}/movie/${userEnc}/${passEnc}/${streamId}.${ext}`;

            allChannels.push({
              id: `xtream-movie-${streamId}`,
              name: s.name || `Movie #${streamId}`,
              groupTitle: catName,
              logoURL: s.stream_icon || undefined,
              streamURL: movieUrl,
              contentType: 'movie'
            });
            counts.movie++;
          });
        }
      }
    } catch (e) {
      console.warn('Error fetching Xtream VOD streams:', e);
    }

    // SECTION C: TV SHOWS (SERIES)
    try {
      const seriesCatUrl = `${base}/player_api.php?username=${userEnc}&password=${passEnc}&action=get_series_categories`;
      const seriesStreamUrl = `${base}/player_api.php?username=${userEnc}&password=${passEnc}&action=get_series`;

      const [seriesCatRes, seriesStreamRes] = await Promise.all([
        fetchWithRedirects(seriesCatUrl).catch(() => null),
        fetchWithRedirects(seriesStreamUrl).catch(() => null)
      ]);

      const seriesCatMap: Record<string, string> = {};
      if (seriesCatRes && seriesCatRes.status === 200) {
        try {
          const catJson = JSON.parse(seriesCatRes.data.toString('utf8'));
          if (Array.isArray(catJson)) {
            catJson.forEach((c: any) => {
              if (c.category_id && c.category_name) {
                seriesCatMap[String(c.category_id)] = c.category_name;
              }
            });
          }
        } catch (e) {
          console.warn('Could not parse series categories JSON', e);
        }
      }

      if (seriesStreamRes && seriesStreamRes.status === 200) {
        const seriesJson = JSON.parse(seriesStreamRes.data.toString('utf8'));
        if (Array.isArray(seriesJson)) {
          seriesJson.forEach((s: any) => {
            const seriesId = s.series_id;
            const catName = seriesCatMap[String(s.category_id)] || 'TV Series';
            // Series stream or direct link
            const seriesUrl = `${base}/series/${userEnc}/${passEnc}/${seriesId}.mp4`;

            allChannels.push({
              id: `xtream-series-${seriesId}`,
              name: s.name || `Series #${seriesId}`,
              groupTitle: catName,
              logoURL: s.cover || s.stream_icon || undefined,
              streamURL: seriesUrl,
              contentType: 'series'
            });
            counts.series++;
          });
        }
      }
    } catch (e) {
      console.warn('Error fetching Xtream TV Shows:', e);
    }

    return res.json({
      success: true,
      totalChannels: allChannels.length,
      counts,
      channels: allChannels,
      serverUrl: base,
      directM3UUrl: `${base}/get.php?username=${userEnc}&password=${passEnc}&type=m3u_plus&output=m3u8`
    });
  } catch (err: any) {
    console.error('Error in /api/xtream/channels:', err);
    return res.status(500).json({
      error: `Failed to fetch Xtream live streams: ${err.message || String(err)}`
    });
  }
});

// 3b. Xtream Codes Series Info (Seasons & Episodes) Endpoint
app.post('/api/xtream/series-info', async (req: Request, res: Response) => {
  const { serverUrl, username, password, seriesId } = req.body;
  if (!serverUrl || !username || !password || !seriesId) {
    return res.status(400).json({ error: 'Server URL, username, password, and seriesId are required' });
  }

  const base = sanitizeServerUrl(serverUrl);
  const userEnc = encodeURIComponent(username);
  const passEnc = encodeURIComponent(password);
  const infoUrl = `${base}/player_api.php?username=${userEnc}&password=${passEnc}&action=get_series_info&series_id=${encodeURIComponent(seriesId)}`;

  try {
    const remote = await fetchWithRedirects(infoUrl, { timeout: 15000 });
    const json = JSON.parse(remote.data.toString('utf8'));
    return res.json(json);
  } catch (err: any) {
    return res.status(500).json({ error: `Failed to fetch series episodes: ${err.message}` });
  }
});

// 3c. Xtream Codes Live TV EPG / Program Schedule Endpoint
app.post('/api/xtream/epg', async (req: Request, res: Response) => {
  const { serverUrl, username, password, streamId } = req.body;
  if (!serverUrl || !username || !password || !streamId) {
    return res.status(400).json({ error: 'Server URL, username, password, and streamId are required' });
  }

  const base = sanitizeServerUrl(serverUrl);
  const userEnc = encodeURIComponent(username);
  const passEnc = encodeURIComponent(password);
  const epgUrl = `${base}/player_api.php?username=${userEnc}&password=${passEnc}&action=get_short_epg&stream_id=${encodeURIComponent(streamId)}&limit=10`;

  try {
    const remote = await fetchWithRedirects(epgUrl, { timeout: 8000 });
    const json = JSON.parse(remote.data.toString('utf8'));
    return res.json(json);
  } catch (err: any) {
    return res.status(200).json({ epg_listings: [], error: err.message });
  }
});

// Helper: Rewrites all URI references inside an M3U8 manifest so every chunk, key,
// and sub-manifest is requested through /api/proxy-stream over HTTPS, completely
// preventing "Mixed Content: The content must be served over HTTPS" in browsers!
function rewriteM3U8Manifest(manifestText: string, baseUrl: string): string {
  const lines = manifestText.split(/\r?\n/);
  const rewritten: string[] = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) {
      rewritten.push(line);
      continue;
    }

    // Rewrite encryption keys or audio maps: #EXT-X-KEY:METHOD=...,URI="..."
    if (trimmed.startsWith('#EXT-X-KEY:') || trimmed.startsWith('#EXT-X-MAP:')) {
      const rewrittenTag = trimmed.replace(/URI=["']([^"']+)["']/g, (_match, uri) => {
        try {
          const resolvedUri = new URL(uri, baseUrl).toString();
          return `URI="/api/proxy-stream?url=${encodeURIComponent(resolvedUri)}"`;
        } catch {
          return _match;
        }
      });
      rewritten.push(rewrittenTag);
      continue;
    }

    // Comment tags or directives
    if (trimmed.startsWith('#')) {
      rewritten.push(line);
      continue;
    }

    // Segment or child playlist URI: resolve relative or absolute URL
    try {
      const resolvedSegment = new URL(trimmed, baseUrl).toString();
      rewritten.push(`/api/proxy-stream?url=${encodeURIComponent(resolvedSegment)}`);
    } catch {
      rewritten.push(line);
    }
  }

  return rewritten.join('\n');
}

// 4. Media Stream Proxy: solves HTTPS Mixed Content by streaming & rewriting manifests, and handles MP4 VOD seeking
app.all('/api/proxy-stream', async (req: Request, res: Response) => {
  // CORS Preflight handling
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Expose-Headers', 'Content-Length, Content-Range, Accept-Ranges, Content-Type');

  if (req.method === 'OPTIONS') {
    return res.sendStatus(204);
  }

  const target = req.query.url as string;
  if (!target) {
    return res.status(400).send('Missing ?url= parameter');
  }

  let parsed: URL;
  try {
    parsed = new URL(target);
  } catch {
    return res.status(400).send('Invalid url parameter');
  }

  const reqHeaders: Record<string, string> = {
    'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
    'Accept': '*/*'
  };

  // Forward Range header for MP4 seeking and progressive playback
  if (req.headers.range) {
    reqHeaders['Range'] = req.headers.range;
  }

  const doRequest = (currentUrl: string, redirectCount = 5) => {
    if (redirectCount < 0) {
      if (!res.headersSent) res.status(502).send('Too many redirects');
      return;
    }

    let curParsed: URL;
    try {
      curParsed = new URL(currentUrl);
    } catch {
      if (!res.headersSent) res.status(400).send('Malformed URL in redirect');
      return;
    }

    const curClient = curParsed.protocol === 'https:' ? https : http;

    const proxyReq = curClient.request(
      curParsed,
      {
        method: req.method === 'HEAD' ? 'HEAD' : 'GET',
        headers: reqHeaders,
        rejectUnauthorized: false
      },
      async (remoteRes) => {
        // Handle 3xx Redirects
        if (
          remoteRes.statusCode &&
          [301, 302, 303, 307, 308].includes(remoteRes.statusCode) &&
          remoteRes.headers.location
        ) {
          const nextUrl = new URL(remoteRes.headers.location, currentUrl).toString();
          return doRequest(nextUrl, redirectCount - 1);
        }

        // Automatic Xtream Series Resolution:
        // If an Xtream series endpoint /series/user/pass/{series_id}.mp4 fails with 404 or 400+,
        // resolve the first episode ID via player_api.php?action=get_series_info
        const seriesMatch = currentUrl.match(/\/series\/([^/]+)\/([^/]+)\/(\d+)\.mp4/);
        if (remoteRes.statusCode && remoteRes.statusCode >= 400 && seriesMatch) {
          try {
            const user = decodeURIComponent(seriesMatch[1]);
            const pass = decodeURIComponent(seriesMatch[2]);
            const seriesId = seriesMatch[3];
            const infoUrl = `${curParsed.protocol}//${curParsed.host}/player_api.php?username=${encodeURIComponent(user)}&password=${encodeURIComponent(pass)}&action=get_series_info&series_id=${seriesId}`;
            const infoRes = await fetchWithRedirects(infoUrl, { timeout: 10000 });
            if (infoRes.status === 200) {
              const infoJson = JSON.parse(infoRes.data.toString('utf8'));
              if (infoJson.episodes) {
                const seasonKeys = Object.keys(infoJson.episodes).sort((a, b) => Number(a) - Number(b));
                if (seasonKeys.length > 0) {
                  const firstSeason = infoJson.episodes[seasonKeys[0]];
                  if (Array.isArray(firstSeason) && firstSeason.length > 0) {
                    const firstEp = firstSeason[0];
                    const epId = firstEp.id;
                    const ext = firstEp.container_extension || 'mp4';
                    const resolvedEpUrl = `${curParsed.protocol}//${curParsed.host}/series/${encodeURIComponent(user)}/${encodeURIComponent(pass)}/${epId}.${ext}`;
                    return doRequest(resolvedEpUrl, redirectCount - 1);
                  }
                }
              }
            }
          } catch (seriesErr) {
            console.warn('Series auto-resolution attempt failed:', seriesErr);
          }
        }

        // Automatic Xtream Movie Extension Fallback:
        // If /movie/user/pass/{id}.mp4 returns 404, try .mkv (or vice-versa)
        const movieMatch = currentUrl.match(/\/movie\/([^/]+)\/([^/]+)\/(\d+)\.(mp4|mkv|avi)/i);
        if (remoteRes.statusCode && remoteRes.statusCode >= 400 && movieMatch && redirectCount > 1) {
          const user = decodeURIComponent(movieMatch[1]);
          const pass = decodeURIComponent(movieMatch[2]);
          const vodId = movieMatch[3];
          const curExt = movieMatch[4].toLowerCase();
          const targetExt = curExt === 'mp4' ? 'mkv' : 'mp4';
          const fallbackVodUrl = `${curParsed.protocol}//${curParsed.host}/movie/${encodeURIComponent(user)}/${encodeURIComponent(pass)}/${vodId}.${targetExt}`;
          return doRequest(fallbackVodUrl, redirectCount - 1);
        }

        const statusCode = remoteRes.statusCode || 200;
        const rawContentType = remoteRes.headers['content-type'] || '';
        const isM3U8 =
          currentUrl.toLowerCase().includes('.m3u8') ||
          rawContentType.includes('mpegurl') ||
          rawContentType.includes('application/x-mpegurl');

        res.setHeader('Access-Control-Allow-Origin', '*');
        res.setHeader('Access-Control-Allow-Headers', '*');
        res.setHeader('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');

        if (isM3U8) {
          // Buffer and rewrite HLS manifest for HTTPS
          const chunks: Buffer[] = [];
          remoteRes.on('data', (c) => chunks.push(c));
          remoteRes.on('end', () => {
            const rawBody = Buffer.concat(chunks).toString('utf8');
            const rewritten = rewriteM3U8Manifest(rawBody, currentUrl);
            res.status(statusCode);
            res.setHeader('Content-Type', 'application/vnd.apple.mpegurl; charset=utf-8');
            res.setHeader('Cache-Control', 'no-cache');
            res.send(rewritten);
          });
        } else {
          // Direct MP4 / TS Video Streaming
          // Determine accurate content-type: ensure MP4 is explicitly video/mp4
          let finalContentType = rawContentType;
          const isMp4 =
            currentUrl.toLowerCase().includes('.mp4') ||
            target.toLowerCase().includes('.mp4') ||
            rawContentType.includes('mp4') ||
            !rawContentType ||
            rawContentType === 'application/octet-stream';

          if (isMp4) {
            finalContentType = 'video/mp4';
          }

          res.status(statusCode);
          res.setHeader('Content-Type', finalContentType);
          res.setHeader('Accept-Ranges', 'bytes');

          if (remoteRes.headers['content-length']) {
            res.setHeader('Content-Length', remoteRes.headers['content-length']);
          }
          if (remoteRes.headers['content-range']) {
            res.setHeader('Content-Range', remoteRes.headers['content-range']);
          }

          if (req.method === 'HEAD') {
            return res.end();
          }

          remoteRes.on('error', (streamErr) => {
            console.warn('Upstream media stream error:', streamErr.message);
            if (!res.headersSent) {
              res.status(502).send(`Stream read error: ${streamErr.message}`);
            } else {
              res.end();
            }
          });

          remoteRes.pipe(res);
        }
      }
    );

    proxyReq.on('error', (err) => {
      console.error('Proxy stream request error:', err);
      if (!res.headersSent) {
        res.status(502).send(`Stream proxy error: ${err.message}`);
      }
    });

    req.on('close', () => {
      proxyReq.destroy();
    });

    proxyReq.end();
  };

  doRequest(target);
});

// 5. Image Proxy to prevent mixed-content blocks on HTTP channel logos
app.get('/api/proxy-image', async (req: Request, res: Response) => {
  const target = req.query.url as string;
  if (!target) return res.status(400).send('Missing url');

  try {
    const remote = await fetchWithRedirects(target, { timeout: 10000 });
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Cache-Control', 'public, max-age=86400');
    if (remote.headers['content-type']) {
      res.setHeader('Content-Type', remote.headers['content-type']);
    }
    return res.status(remote.status).send(remote.data);
  } catch {
    return res.status(404).send('Image fetch failed');
  }
});

// 6. Direct server-side zip download: ensures fresh source code without browser cache
app.get('/api/download-zip', async (_req: Request, res: Response) => {
  try {
    const zip = new JSZip();
    const folder = zip.folder('EasyIPTV');
    const swiftDir = path.join(__dirname, 'swift-sources');

    if (fs.existsSync(swiftDir)) {
      const files = fs.readdirSync(swiftDir);
      for (const file of files) {
        const filePath = path.join(swiftDir, file);
        const stat = fs.statSync(filePath);
        if (stat.isFile()) {
          folder?.file(file, fs.readFileSync(filePath, 'utf8'));
        }
      }
    }

    folder?.file(
      'README.md',
      `# EasyIPTV — Native SwiftUI Player for macOS 13+ & iOS 16+

Built with Swift, SwiftUI, AVFoundation, and Swift Concurrency.
Supports Live TV, Movies (VOD), and TV Shows (Series) with Xtream Codes and M3U/M3U8 playlists.

---

## ⚡ Method 1: Instant Clean Build & Run (Terminal / SwiftPM)

1. Open your terminal in this extracted folder.
2. Remove any old cache and run directly:
   \`\`\`bash
   rm -rf .build && swift run
   \`\`\`
   *(Or simply double-click \`run_app.command\` in Finder)*

---

## 🛠️ Method 2: Open Directly in Xcode (Recommended for Development)

Because this project includes a standard \`Package.swift\`, you can open it directly in Xcode with zero configuration:

1. In Terminal inside this folder, run:
   \`\`\`bash
   xed .
   \`\`\`
   *(Or right-click \`Package.swift\` -> Open With -> Xcode)*
2. In Xcode's top toolbar, select **EasyIPTV > My Mac** (or iOS Simulator / Device).
3. Press **Cmd + R** to build and run!
4. To export a standalone \`.app\`:
   - Select **Product > Archive** or **Product > Build for Profiling** to get the signed \`.app\` bundle.

---

## 📦 Method 3: Automated .DMG Disk Image Installer

1. Run the clean build script:
   \`\`\`bash
   chmod +x build_dmg.sh && ./build_dmg.sh
   \`\`\`
2. The script compiles the binary with SwiftPM, attaches \`Info.plist\` with ATS streaming network permissions, ad-hoc codesigns the app, and builds \`EasyIPTV-macOS.dmg\`.
3. Double-click \`EasyIPTV-macOS.dmg\` and drag \`EasyIPTV\` into \`/Applications\`.
`
    );

    const buffer = await zip.generateAsync({
      type: 'nodebuffer',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 }
    });

    res.setHeader('Content-Type', 'application/zip');
    res.setHeader('Content-Disposition', 'attachment; filename="EasyIPTV-macOS-iOS.zip"');
    res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
    return res.send(buffer);
  } catch (err: any) {
    console.error('Failed to generate zip on server:', err);
    return res.status(500).send('Failed to generate zip file');
  }
});

// Setup Vite middleware in dev, or serve static dist in prod
async function setupServer() {
  const isProd = process.env.NODE_ENV === 'production';

  if (!isProd) {
    const { createServer: createViteServer } = await import('vite');
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: 'spa'
    });
    app.use(vite.middlewares);
  } else {
    app.use(express.static(path.join(__dirname, 'dist')));
    app.get('*', (_req, res) => {
      res.sendFile(path.join(__dirname, 'dist', 'index.html'));
    });
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`Server listening on port ${PORT} (dev: ${!isProd})`);
  });
}

setupServer().catch((err) => {
  console.error('Failed to start server:', err);
  process.exit(1);
});
