import React, { useState } from 'react';
import { ChannelItem, ContentType } from '../types/iptv';
import { InteractivePlayer } from './InteractivePlayer';
import { 
  Tv, Star, Search, Plus, Radio, ArrowLeft,
  ChevronRight, Wifi, Battery, Film, Clapperboard
} from 'lucide-react';

interface IOSSimulatorProps {
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
}

export const IOSSimulator: React.FC<IOSSimulatorProps> = ({
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
  onOpenLoader
}) => {
  const [activeTab, setActiveTab] = useState<'channels' | 'player' | 'favorites'>('channels');

  // Count items by fundamental category
  const liveCount = channels.filter(c => (c.contentType || 'live') === 'live').length;
  const movieCount = channels.filter(c => c.contentType === 'movie').length;
  const seriesCount = channels.filter(c => c.contentType === 'series').length;

  // Section channels
  const sectionChannels = channels.filter(c => (c.contentType || 'live') === selectedSection);

  // Compute categories for current section
  const categoryGroups = Array.from(new Set(sectionChannels.map(c => c.groupTitle || 'General'))).sort();
  const allCategories = ['All', 'Favorites', ...categoryGroups];

  // Filter channels
  const filteredChannels = sectionChannels.filter(channel => {
    if (activeTab === 'favorites' || selectedCategory === 'Favorites' || selectedCategory === '★ Favorites') {
      if (!isFavorite(channel)) return false;
    } else if (selectedCategory !== 'All') {
      if ((channel.groupTitle || 'General') !== selectedCategory) return false;
    }

    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase();
      const matchName = channel.name.toLowerCase().includes(q);
      const matchGroup = channel.groupTitle.toLowerCase().includes(q);
      if (!matchName && !matchGroup) return false;
    }

    return true;
  });

  return (
    <div className="w-[380px] h-[750px] bg-black rounded-[48px] p-3 shadow-2xl border-4 border-neutral-800 relative flex flex-col select-none overflow-hidden mx-auto">
      
      {/* iPhone Outer Hardware Bezel & Screen Container */}
      <div className="w-full h-full bg-neutral-950 rounded-[38px] overflow-hidden flex flex-col relative border border-neutral-900">
        
        {/* Dynamic Island & Status Bar */}
        <div className="pt-3 px-6 pb-2 flex items-center justify-between text-white text-[11px] font-medium z-30 bg-neutral-950/80 backdrop-blur-md">
          <span>9:41</span>
          
          {/* Dynamic Island */}
          <div className="w-24 h-6 bg-black rounded-full flex items-center justify-center gap-1.5 px-2 shadow-inner">
            <span className="w-2.5 h-2.5 rounded-full bg-neutral-800" />
            <span className="w-2.5 h-2.5 rounded-full bg-blue-500/80 animate-pulse" />
          </div>

          <div className="flex items-center gap-1.5">
            <Wifi className="w-3 h-3" />
            <Battery className="w-4 h-4" />
          </div>
        </div>

        {/* Top Header / Navigation Bar */}
        <div className="px-4 py-2 border-b border-neutral-900 flex items-center justify-between bg-neutral-950">
          <div className="flex items-center gap-2.5">
            <img 
              src="/app-icon.png" 
              alt="EasyIPTV Icon" 
              className="w-7 h-7 rounded-lg object-cover shadow-sm border border-white/10"
              referrerPolicy="no-referrer"
            />
            <div>
              <h2 className="text-sm font-bold text-white leading-tight">EasyIPTV</h2>
              <p className="text-[10px] text-neutral-400 leading-none">iOS 16+ NavigationSplitView</p>
            </div>
          </div>
          <button
            onClick={onOpenLoader}
            className="w-8 h-8 rounded-full bg-blue-600 hover:bg-blue-500 text-white flex items-center justify-center transition-colors cursor-pointer shadow-md"
            title="Add M3U or Xtream"
          >
            <Plus className="w-4 h-4" />
          </button>
        </div>

        {/* 3 Main Categories Segmented Control (Live TV, Movies, TV Shows) */}
        <div className="p-2 bg-neutral-950 border-b border-neutral-900">
          <div className="grid grid-cols-3 gap-1 bg-neutral-900 p-1 rounded-xl">
            <button
              onClick={() => {
                onSelectSection('live');
                onSelectCategory('All');
              }}
              className={`py-1.5 rounded-lg text-[10px] font-bold flex items-center justify-center gap-1 transition-all cursor-pointer ${
                selectedSection === 'live'
                  ? 'bg-blue-600 text-white shadow-xs'
                  : 'text-neutral-400 hover:text-white'
              }`}
            >
              <Tv className="w-3 h-3" />
              <span>Live TV</span>
              <span className="text-[9px] opacity-75">({liveCount})</span>
            </button>

            <button
              onClick={() => {
                onSelectSection('movie');
                onSelectCategory('All');
              }}
              className={`py-1.5 rounded-lg text-[10px] font-bold flex items-center justify-center gap-1 transition-all cursor-pointer ${
                selectedSection === 'movie'
                  ? 'bg-purple-600 text-white shadow-xs'
                  : 'text-neutral-400 hover:text-white'
              }`}
            >
              <Film className="w-3 h-3" />
              <span>Movies</span>
              <span className="text-[9px] opacity-75">({movieCount})</span>
            </button>

            <button
              onClick={() => {
                onSelectSection('series');
                onSelectCategory('All');
              }}
              className={`py-1.5 rounded-lg text-[10px] font-bold flex items-center justify-center gap-1 transition-all cursor-pointer ${
                selectedSection === 'series'
                  ? 'bg-amber-600 text-white shadow-xs'
                  : 'text-neutral-400 hover:text-white'
              }`}
            >
              <Clapperboard className="w-3 h-3" />
              <span>Shows</span>
              <span className="text-[9px] opacity-75">({seriesCount})</span>
            </button>
          </div>
        </div>

        {/* Sub-view switcher based on Tab or Selected Channel */}
        <div className="flex-1 overflow-hidden flex flex-col">
          {activeTab === 'player' ? (
            <div className="flex-1 flex flex-col bg-black">
              {/* Back to list bar */}
              <div className="p-3 bg-neutral-900/90 flex items-center justify-between text-white border-b border-neutral-800">
                <button
                  onClick={() => setActiveTab('channels')}
                  className="flex items-center gap-1 text-xs text-blue-400 font-medium cursor-pointer"
                >
                  <ArrowLeft className="w-4 h-4" /> Back to List
                </button>
                <span className="text-xs font-semibold truncate max-w-[170px]">
                  {currentChannel?.name || 'Player'}
                </span>
                <div className="w-4" />
              </div>

              {/* Player Stage */}
              <div className="flex-1">
                <InteractivePlayer
                  channel={currentChannel}
                  isFavorite={currentChannel ? isFavorite(currentChannel) : false}
                  onToggleFavorite={() => currentChannel && onToggleFavorite(currentChannel)}
                />
              </div>
            </div>
          ) : (
            <div className="flex-1 flex flex-col overflow-hidden">
              {/* Category Pills Bar */}
              <div className="py-2 px-3 overflow-x-auto flex gap-1.5 shrink-0 no-scrollbar border-b border-neutral-900 bg-neutral-950">
                {allCategories.map(cat => {
                  const isSelected = selectedCategory === cat;
                  return (
                    <button
                      key={cat}
                      onClick={() => onSelectCategory(cat)}
                      className={`px-3 py-1 rounded-full text-[11px] font-medium whitespace-nowrap transition-colors cursor-pointer ${
                        isSelected 
                          ? 'bg-blue-600 text-white shadow-sm' 
                          : 'bg-neutral-900 text-neutral-400 hover:text-white'
                      }`}
                    >
                      {cat === 'Favorites' ? '★ Favorites' : cat}
                    </button>
                  );
                })}
              </div>

              {/* iOS Search Bar */}
              <div className="p-2.5 bg-neutral-950 border-b border-neutral-900">
                <div className="relative">
                  <Search className="w-3.5 h-3.5 absolute left-3 top-2.5 text-neutral-500" />
                  <input
                    type="text"
                    placeholder={`Search in ${selectedSection === 'live' ? 'Live TV' : selectedSection === 'movie' ? 'Movies' : 'Shows'}...`}
                    value={searchQuery}
                    onChange={(e) => onSearchChange(e.target.value)}
                    className="w-full pl-8 pr-3 py-1.5 bg-neutral-900 border border-neutral-800 rounded-xl text-xs text-white placeholder:text-neutral-500 focus:outline-none"
                  />
                </div>
              </div>

              {/* Channel List */}
              <div className="flex-1 overflow-y-auto divide-y divide-neutral-900">
                {filteredChannels.length === 0 ? (
                  <div className="p-8 text-center flex flex-col items-center justify-center h-full text-neutral-500 text-xs">
                    <Radio className="w-8 h-8 text-neutral-600 mb-2 opacity-60" />
                    <p className="font-medium text-neutral-400">
                      {channels.length === 0 ? 'No Playlist Loaded' : 'No channels found'}
                    </p>
                    <p className="text-[11px] text-neutral-500 mt-1 max-w-[200px]">
                      {channels.length === 0 
                        ? 'Tap + above to add your M3U playlist or login with Xtream Codes.'
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
                  filteredChannels.map(channel => {
                    const isFav = isFavorite(channel);
                    const isCurrent = currentChannel?.id === channel.id;

                    return (
                      <div
                        key={channel.id}
                        onClick={() => {
                          onSelectChannel(channel);
                          setActiveTab('player');
                        }}
                        className={`p-3 flex items-center gap-3 transition-colors cursor-pointer ${
                          isCurrent ? 'bg-blue-950/40' : 'hover:bg-neutral-900/50'
                        }`}
                      >
                        {/* Logo */}
                        {channel.logoURL ? (
                          <img
                            src={
                              typeof window !== 'undefined' && window.location.protocol === 'https:' && channel.logoURL.startsWith('http://')
                                ? `/api/proxy-image?url=${encodeURIComponent(channel.logoURL)}`
                                : channel.logoURL
                            }
                            alt=""
                            className="w-10 h-10 rounded-lg object-contain bg-neutral-900 border border-neutral-800 p-0.5 shrink-0"
                            onError={(e) => { (e.target as HTMLElement).style.display = 'none'; }}
                          />
                        ) : (
                          <div className="w-10 h-10 rounded-lg bg-neutral-900 border border-neutral-800 flex items-center justify-center text-neutral-500 shrink-0">
                            {channel.contentType === 'movie' ? (
                              <Film className="w-4 h-4 text-purple-400" />
                            ) : channel.contentType === 'series' ? (
                              <Clapperboard className="w-4 h-4 text-amber-400" />
                            ) : (
                              <Radio className="w-4 h-4" />
                            )}
                          </div>
                        )}

                        {/* Title & Group */}
                        <div className="flex-1 min-w-0">
                          <div className="text-xs font-semibold text-white truncate">
                            {channel.name}
                          </div>
                          <div className="text-[10px] text-neutral-400 mt-0.5 flex items-center gap-1.5">
                            <span className="truncate">{channel.groupTitle}</span>
                            <span>•</span>
                            <span className="text-neutral-500 font-mono text-[9px] uppercase">
                              {channel.contentType === 'movie' ? 'VOD' : channel.contentType === 'series' ? 'SERIES' : 'LIVE'}
                            </span>
                          </div>
                        </div>

                        {/* Star Favorite */}
                        <button
                          onClick={(e) => {
                            e.stopPropagation();
                            onToggleFavorite(channel);
                          }}
                          className="p-1 text-neutral-500 hover:text-amber-400"
                        >
                          <Star className={`w-4 h-4 ${isFav ? 'fill-amber-400 text-amber-400' : ''}`} />
                        </button>

                        <ChevronRight className="w-4 h-4 text-neutral-600" />
                      </div>
                    );
                  })
                )}
              </div>
            </div>
          )}
        </div>

        {/* iOS Bottom Tab Bar */}
        <div className="h-14 bg-neutral-950/95 backdrop-blur-md border-t border-neutral-900 flex items-center justify-around px-2 z-20">
          <button
            onClick={() => setActiveTab('channels')}
            className={`flex flex-col items-center gap-1 cursor-pointer transition-colors ${
              activeTab === 'channels' ? 'text-blue-500' : 'text-neutral-500 hover:text-neutral-300'
            }`}
          >
            <Tv className="w-4 h-4" />
            <span className="text-[10px] font-medium">Browse</span>
          </button>

          <button
            onClick={() => {
              if (currentChannel) setActiveTab('player');
            }}
            className={`flex flex-col items-center gap-1 cursor-pointer transition-colors ${
              activeTab === 'player' ? 'text-blue-500' : 'text-neutral-500 hover:text-neutral-300'
            }`}
          >
            <Radio className="w-4 h-4" />
            <span className="text-[10px] font-medium">Now Playing</span>
          </button>

          <button
            onClick={() => {
              setActiveTab('favorites');
              onSelectCategory('★ Favorites');
            }}
            className={`flex flex-col items-center gap-1 cursor-pointer transition-colors ${
              activeTab === 'favorites' ? 'text-blue-500' : 'text-neutral-500 hover:text-neutral-300'
            }`}
          >
            <Star className="w-4 h-4" />
            <span className="text-[10px] font-medium">Favorites</span>
          </button>
        </div>

        {/* Home Indicator */}
        <div className="h-4 bg-neutral-950 flex items-center justify-center pb-1">
          <div className="w-32 h-1 bg-white/30 rounded-full" />
        </div>

      </div>
    </div>
  );
};
