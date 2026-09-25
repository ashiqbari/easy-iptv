import React, { useState, useEffect } from 'react';
import { ChannelItem, ContentType, XtreamAccountInfo } from '../types/iptv';
import { InteractivePlayer } from './InteractivePlayer';
import { SeriesEpisodeBrowser } from './SeriesEpisodeBrowser';
import { 
  Tv, Star, Search, PlusCircle, RefreshCw, Folder, Film, 
  Flame, Radio, Music, Trophy, Clapperboard, Sparkles, Play
} from 'lucide-react';

interface MacSimulatorProps {
  channels: ChannelItem[];
  currentChannel: ChannelItem | null;
  selectedSection: ContentType;
  onSelectSection: (section: ContentType) => void;
  selectedCategory: string;
  onSelectCategory: (cat: string) => void;
  searchQuery: string;
  onSearchChange: (q: string) => void;
  onSelectChannel: (item: ChannelItem) => void;
  onToggleFavorite: (item: ChannelItem) => void;
  isFavorite: (item: ChannelItem) => boolean;
  onOpenLoader: () => void;
  onClearPlaylist?: () => void;
  xtreamAccount?: XtreamAccountInfo | null;
}

export const MacSimulator: React.FC<MacSimulatorProps> = ({
  channels,
  currentChannel,
  selectedSection,
  onSelectSection,
  selectedCategory,
  onSelectCategory,
  searchQuery,
  onSearchChange,
  onSelectChannel,
  onToggleFavorite,
  isFavorite,
  onOpenLoader,
  onClearPlaylist,
  xtreamAccount
}) => {
  const [activePlaybackChannel, setActivePlaybackChannel] = useState<ChannelItem | null>(null);
  const [activeEpisodeId, setActiveEpisodeId] = useState<string | number | null>(null);

  // Reset episode selection when a non-series channel or new series is picked
  useEffect(() => {
    setActivePlaybackChannel(null);
    setActiveEpisodeId(null);
  }, [currentChannel?.id, selectedSection]);
  // Memoized counts by fundamental category
  const { liveCount, movieCount, seriesCount } = React.useMemo(() => {
    let live = 0, movie = 0, series = 0;
    for (const c of channels) {
      const type = c.contentType || 'live';
      if (type === 'live') live++;
      else if (type === 'movie') movie++;
      else if (type === 'series') series++;
    }
    return { liveCount: live, movieCount: movie, seriesCount: series };
  }, [channels]);

  // Channels belonging to current section
  const sectionChannels = React.useMemo(() => {
    return channels.filter(c => (c.contentType || 'live') === selectedSection);
  }, [channels, selectedSection]);

  // Compute categories and category counts in single pass
  const { allCategories, categoryCountsMap, favoritesCount } = React.useMemo(() => {
    const counts: Record<string, number> = {};
    const groupSet = new Set<string>();
    let fav = 0;

    for (const c of sectionChannels) {
      const g = c.groupTitle || 'General';
      groupSet.add(g);
      counts[g] = (counts[g] || 0) + 1;
      if (isFavorite(c)) fav++;
    }

    const sortedGroups = Array.from(groupSet).sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
    return {
      allCategories: ['All', 'Favorites', ...sortedGroups],
      categoryCountsMap: counts,
      favoritesCount: fav
    };
  }, [sectionChannels, isFavorite]);

  // Memoized filtered channels for display
  const filteredChannels = React.useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    return sectionChannels.filter(channel => {
      // 1. Category
      if (selectedCategory === 'Favorites' || selectedCategory === '★ Favorites') {
        if (!isFavorite(channel)) return false;
      } else if (selectedCategory !== 'All') {
        if ((channel.groupTitle || 'General') !== selectedCategory) return false;
      }

      // 2. Search
      if (q) {
        const matchName = channel.name.toLowerCase().includes(q);
        const matchGroup = (channel.groupTitle || '').toLowerCase().includes(q);
        if (!matchName && !matchGroup) return false;
      }

      return true;
    });
  }, [sectionChannels, selectedCategory, searchQuery, isFavorite]);

  const getCategoryIcon = (cat: string) => {
    const l = cat.toLowerCase();
    if (l === 'all') {
      if (selectedSection === 'movie') return <Film className="w-4 h-4 text-purple-400" />;
      if (selectedSection === 'series') return <Clapperboard className="w-4 h-4 text-amber-400" />;
      return <Tv className="w-4 h-4 text-blue-400" />;
    }
    if (l === 'favorites' || l.includes('favorite')) return <Star className="w-4 h-4 text-amber-400 fill-amber-400" />;
    if (l.includes('sport')) return <Trophy className="w-4 h-4 text-emerald-400" />;
    if (l.includes('cinema') || l.includes('movie') || l.includes('film')) return <Film className="w-4 h-4 text-purple-400" />;
    if (l.includes('sci')) return <Flame className="w-4 h-4 text-orange-400" />;
    if (l.includes('music')) return <Music className="w-4 h-4 text-pink-400" />;
    return <Folder className="w-4 h-4 text-neutral-400" />;
  };

  const [isDetailOnly, setIsDetailOnly] = React.useState(false);

  return (
    <div className="w-full h-full bg-neutral-950 rounded-2xl border border-neutral-800 shadow-2xl flex flex-col overflow-hidden">
      
      {/* macOS Window Titlebar with Traffic Lights */}
      <div className="h-10 bg-neutral-900/90 backdrop-blur-md border-b border-neutral-800 flex items-center justify-between px-4 select-none">
        <div className="flex items-center gap-2">
          <div className="flex items-center gap-1.5">
            <div className="w-3 h-3 rounded-full bg-red-500/80 border border-red-600 shadow-xs" />
            <div className="w-3 h-3 rounded-full bg-yellow-500/80 border border-yellow-600 shadow-xs" />
            <button 
              onClick={() => setIsDetailOnly(!isDetailOnly)}
              className="w-3 h-3 rounded-full bg-green-500 hover:bg-green-400 border border-green-600 shadow-xs cursor-pointer transition-transform hover:scale-110"
              title={isDetailOnly ? "Restore Sidebar & Channel List" : "Expand Video Player (Hide Sidebars)"}
            />
          </div>
          <img 
            src="/app-icon.png" 
            alt="App Icon" 
            className="w-4 h-4 rounded-md object-cover ml-3"
            referrerPolicy="no-referrer"
          />
          <span className="text-xs font-medium text-neutral-300 ml-1.5 font-mono">
            EasyIPTV — {selectedSection === 'live' ? 'Live TV' : selectedSection === 'movie' ? 'Movies (VOD)' : 'TV Shows (Series)'}
          </span>
        </div>

        <div className="flex items-center gap-2">
          <button
            onClick={() => setIsDetailOnly(!isDetailOnly)}
            className={`px-2.5 py-1 rounded-md text-xs font-medium border transition-colors flex items-center gap-1.5 cursor-pointer ${
              isDetailOnly 
                ? 'bg-blue-600/30 border-blue-500/50 text-blue-300' 
                : 'hover:bg-neutral-800 text-neutral-300 border-neutral-700/50'
            }`}
            title="Toggle sidebar to maximize video"
          >
            {isDetailOnly ? 'Show Sidebar' : 'Hide Sidebar'}
          </button>

          {channels.length > 0 && onClearPlaylist && (
            <button
              onClick={onClearPlaylist}
              className="p-1.5 rounded-md hover:bg-neutral-800 text-neutral-400 hover:text-white transition-colors text-xs flex items-center gap-1 cursor-pointer"
              title="Clear loaded channels"
            >
              <RefreshCw className="w-3.5 h-3.5" />
              <span className="hidden sm:inline">Clear</span>
            </button>
          )}
          <button
            onClick={onOpenLoader}
            className="px-2.5 py-1 rounded-md bg-blue-600/80 hover:bg-blue-600 text-white text-xs font-medium transition-colors flex items-center gap-1.5 cursor-pointer shadow-xs"
          >
            <PlusCircle className="w-3.5 h-3.5" /> Add Playlist / Xtream
          </button>
        </div>
      </div>

      {/* 3-Column NavigationSplitView Layout */}
      <div className="flex-1 flex overflow-hidden">
        
        {/* Column 1: Sidebar (Section Switcher & Categories) - Spacious width */}
        {!isDetailOnly && (
        <>
        <aside className="w-72 lg:w-80 bg-neutral-900/50 border-r border-neutral-800/80 flex flex-col select-none shrink-0">
          
          {/* Clean 3 Core Categories Selector (Live TV, Movies, TV Shows) */}
          <div className="p-2.5 border-b border-neutral-800/80 bg-neutral-900/40">
            <div className="grid grid-cols-3 gap-1 bg-neutral-950 p-1 rounded-xl border border-neutral-800/80">
              <button
                onClick={() => {
                  onSelectSection('live');
                  onSelectCategory('All');
                }}
                className={`py-1.5 px-1 rounded-lg text-[11px] font-semibold flex flex-col items-center gap-0.5 transition-all cursor-pointer ${
                  selectedSection === 'live'
                    ? 'bg-blue-600 text-white shadow-sm'
                    : 'text-neutral-400 hover:text-white hover:bg-neutral-900'
                }`}
              >
                <Tv className="w-3.5 h-3.5" />
                <span className="truncate">Live TV</span>
                <span className="text-[9px] opacity-80 font-mono">{liveCount}</span>
              </button>

              <button
                onClick={() => {
                  onSelectSection('movie');
                  onSelectCategory('All');
                }}
                className={`py-1.5 px-1 rounded-lg text-[11px] font-semibold flex flex-col items-center gap-0.5 transition-all cursor-pointer ${
                  selectedSection === 'movie'
                    ? 'bg-purple-600 text-white shadow-sm'
                    : 'text-neutral-400 hover:text-white hover:bg-neutral-900'
                }`}
              >
                <Film className="w-3.5 h-3.5" />
                <span className="truncate">Movies</span>
                <span className="text-[9px] opacity-80 font-mono">{movieCount}</span>
              </button>

              <button
                onClick={() => {
                  onSelectSection('series');
                  onSelectCategory('All');
                }}
                className={`py-1.5 px-1 rounded-lg text-[11px] font-semibold flex flex-col items-center gap-0.5 transition-all cursor-pointer ${
                  selectedSection === 'series'
                    ? 'bg-amber-600 text-white shadow-sm'
                    : 'text-neutral-400 hover:text-white hover:bg-neutral-900'
                }`}
              >
                <Clapperboard className="w-3.5 h-3.5" />
                <span className="truncate">TV Shows</span>
                <span className="text-[9px] opacity-80 font-mono">{seriesCount}</span>
              </button>
            </div>
          </div>

          {/* Category Groupings */}
          <div className="flex-1 overflow-y-auto px-2 space-y-1 py-2">
            <div className="text-[10px] font-semibold uppercase tracking-wider text-neutral-400 px-2 py-1">
              Quick Filters
            </div>
            {allCategories.slice(0, 2).map((cat) => {
              const isSelected = selectedCategory === cat;
              const count = cat === 'Favorites' || cat === '★ Favorites' 
                ? favoritesCount 
                : sectionChannels.length;

              return (
                <button
                  key={cat}
                  onClick={() => onSelectCategory(cat)}
                  className={`w-full text-left px-2.5 py-1.5 rounded-lg text-xs font-medium flex items-center justify-between transition-colors cursor-pointer ${
                    isSelected 
                      ? 'bg-blue-600 text-white shadow-sm' 
                      : 'text-neutral-300 hover:bg-neutral-800 hover:text-white'
                  }`}
                >
                  <div className="flex items-center gap-2 truncate">
                    {getCategoryIcon(cat)}
                    <span className="truncate">{cat === 'Favorites' || cat === '★ Favorites' ? 'Favorites' : `All ${selectedSection === 'live' ? 'Live TV' : selectedSection === 'movie' ? 'Movies' : 'Shows'}`}</span>
                  </div>
                  <span className={`text-[10px] font-mono px-1.5 py-0.5 rounded ${
                    isSelected ? 'bg-blue-700/80 text-white' : 'text-neutral-500'
                  }`}>
                    {count}
                  </span>
                </button>
              );
            })}

            <div className="text-[10px] font-semibold uppercase tracking-wider text-neutral-400 px-2 pt-3 pb-1">
              {selectedSection === 'live' ? 'Live Categories' : selectedSection === 'movie' ? 'Movie Genres' : 'Show Categories'}
            </div>
            {allCategories.slice(2).map((cat) => {
              const isSelected = selectedCategory === cat;
              const count = categoryCountsMap[cat] || 0;

              return (
                <button
                  key={cat}
                  onClick={() => onSelectCategory(cat)}
                  className={`w-full text-left px-2.5 py-1.5 rounded-lg text-xs font-medium flex items-center justify-between transition-colors cursor-pointer ${
                    isSelected 
                      ? 'bg-blue-600 text-white shadow-sm' 
                      : 'text-neutral-300 hover:bg-neutral-800 hover:text-white'
                  }`}
                >
                  <div className="flex items-center gap-2 truncate">
                    {getCategoryIcon(cat)}
                    <span className="truncate">{cat}</span>
                  </div>
                  <span className={`text-[10px] font-mono px-1.5 py-0.5 rounded ${
                    isSelected ? 'bg-blue-700/80 text-white' : 'text-neutral-500'
                  }`}>
                    {count}
                  </span>
                </button>
              );
            })}
          </div>

          <div className="p-3 border-t border-neutral-800/80 text-[11px] text-neutral-400 flex items-center justify-between">
            <span>{sectionChannels.length} in {selectedSection.toUpperCase()}</span>
            <span className="text-neutral-500">{channels.length} Total</span>
          </div>
        </aside>

        {/* Column 2: Content (Channel List) - Spacious width */}
        <section className="w-80 lg:w-96 bg-neutral-950/70 border-r border-neutral-800/80 flex flex-col shrink-0">
          {/* Search Bar */}
          <div className="p-3 border-b border-neutral-800/80 mb-3.5 pb-3">
            <div className="relative">
              <Search className="w-3.5 h-3.5 absolute left-2.5 top-2.5 text-neutral-500" />
              <input
                type="text"
                placeholder={`Search in ${selectedSection === 'live' ? 'Live TV' : selectedSection === 'movie' ? 'Movies' : 'TV Shows'}...`}
                value={searchQuery}
                onChange={(e) => onSearchChange(e.target.value)}
                className="w-full pl-8 pr-3 py-1.5 bg-neutral-900 border border-neutral-800 rounded-lg text-xs text-white placeholder:text-neutral-500 focus:outline-none focus:border-blue-500 shadow-inner"
              />
            </div>
            <div className="flex items-center justify-between mt-2.5 text-[11px] text-neutral-400 px-0.5">
              <span className="font-medium truncate">{selectedCategory}</span>
              <span className="font-mono text-neutral-500">{filteredChannels.length} found</span>
            </div>
          </div>

          {/* List items */}
          <div className="flex-1 overflow-y-auto divide-y divide-neutral-900/50">
            {filteredChannels.length === 0 ? (
              <div className="p-8 text-center flex flex-col items-center justify-center h-full text-neutral-500 text-xs">
                <Radio className="w-8 h-8 text-neutral-600 mb-2 opacity-60" />
                <p className="font-medium text-neutral-400">
                  {channels.length === 0 ? 'No Playlist Loaded' : 'No channels found'}
                </p>
                <p className="text-[11px] text-neutral-500 mt-1 max-w-[200px]">
                  {channels.length === 0 
                    ? 'Load your M3U URL or connect your Xtream Codes account.'
                    : 'Try changing category or clearing your search.'}
                </p>
                {channels.length === 0 && (
                  <button
                    onClick={onOpenLoader}
                    className="mt-3 px-3 py-1.5 rounded-lg bg-blue-600 hover:bg-blue-500 text-white font-medium text-xs transition-colors cursor-pointer"
                  >
                    Add Playlist
                  </button>
                )}
              </div>
            ) : (
              filteredChannels.map((channel) => {
                const isCurrent = currentChannel?.id === channel.id;
                const isFav = isFavorite(channel);

                return (
                  <div
                    key={channel.id}
                    onClick={() => onSelectChannel(channel)}
                    className={`p-3 flex items-center gap-3 transition-colors cursor-pointer group ${
                      isCurrent 
                        ? 'bg-blue-900/30 border-l-4 border-blue-500' 
                        : 'hover:bg-neutral-900/60'
                    }`}
                  >
                    {/* Logo / Poster Icon */}
                    <div className="w-10 h-10 rounded-lg bg-neutral-900 border border-neutral-800 flex items-center justify-center shrink-0 overflow-hidden relative">
                      {channel.logoURL ? (
                        <img 
                          src={
                            typeof window !== 'undefined' && window.location.protocol === 'https:' && channel.logoURL.startsWith('http://')
                              ? `/api/proxy-image?url=${encodeURIComponent(channel.logoURL)}`
                              : channel.logoURL
                          } 
                          alt="" 
                          className="w-full h-full object-contain p-0.5" 
                          onError={(e) => { (e.target as HTMLElement).style.display = 'none'; }}
                        />
                      ) : (
                        selectedSection === 'movie' 
                          ? <Film className="w-5 h-5 text-purple-400" />
                          : selectedSection === 'series'
                          ? <Clapperboard className="w-5 h-5 text-amber-400" />
                          : <Radio className="w-5 h-5 text-neutral-400" />
                      )}
                    </div>

                    {/* Metadata */}
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center justify-between gap-1">
                        <span className={`text-xs font-semibold truncate ${
                          isCurrent ? 'text-blue-400' : 'text-neutral-200 group-hover:text-white'
                        }`}>
                          {channel.name}
                        </span>
                        
                        <button
                          onClick={(e) => {
                            e.stopPropagation();
                            onToggleFavorite(channel);
                          }}
                          className="text-neutral-500 hover:text-amber-400 p-0.5 transition-colors cursor-pointer"
                          title={isFav ? 'Remove Favorite' : 'Add Favorite'}
                        >
                          <Star className={`w-3.5 h-3.5 ${isFav ? 'text-amber-400 fill-amber-400' : ''}`} />
                        </button>
                      </div>

                      <div className="flex items-center gap-1.5 mt-0.5">
                        <span className="text-[10px] text-neutral-400 truncate">
                          {channel.groupTitle}
                        </span>
                        <span className="text-[9px] px-1 py-0.2 rounded font-mono uppercase bg-neutral-900 text-neutral-400 border border-neutral-800 shrink-0">
                          {channel.contentType === 'movie' ? 'VOD' : channel.contentType === 'series' ? 'EPISODE' : 'LIVE'}
                        </span>
                      </div>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </section>
        </>
        )}

        {/* Column 3: Detail View (IPTVPlaybackView) */}
        <main className="flex-1 bg-black flex flex-col overflow-hidden relative">
          <div className="flex-1 relative overflow-hidden flex flex-col">
            {currentChannel?.contentType === 'series' && !activePlaybackChannel ? (
              <div className="w-full h-full bg-gradient-to-b from-neutral-900 via-neutral-950 to-black overflow-y-auto p-6 md:p-8 select-none">
                <div className="flex flex-col md:flex-row items-start gap-6 mb-8">
                  {currentChannel.logoURL ? (
                    <img
                      src={currentChannel.logoURL}
                      alt={currentChannel.name}
                      className="w-36 h-52 object-cover rounded-xl shadow-2xl border border-neutral-700/80 shrink-0"
                      referrerPolicy="no-referrer"
                    />
                  ) : (
                    <div className="w-36 h-52 rounded-xl bg-amber-500/20 text-amber-400 flex items-center justify-center border border-amber-500/30 shrink-0 shadow-xl">
                      <Clapperboard className="w-12 h-12" />
                    </div>
                  )}

                  <div className="flex-1 space-y-3">
                    <h2 className="text-2xl md:text-3xl font-bold text-white tracking-tight">
                      {currentChannel.name}
                    </h2>

                    <div className="flex flex-wrap items-center gap-2 text-xs">
                      <span className="px-2 py-0.5 rounded bg-neutral-800 text-neutral-300 font-mono">2024</span>
                      <span className="px-2 py-0.5 rounded bg-neutral-800 text-neutral-300">{currentChannel.groupTitle || 'Drama / TV Series'}</span>
                      <span className="px-2 py-0.5 rounded bg-yellow-500/20 text-yellow-400 border border-yellow-500/30 flex items-center gap-1 font-bold">
                        <Star className="w-3 h-3 fill-yellow-400" /> 9.0
                      </span>
                    </div>

                    <p className="text-xs md:text-sm text-neutral-300 leading-relaxed max-w-2xl">
                      High-definition TV series stream. Browse through all available seasons and episodes below to begin streaming on demand.
                    </p>

                    <div className="flex items-center gap-3 pt-2">
                      <button
                        onClick={() => {
                          const firstEpButton = document.querySelector('[data-first-episode="true"]') as HTMLButtonElement;
                          if (firstEpButton) firstEpButton.click();
                        }}
                        className="px-5 py-2.5 rounded-xl bg-white hover:bg-neutral-200 text-black font-bold text-xs flex items-center gap-2 transition-transform hover:scale-105 cursor-pointer shadow-lg"
                      >
                        <Play className="w-4 h-4 fill-black" />
                        <span>Play first episode</span>
                      </button>

                      <button
                        onClick={() => onToggleFavorite(currentChannel)}
                        className="px-4 py-2.5 rounded-xl bg-neutral-800/90 hover:bg-neutral-800 text-white font-semibold text-xs flex items-center gap-2 border border-neutral-700/60 transition-colors cursor-pointer"
                      >
                        <Star className={`w-4 h-4 ${isFavorite(currentChannel) ? 'fill-yellow-400 text-yellow-400' : 'text-neutral-400'}`} />
                        <span>{isFavorite(currentChannel) ? 'Favorited' : 'Add to favorites'}</span>
                      </button>
                    </div>
                  </div>
                </div>

                <div className="text-sm font-bold text-white mb-2 flex items-center gap-2">
                  <span>Seasons and Episodes</span>
                </div>
              </div>
            ) : (
              <InteractivePlayer 
                channel={activePlaybackChannel || currentChannel} 
                isFavorite={currentChannel ? isFavorite(currentChannel) : false}
                onToggleFavorite={() => currentChannel && onToggleFavorite(currentChannel)}
                onBackToSeriesOverview={currentChannel?.contentType === 'series' && activePlaybackChannel ? () => setActivePlaybackChannel(null) : undefined}
                xtreamAccount={xtreamAccount ?? null}
                onNextChannel={() => {
                  if (filteredChannels.length > 1 && currentChannel) {
                    const idx = filteredChannels.findIndex(c => c.id === currentChannel.id);
                    const next = filteredChannels[(idx + 1) % filteredChannels.length];
                    onSelectChannel(next);
                  }
                }}
              />
            )}
          </div>

          {/* Series Episode Browser (Dedicated ONLY for TV Shows) */}
          {currentChannel && currentChannel.contentType === 'series' && (
            <SeriesEpisodeBrowser
              channel={currentChannel}
              xtreamAccount={xtreamAccount ?? null}
              activeEpisodeId={activeEpisodeId}
              onSelectEpisode={(episodeItem, episode) => {
                setActivePlaybackChannel(episodeItem);
                setActiveEpisodeId(episode.id);
              }}
            />
          )}
        </main>

      </div>

    </div>
  );
};
