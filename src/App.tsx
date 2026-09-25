import React, { useState, useEffect } from 'react';
import { ChannelItem, XtreamAccountInfo, ContentType } from './types/iptv';
import { SAMPLE_CHANNELS } from './utils/m3uParser';
import { SWIFT_FILES } from './data/swiftFiles';
import { MacSimulator } from './components/MacSimulator';
import { IOSSimulator } from './components/IOSSimulator';
import { SwiftCodeViewer } from './components/SwiftCodeViewer';
import { ArchitectureGuide } from './components/ArchitectureGuide';
import { M3ULoaderModal } from './components/M3ULoaderModal';
import { 
  Tv, Monitor, Smartphone, Code2, BookOpen, 
  Download, Globe, Sparkles, Star, Play, KeyRound, Server
} from 'lucide-react';

export default function App() {
  const [activeView, setActiveView] = useState<'simulator' | 'code' | 'docs'>('simulator');
  const [deviceMode, setDeviceMode] = useState<'mac' | 'ios'>('mac');
  
  // Channels, Content Sections, and Playback State with LocalStorage Persistence
  const [channels, setChannels] = useState<ChannelItem[]>(() => {
    try {
      const saved = localStorage.getItem('iptv_saved_channels');
      return saved ? JSON.parse(saved) : [];
    } catch {
      return [];
    }
  });

  const [selectedSection, setSelectedSection] = useState<ContentType>(() => {
    try {
      const saved = localStorage.getItem('iptv_selected_section') as ContentType;
      return (saved === 'live' || saved === 'movie' || saved === 'series') ? saved : 'live';
    } catch {
      return 'live';
    }
  });

  const [currentChannel, setCurrentChannel] = useState<ChannelItem | null>(null);
  const [selectedCategory, setSelectedCategory] = useState<string>('All');
  const [searchQuery, setSearchQuery] = useState<string>('');
  
  const [playlistSource, setPlaylistSource] = useState<string>(() => {
    return localStorage.getItem('iptv_playlist_source') || 'No Playlist Loaded';
  });

  const [xtreamAccount, setXtreamAccount] = useState<XtreamAccountInfo | null>(() => {
    try {
      const saved = localStorage.getItem('iptv_xtream_account');
      return saved ? JSON.parse(saved) : null;
    } catch {
      return null;
    }
  });

  const [favoriteIds, setFavoriteIds] = useState<Set<string>>(() => {
    try {
      const saved = localStorage.getItem('iptv_favorites');
      return saved ? new Set(JSON.parse(saved)) : new Set();
    } catch {
      return new Set();
    }
  });

  const [isLoaderOpen, setIsLoaderOpen] = useState(false);

  // Sync channels & playlist source to localStorage
  useEffect(() => {
    try {
      if (channels.length > 0) {
        localStorage.setItem('iptv_saved_channels', JSON.stringify(channels));
        localStorage.setItem('iptv_playlist_source', playlistSource);
      } else {
        localStorage.removeItem('iptv_saved_channels');
        localStorage.removeItem('iptv_playlist_source');
      }
    } catch (e) {
      console.warn('Failed to save channels to localStorage', e);
    }
  }, [channels, playlistSource]);

  // Sync selectedSection to localStorage
  useEffect(() => {
    try {
      localStorage.setItem('iptv_selected_section', selectedSection);
    } catch (e) {
      console.warn('Failed to save selected section', e);
    }
  }, [selectedSection]);

  // Sync xtreamAccount to localStorage
  useEffect(() => {
    try {
      if (xtreamAccount) {
        localStorage.setItem('iptv_xtream_account', JSON.stringify(xtreamAccount));
      } else {
        localStorage.removeItem('iptv_xtream_account');
      }
    } catch (e) {
      console.warn('Failed to save xtream account', e);
    }
  }, [xtreamAccount]);

  // Automatically activate first channel on initial load if restored
  useEffect(() => {
    if (channels.length > 0 && !currentChannel) {
      const sectionChannels = channels.filter(c => (c.contentType || 'live') === selectedSection);
      if (sectionChannels.length > 0) {
        setCurrentChannel(sectionChannels[0]);
      } else {
        setCurrentChannel(channels[0]);
      }
    }
  }, [channels, currentChannel, selectedSection]);

  // Sync favorites to localStorage
  useEffect(() => {
    try {
      localStorage.setItem('iptv_favorites', JSON.stringify(Array.from(favoriteIds)));
    } catch (e) {
      console.error('Failed to save favorites to localStorage', e);
    }
  }, [favoriteIds]);

  const toggleFavorite = (item: ChannelItem) => {
    setFavoriteIds(prev => {
      const next = new Set(prev);
      if (next.has(item.id)) {
        next.delete(item.id);
      } else {
        next.add(item.id);
      }
      return next;
    });
  };

  const isFavorite = (item: ChannelItem) => favoriteIds.has(item.id);

  const handleLoadChannels = (newChannels: ChannelItem[], sourceTitle: string) => {
    setChannels(newChannels);
    setPlaylistSource(sourceTitle);
    setSelectedCategory('All');
    setSearchQuery('');
    
    // Check if new channels have items for current section, or pick first available
    const sectionChannels = newChannels.filter(c => (c.contentType || 'live') === selectedSection);
    if (sectionChannels.length > 0) {
      setCurrentChannel(sectionChannels[0]);
    } else if (newChannels.length > 0) {
      const first = newChannels[0];
      setSelectedSection(first.contentType || 'live');
      setCurrentChannel(first);
    }
  };

  const handleClearPlaylist = () => {
    setChannels([]);
    setPlaylistSource('No Playlist Loaded');
    setXtreamAccount(null);
    setSelectedSection('live');
    setSelectedCategory('All');
    setSearchQuery('');
    setCurrentChannel(null);
    try {
      localStorage.removeItem('iptv_saved_channels');
      localStorage.removeItem('iptv_playlist_source');
      localStorage.removeItem('iptv_xtream_account');
    } catch (e) {
      console.warn('Failed to clear stored playlist', e);
    }
  };

  return (
    <div className="flex flex-col h-screen w-screen bg-neutral-950 text-neutral-100 overflow-hidden font-sans">
      
      {/* Top Global Navigation Bar */}
      <header className="h-14 border-b border-neutral-800 bg-neutral-900/90 backdrop-blur-md px-4 md:px-6 flex items-center justify-between shrink-0 select-none z-40">
        
        {/* Brand / Logo */}
        <div className="flex items-center gap-3">
          <img 
            src="/app-icon.png" 
            alt="EasyIPTV Pro Logo" 
            className="w-8 h-8 rounded-xl object-cover shadow-lg shadow-purple-500/20 border border-white/10" 
            referrerPolicy="no-referrer"
          />
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-sm font-bold text-white tracking-tight flex items-center gap-1.5">
                <span>EasyIPTV</span>
              </h1>
              <span className="hidden sm:inline-flex px-1.5 py-0.5 rounded text-[10px] font-semibold bg-blue-500/10 text-blue-400 border border-blue-500/20">
                iOS 16+ & macOS 13+
              </span>
            </div>
            <p className="text-[11px] text-neutral-400 hidden md:block">
              Native AVKit • Swift Concurrency • Xtream & M3U
            </p>
          </div>
        </div>

        {/* Center Primary Tab Buttons */}
        <div className="flex items-center gap-1 bg-neutral-950 p-1 rounded-xl border border-neutral-800">
          <button
            onClick={() => setActiveView('simulator')}
            className={`px-3 py-1.5 rounded-lg text-xs font-semibold transition-all flex items-center gap-1.5 cursor-pointer ${
              activeView === 'simulator'
                ? 'bg-blue-600 text-white shadow-sm'
                : 'text-neutral-400 hover:text-white hover:bg-neutral-900'
            }`}
          >
            <Play className="w-3.5 h-3.5 fill-current" />
            <span>Interactive Simulator</span>
          </button>

          <button
            onClick={() => setActiveView('code')}
            className={`px-3 py-1.5 rounded-lg text-xs font-semibold transition-all flex items-center gap-1.5 cursor-pointer ${
              activeView === 'code'
                ? 'bg-blue-600 text-white shadow-sm'
                : 'text-neutral-400 hover:text-white hover:bg-neutral-900'
            }`}
          >
            <Code2 className="w-3.5 h-3.5" />
            <span>Swift Source Code</span>
            <span className="px-1.5 py-0.2 rounded-full text-[9px] bg-neutral-800 text-neutral-300">
              {SWIFT_FILES.length} Files
            </span>
          </button>

          <button
            onClick={() => setActiveView('docs')}
            className={`px-3 py-1.5 rounded-lg text-xs font-semibold transition-all flex items-center gap-1.5 cursor-pointer ${
              activeView === 'docs'
                ? 'bg-blue-600 text-white shadow-sm'
                : 'text-neutral-400 hover:text-white hover:bg-neutral-900'
            }`}
          >
            <BookOpen className="w-3.5 h-3.5" />
            <span className="hidden sm:inline">Architecture & Guide</span>
            <span className="sm:hidden">Docs</span>
          </button>
        </div>

        {/* Right Action Bar (Device switcher & playlist modal trigger) */}
        <div className="flex items-center gap-2">
          {activeView === 'simulator' && (
            <div className="flex items-center bg-neutral-950 p-1 rounded-lg border border-neutral-800">
              <button
                onClick={() => setDeviceMode('mac')}
                className={`p-1.5 rounded-md transition-colors cursor-pointer ${
                  deviceMode === 'mac'
                    ? 'bg-neutral-800 text-white'
                    : 'text-neutral-500 hover:text-white'
                }`}
                title="macOS SplitView Preview"
              >
                <Monitor className="w-4 h-4" />
              </button>
              <button
                onClick={() => setDeviceMode('ios')}
                className={`p-1.5 rounded-md transition-colors cursor-pointer ${
                  deviceMode === 'ios'
                    ? 'bg-neutral-800 text-white'
                    : 'text-neutral-500 hover:text-white'
                }`}
                title="iOS iPhone Preview"
              >
                <Smartphone className="w-4 h-4" />
              </button>
            </div>
          )}

          {/* Active Playlist / Xtream badge */}
          {playlistSource !== 'Public Demo HLS Streams' && (
            <span className="hidden lg:inline-flex items-center gap-1 px-2 py-1 rounded-lg text-[11px] bg-blue-500/10 text-blue-300 border border-blue-500/20 truncate max-w-[170px]">
              <Server className="w-3 h-3 text-blue-400 shrink-0" />
              <span className="truncate">{playlistSource}</span>
            </span>
          )}

          <button
            onClick={() => setIsLoaderOpen(true)}
            className="px-3 py-1.5 rounded-lg bg-blue-600 hover:bg-blue-500 text-white text-xs font-semibold flex items-center gap-1.5 shadow-sm transition-colors cursor-pointer"
          >
            <KeyRound className="w-3.5 h-3.5" />
            <span className="hidden sm:inline">Add M3U / Xtream</span>
            <span className="sm:hidden">Add</span>
          </button>
        </div>

      </header>

      {/* Main Workspace Body */}
      <main className="flex-1 overflow-hidden p-3 md:p-4">
        {activeView === 'simulator' && (
          deviceMode === 'mac' ? (
            <MacSimulator
              channels={channels}
              currentChannel={currentChannel}
              selectedSection={selectedSection}
              onSelectSection={setSelectedSection}
              selectedCategory={selectedCategory}
              onSelectCategory={setSelectedCategory}
              searchQuery={searchQuery}
              onSearchChange={setSearchQuery}
              onSelectChannel={setCurrentChannel}
              onToggleFavorite={toggleFavorite}
              isFavorite={isFavorite}
              onOpenLoader={() => setIsLoaderOpen(true)}
              onClearPlaylist={handleClearPlaylist}
              xtreamAccount={xtreamAccount}
            />
          ) : (
            <div className="h-full w-full overflow-y-auto flex items-center justify-center p-2">
              <IOSSimulator
                channels={channels}
                currentChannel={currentChannel}
                selectedSection={selectedSection}
                onSelectSection={setSelectedSection}
                selectedCategory={selectedCategory}
                onSelectCategory={setSelectedCategory}
                searchQuery={searchQuery}
                onSearchChange={setSearchQuery}
                onSelectChannel={setCurrentChannel}
                onToggleFavorite={toggleFavorite}
                isFavorite={isFavorite}
                onOpenLoader={() => setIsLoaderOpen(true)}
              />
            </div>
          )
        )}

        {activeView === 'code' && (
          <SwiftCodeViewer />
        )}

        {activeView === 'docs' && (
          <div className="h-full rounded-2xl border border-neutral-800 bg-neutral-950 overflow-hidden shadow-2xl">
            <ArchitectureGuide />
          </div>
        )}
      </main>

      {/* M3U URL / Xtream Codes Loader Modal */}
      <M3ULoaderModal
        isOpen={isLoaderOpen}
        onClose={() => setIsLoaderOpen(false)}
        onLoadChannels={handleLoadChannels}
        onSaveXtreamInfo={setXtreamAccount}
      />

    </div>
  );
}

