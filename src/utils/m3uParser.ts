import { ChannelItem, ContentType } from '../types/iptv';

export const SAMPLE_CHANNELS: ChannelItem[] = [];

/**
 * Categorizes an IPTV stream into one of the 3 fundamental types:
 * - 'live' (Live TV broadcast channels, news, sports)
 * - 'movie' (Films, VOD, Cinema, on-demand movies)
 * - 'series' (TV shows, series with seasons and episodes)
 */
export function detectContentType(groupTitle: string, name: string, streamUrl: string): ContentType {
  const lowerGroup = (groupTitle || '').toLowerCase();
  const lowerName = (name || '').toLowerCase();
  const lowerUrl = (streamUrl || '').toLowerCase();

  // 1. Check TV Shows / Series first
  if (
    lowerGroup.includes('series') ||
    lowerGroup.includes('serie') ||
    lowerGroup.includes('tv show') ||
    lowerGroup.includes('tv-show') ||
    lowerGroup.includes('shows') ||
    lowerGroup.includes('temporada') ||
    lowerGroup.includes('season') ||
    lowerGroup.includes('anime') ||
    lowerGroup.includes('telenovela') ||
    lowerUrl.includes('/series/') ||
    /\bs\d{1,2}\s*e\d{1,2}\b/i.test(name) ||
    /\bseason\s*\d+\b/i.test(name) ||
    /\bepisode\s*\d+\b/i.test(name) ||
    /\bep\.\s*\d+\b/i.test(name) ||
    /\[series\]/i.test(name) ||
    /\|\s*series\s*\|/i.test(name)
  ) {
    return 'series';
  }

  // 2. Check Movies / VOD
  if (
    lowerGroup.includes('movie') ||
    lowerGroup.includes('movies') ||
    lowerGroup.includes('vod') ||
    lowerGroup.includes('cinema') ||
    lowerGroup.includes('films') ||
    lowerGroup.includes('film') ||
    lowerGroup.includes('pelicula') ||
    lowerGroup.includes('peliculas') ||
    lowerGroup.includes('filme') ||
    lowerGroup.includes('filmes') ||
    lowerGroup.includes('kino') ||
    lowerGroup.includes('4k movies') ||
    lowerGroup.includes('cinema') ||
    lowerUrl.includes('/movie/') ||
    lowerUrl.endsWith('.mp4') ||
    lowerUrl.endsWith('.mkv') ||
    lowerUrl.endsWith('.avi') ||
    lowerUrl.endsWith('.mov') ||
    /\(\s*(19\d\d|20[0-3]\d)\s*\)/.test(name)
  ) {
    return 'movie';
  }

  // 3. Default to Live TV (Sports, News, 24/7, General)
  return 'live';
}

export function parseM3UString(rawText: string): ChannelItem[] {
  const lines = rawText.split(/\r?\n/);
  const items: ChannelItem[] = [];
  let pendingExtInf: string | null = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    if (line.startsWith('#EXTINF:')) {
      pendingExtInf = line;
      continue;
    }

    if (line.startsWith('#')) {
      continue;
    }

    if (pendingExtInf) {
      const extInf = pendingExtInf;
      pendingExtInf = null;

      const tvgNameMatch = extInf.match(/tvg-name=["']([^"']*)["']/i);
      const tvgIDMatch = extInf.match(/tvg-id=["']([^"']*)["']/i);
      const groupMatch = extInf.match(/group-title=["']([^"']*)["']/i);
      const logoMatch = extInf.match(/tvg-logo=["']([^"']*)["']/i);

      let displayName = '';
      const commaIndex = extInf.lastIndexOf(',');
      if (commaIndex !== -1) {
        displayName = extInf.substring(commaIndex + 1).trim();
      }

      if (!displayName) {
        displayName = tvgNameMatch ? tvgNameMatch[1] : `Channel ${items.length + 1}`;
      }

      const rawGroup = groupMatch ? groupMatch[1].trim() : 'General';
      const streamURL = line;
      const contentType = detectContentType(rawGroup, displayName, streamURL);

      items.push({
        id: `m3u-${items.length + 1}-${Date.now().toString(36)}`,
        name: displayName,
        groupTitle: rawGroup || (contentType === 'movie' ? 'Movies' : contentType === 'series' ? 'TV Shows' : 'General Live'),
        logoURL: logoMatch ? logoMatch[1] : undefined,
        streamURL,
        tvgID: tvgIDMatch ? tvgIDMatch[1] : undefined,
        tvgName: tvgNameMatch ? tvgNameMatch[1] : undefined,
        isFavorite: false,
        contentType
      });
    }
  }

  return items;
}
