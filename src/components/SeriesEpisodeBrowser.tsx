import React, { useState, useEffect } from 'react';
import { ChannelItem, XtreamAccountInfo, SeriesDetail, SeriesEpisode } from '../types/iptv';
import { Play, Film, Calendar, Star, Layers, Tv, ChevronRight, Loader2, AlertCircle } from 'lucide-react';

interface SeriesEpisodeBrowserProps {
  channel: ChannelItem;
  xtreamAccount: XtreamAccountInfo | null;
  activeEpisodeId?: string | number | null;
  onSelectEpisode: (episodeItem: ChannelItem, episode: SeriesEpisode) => void;
}

export const SeriesEpisodeBrowser: React.FC<SeriesEpisodeBrowserProps> = ({
  channel,
  xtreamAccount,
  activeEpisodeId,
  onSelectEpisode
}) => {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [seriesDetail, setSeriesDetail] = useState<SeriesDetail | null>(null);
  const [selectedSeason, setSelectedSeason] = useState<string>('1');

  // Extract series ID and credentials
  useEffect(() => {
    let seriesId = '';
    let serverUrl = xtreamAccount?.serverUrl || '';
    let username = xtreamAccount?.username || '';
    let password = '';

    // If channel id has format "xtream-series-1234"
    if (channel.id.startsWith('xtream-series-')) {
      seriesId = channel.id.replace('xtream-series-', '');
    }

    // Try extracting from streamURL: .../series/user/pass/1234.mp4
    const urlMatch = channel.streamURL.match(/^(https?:\/\/[^/]+)\/series\/([^/]+)\/([^/]+)\/(\d+)/i);
    if (urlMatch) {
      if (!serverUrl) serverUrl = urlMatch[1];
      if (!username) username = decodeURIComponent(urlMatch[2]);
      if (!password) password = decodeURIComponent(urlMatch[3]);
      if (!seriesId) seriesId = urlMatch[4];
    }

    // If still no password, check localStorage
    if (!password) {
      try {
        const saved = localStorage.getItem('iptv_saved_xtream_creds') || localStorage.getItem('iptv_xtream_account');
        if (saved) {
          const parsed = JSON.parse(saved);
          password = parsed.password || '';
          if (!serverUrl) serverUrl = parsed.serverUrl || '';
          if (!username) username = parsed.username || '';
        }
      } catch {}
    }

    if (!seriesId) {
      setError('Could not identify series ID for this TV show.');
      return;
    }

    const fetchEpisodes = async () => {
      setLoading(true);
      setError(null);
      try {
        const res = await fetch('/api/xtream/series-info', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            serverUrl: serverUrl || 'http://localhost',
            username: username || 'demo',
            password: password || 'demo',
            seriesId
          })
        });

        if (!res.ok) {
          throw new Error(`Server returned HTTP ${res.status}`);
        }

        const data: SeriesDetail = await res.json();
        setSeriesDetail(data);

        // Determine default season
        if (data.episodes) {
          const seasonKeys = Object.keys(data.episodes).sort((a, b) => Number(a) - Number(b));
          if (seasonKeys.length > 0) {
            setSelectedSeason(seasonKeys[0]);
          }
        }
      } catch (err: any) {
        setError(err.message || 'Failed to load series seasons & episodes.');
      } finally {
        setLoading(false);
      }
    };

    fetchEpisodes();
  }, [channel.id, channel.streamURL]);

  const episodesMap = seriesDetail?.episodes || {};
  const seasonKeys = Object.keys(episodesMap).sort((a, b) => Number(a) - Number(b));
  const currentSeasonEpisodes = episodesMap[selectedSeason] || [];

  const handleEpisodeClick = (ep: any) => {
    let serverUrl = xtreamAccount?.serverUrl || '';
    let username = xtreamAccount?.username || '';
    let password = '';

    const urlMatch = channel.streamURL.match(/^(https?:\/\/[^/]+)\/series\/([^/]+)\/([^/]+)\/(\d+)/i);
    if (urlMatch) {
      if (!serverUrl) serverUrl = urlMatch[1];
      if (!username) username = decodeURIComponent(urlMatch[2]);
      if (!password) password = decodeURIComponent(urlMatch[3]);
    }
    if (!password) {
      try {
        const saved = localStorage.getItem('iptv_xtream_account');
        if (saved) {
          const parsed = JSON.parse(saved);
          password = parsed.password || '';
          if (!serverUrl) serverUrl = parsed.serverUrl || '';
          if (!username) username = parsed.username || '';
        }
      } catch {}
    }

    const cleanBase = serverUrl.replace(/\/+$/, '');
    const epId = String(ep.id);
    const ext = ep.container_extension || 'mp4';
    const epStreamUrl = `${cleanBase}/series/${encodeURIComponent(username)}/${encodeURIComponent(password)}/${epId}.${ext}`;

    const episodeItem: ChannelItem = {
      id: `xtream-episode-${epId}`,
      name: `${channel.name} - S${selectedSeason}E${ep.episode_num || ''}: ${ep.title || 'Episode'}`,
      groupTitle: `Season ${selectedSeason}`,
      logoURL: channel.logoURL,
      streamURL: epStreamUrl,
      contentType: 'series'
    };

    onSelectEpisode(episodeItem, {
      id: epId,
      episodeNum: Number(ep.episode_num) || 1,
      title: ep.title || 'Episode',
      containerExtension: ext,
      season: selectedSeason,
      streamUrl: epStreamUrl
    });
  };

  return (
    <div className="bg-neutral-900/90 border-t border-neutral-800 text-white flex flex-col max-h-96 overflow-hidden select-none">
      
      {/* Series Metadata Header */}
      <div className="p-3 bg-neutral-950/60 border-b border-neutral-800/80 flex items-center justify-between">
        <div className="flex items-center gap-3 truncate">
          {channel.logoURL ? (
            <img 
              src={`/api/proxy-image?url=${encodeURIComponent(channel.logoURL)}`}
              alt={channel.name} 
              className="w-9 h-12 rounded object-cover border border-neutral-800 bg-neutral-900 shrink-0"
              onError={(e) => { (e.target as HTMLElement).style.display = 'none'; }}
            />
          ) : (
            <div className="w-9 h-12 rounded bg-neutral-800 flex items-center justify-center text-neutral-400 shrink-0">
              <Tv className="w-5 h-5" />
            </div>
          )}
          <div className="truncate">
            <h3 className="text-xs font-bold text-white truncate flex items-center gap-1.5">
              <span>{seriesDetail?.info?.name || channel.name}</span>
              <span className="px-1.5 py-0.2 rounded text-[9px] bg-purple-500/20 text-purple-400 border border-purple-500/30">
                TV Series
              </span>
            </h3>
            <p className="text-[11px] text-neutral-400 truncate mt-0.5">
              {seriesDetail?.info?.genre || channel.groupTitle} {seriesDetail?.info?.releaseDate ? `• ${seriesDetail.info.releaseDate.slice(0, 4)}` : ''}
            </p>
          </div>
        </div>

        {/* Total Seasons Badge */}
        <div className="flex items-center gap-2 shrink-0 text-[11px] text-neutral-400">
          <Layers className="w-3.5 h-3.5 text-neutral-400" />
          <span>{seasonKeys.length} Season{seasonKeys.length === 1 ? '' : 's'}</span>
        </div>
      </div>

      {/* Season Selection Tabs */}
      {seasonKeys.length > 0 && (
        <div className="px-3 py-2 bg-neutral-900/70 border-b border-neutral-800/80 flex items-center gap-1.5 overflow-x-auto scrollbar-none">
          <span className="text-[10px] font-bold uppercase text-neutral-400 mr-1 shrink-0">
            Seasons:
          </span>
          {seasonKeys.map((season) => (
            <button
              key={season}
              onClick={() => setSelectedSeason(season)}
              className={`px-3 py-1 rounded-md text-xs font-semibold shrink-0 transition-all cursor-pointer ${
                selectedSeason === season
                  ? 'bg-blue-600 text-white shadow-sm'
                  : 'bg-neutral-800/80 text-neutral-300 hover:bg-neutral-800 hover:text-white'
              }`}
            >
              Season {season}
              <span className="ml-1.5 text-[10px] opacity-75">
                ({(episodesMap[season] || []).length})
              </span>
            </button>
          ))}
        </div>
      )}

      {/* Episodes List */}
      <div className="flex-1 overflow-y-auto p-2 space-y-1 divide-y divide-neutral-800/40">
        {loading ? (
          <div className="py-8 flex flex-col items-center justify-center text-neutral-400 gap-2">
            <Loader2 className="w-5 h-5 animate-spin text-blue-500" />
            <span className="text-xs">Fetching seasons and episodes from server...</span>
          </div>
        ) : error ? (
          <div className="py-6 px-4 text-center text-red-400 flex flex-col items-center gap-1.5">
            <AlertCircle className="w-5 h-5" />
            <span className="text-xs font-medium">{error}</span>
            <span className="text-[10px] text-neutral-500">
              Ensure server credentials and series permissions are active.
            </span>
          </div>
        ) : currentSeasonEpisodes.length === 0 ? (
          <div className="py-8 text-center text-neutral-500 text-xs">
            No episodes found for Season {selectedSeason}.
          </div>
        ) : (
          currentSeasonEpisodes.map((ep: any, index: number) => {
            const epIdStr = String(ep.id);
            const isActive = String(activeEpisodeId) === epIdStr;
            const epNum = ep.episode_num ?? index + 1;
            const title = ep.title || `Episode ${epNum}`;

            return (
              <div
                key={epIdStr}
                onClick={() => handleEpisodeClick(ep)}
                className={`pt-1 first:pt-0 group flex items-center justify-between p-2 rounded-lg transition-all cursor-pointer ${
                  isActive
                    ? 'bg-blue-600/20 border border-blue-500/40 text-blue-200'
                    : 'hover:bg-neutral-800/60 text-neutral-200'
                }`}
              >
                <div className="flex items-center gap-2.5 truncate">
                  <div className={`w-6 h-6 rounded flex items-center justify-center text-[10px] font-bold shrink-0 ${
                    isActive ? 'bg-blue-600 text-white' : 'bg-neutral-800 text-neutral-400 group-hover:bg-neutral-700'
                  }`}>
                    {isActive ? (
                      <Play className="w-3 h-3 fill-current" />
                    ) : (
                      epNum
                    )}
                  </div>
                  <div className="truncate">
                    <div className="text-xs font-medium truncate flex items-center gap-1.5">
                      <span className={isActive ? 'text-white font-bold' : ''}>{title}</span>
                      {isActive && (
                        <span className="px-1.5 py-0.2 rounded text-[9px] font-bold bg-blue-500 text-white uppercase tracking-wider animate-pulse">
                          Now Playing
                        </span>
                      )}
                    </div>
                    <div className="text-[10px] text-neutral-500 truncate flex items-center gap-2 mt-0.5">
                      <span>Season {selectedSeason} • Episode {epNum}</span>
                      {ep.container_extension && (
                        <span className="uppercase font-mono">{ep.container_extension}</span>
                      )}
                      {ep.info?.duration && <span>{ep.info.duration}</span>}
                    </div>
                  </div>
                </div>

                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    handleEpisodeClick(ep);
                  }}
                  className={`p-1.5 rounded-md transition-all shrink-0 ${
                    isActive
                      ? 'bg-blue-600 text-white'
                      : 'bg-neutral-800 text-neutral-400 group-hover:bg-blue-600 group-hover:text-white'
                  }`}
                  title={`Play ${title}`}
                >
                  <Play className="w-3 h-3 fill-current" />
                </button>
              </div>
            );
          })
        )}
      </div>

    </div>
  );
};
