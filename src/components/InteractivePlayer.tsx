import React, { useEffect, useRef, useState, useCallback } from 'react';
import Hls from 'hls.js';
import { ChannelItem, XtreamAccountInfo } from '../types/iptv';
import { LiveEPGModal } from './LiveEPGModal';
import { 
  Play, Pause, Volume2, VolumeX, Maximize2, Minimize2, 
  RotateCcw, RotateCw, Star, Radio, AlertTriangle, Loader2, ShieldCheck,
  Zap, Film, Clapperboard, Tv, FastForward, Rewind, Calendar, Sliders, Check, RefreshCw
} from 'lucide-react';

interface InteractivePlayerProps {
  channel: ChannelItem | null;
  isFavorite?: boolean;
  onToggleFavorite?: () => void;
  onNextChannel?: () => void;
  onPrevChannel?: () => void;
  onBackToSeriesOverview?: () => void;
  xtreamAccount?: XtreamAccountInfo | null;
}

function formatTime(seconds: number): string {
  if (!seconds || isNaN(seconds) || !isFinite(seconds)) return '00:00';
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) {
    return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  }
  return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
}

export const InteractivePlayer: React.FC<InteractivePlayerProps> = ({
  channel,
  isFavorite,
  onToggleFavorite,
  onNextChannel,
  onPrevChannel,
  onBackToSeriesOverview,
  xtreamAccount
}) => {
  const videoRef = useRef<HTMLVideoElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  const [isPlaying, setIsPlaying] = useState(false);
  const [isMuted, setIsMuted] = useState(false);
  const [volume, setVolume] = useState(0.85);
  const [isBuffering, setIsBuffering] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [showControls, setShowControls] = useState(true);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [isInAppFullscreen, setIsInAppFullscreen] = useState(false);
  const [aspectRatio, setAspectRatio] = useState<'contain' | 'cover'>('contain');
  const [useProxy, setUseProxy] = useState(false);
  const [formatOverride, setFormatOverride] = useState<'auto' | 'mp4' | 'mkv' | 'hls' | 'ts'>('auto');
  const [showFormatMenu, setShowFormatMenu] = useState(false);
  const [isEPGOpen, setIsEPGOpen] = useState(false);

  // VOD / MP4 specific playback states
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [isSeeking, setIsSeeking] = useState(false);

  const hideControlsTimeout = useRef<number | null>(null);

  const isHttpsOrigin = typeof window !== 'undefined' && window.location.protocol === 'https:';
  let rawUrl = channel?.streamURL || '';

  // Apply format override extension if chosen for VOD movies or episodes
  if (formatOverride !== 'auto' && rawUrl) {
    if (formatOverride === 'mp4') {
      rawUrl = rawUrl.replace(/\.(mkv|avi|ts|m3u8)$/i, '.mp4');
    } else if (formatOverride === 'mkv') {
      rawUrl = rawUrl.replace(/\.(mp4|avi|ts|m3u8)$/i, '.mkv');
    } else if (formatOverride === 'ts') {
      rawUrl = rawUrl.replace(/\.(mp4|mkv|avi|m3u8)$/i, '.ts');
    } else if (formatOverride === 'hls') {
      rawUrl = rawUrl.replace(/\.(mp4|mkv|avi|ts)$/i, '.m3u8');
    }
  }

  const isHttpStream = rawUrl.toLowerCase().startsWith('http://');
  const isVOD = channel?.contentType === 'movie' || channel?.contentType === 'series' || rawUrl.toLowerCase().includes('.mp4') || rawUrl.toLowerCase().includes('.mkv');
  
  // For web clients, proxy is enabled for external streams to bypass CORS, add Range headers, and prevent mixed-content blocks
  const shouldProxy = useProxy || isHttpsOrigin || isHttpStream || rawUrl.startsWith('http');

  // Fullscreen toggle: YouTube-style full viewport coverage hiding all sidebars and chrome
  const toggleFullscreen = useCallback(() => {
    if (!containerRef.current) return;

    // Check if we are currently in native fullscreen
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(() => {});
      setIsFullscreen(false);
      setIsInAppFullscreen(false);
      return;
    }

    // Check if we are in in-app fullscreen
    if (isInAppFullscreen) {
      setIsInAppFullscreen(false);
      setIsFullscreen(false);
      return;
    }

    // Activate in-app theater fullscreen first so video instantly fills 100% viewport and hides sidebars
    setIsInAppFullscreen(true);
    setIsFullscreen(true);

    // Also try browser native requestFullscreen
    containerRef.current.requestFullscreen().catch(() => {
      // In-app fullscreen is already active
    });
  }, [isInAppFullscreen]);

  // Sync fullscreen change events from browser
  useEffect(() => {
    const handleFullscreenChange = () => {
      const isNative = !!document.fullscreenElement;
      setIsFullscreen(isNative || isInAppFullscreen);
      if (!isNative && !isInAppFullscreen) {
        setIsFullscreen(false);
      }
    };
    document.addEventListener('fullscreenchange', handleFullscreenChange);
    return () => {
      document.removeEventListener('fullscreenchange', handleFullscreenChange);
    };
  }, [isInAppFullscreen]);

  // Keyboard Shortcuts (F for fullscreen, Space for play/pause, ArrowLeft/Right for seeking)
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (['INPUT', 'TEXTAREA'].includes((e.target as HTMLElement)?.tagName)) return;

      if (e.key === 'f' || e.key === 'F') {
        e.preventDefault();
        toggleFullscreen();
      } else if (e.key === ' ' || e.code === 'Space') {
        e.preventDefault();
        togglePlay();
      } else if (e.key === 'Escape') {
        if (isInAppFullscreen) {
          setIsInAppFullscreen(false);
          setIsFullscreen(false);
        }
      } else if (e.key === 'm' || e.key === 'M') {
        toggleMute();
      } else if (e.key === 'ArrowRight') {
        seekBy(10);
      } else if (e.key === 'ArrowLeft') {
        seekBy(-10);
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [toggleFullscreen, isInAppFullscreen, isPlaying]);

  // Initialize and attach stream
  useEffect(() => {
    if (!channel || !videoRef.current) return;

    setErrorMsg(null);
    setIsBuffering(true);
    setCurrentTime(0);
    setDuration(0);

    const video = videoRef.current;
    let hls: Hls | null = null;

    // Determine target URL: direct or proxied through /api/proxy-stream
    const targetUrl = !rawUrl
      ? ''
      : rawUrl.startsWith('/api/')
        ? rawUrl
        : shouldProxy
          ? `/api/proxy-stream?url=${encodeURIComponent(rawUrl)}`
          : rawUrl;

    const isHlsStream = rawUrl.toLowerCase().includes('.m3u8') || targetUrl.includes('.m3u8');

    if (isHlsStream && Hls.isSupported()) {
      hls = new Hls({
        enableWorker: true,
        lowLatencyMode: true,
        backBufferLength: 90,
        xhrSetup: (xhr) => {
          xhr.withCredentials = false;
        }
      });

      hls.loadSource(targetUrl);
      hls.attachMedia(video);

      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        setIsBuffering(false);
        video.play().catch(() => {
          video.muted = true;
          setIsMuted(true);
          video.play().catch(() => setIsPlaying(false));
        });
      });

      hls.on(Hls.Events.ERROR, (_, data) => {
        if (data.fatal) {
          switch (data.type) {
            case Hls.ErrorTypes.NETWORK_ERROR:
              setErrorMsg(
                useProxy
                  ? 'Network error: Stream unreachable or connection closed by IPTV provider.'
                  : 'Network error: Stream blocked by browser CORS or HTTP mixed-content. Try enabling Proxy Bypass.'
              );
              hls?.startLoad();
              break;
            case Hls.ErrorTypes.MEDIA_ERROR:
              setErrorMsg('Media stream error encountered. Attempting recovery...');
              hls?.recoverMediaError();
              break;
            default:
              setErrorMsg('Stream playback stopped. Provider server may be offline.');
              hls?.destroy();
              break;
          }
          setIsBuffering(false);
        }
      });
    } else if (isHlsStream && video.canPlayType('application/vnd.apple.mpegurl')) {
      // Native Apple WebKit / Safari HLS
      video.src = targetUrl;
      video.play().catch(() => {
        video.muted = true;
        setIsMuted(true);
        video.play().catch(() => setIsPlaying(false));
      });
    } else {
      // MP4 / Direct Progressive Stream Playback
      video.removeAttribute('crossorigin');
      video.preload = 'auto';
      video.src = targetUrl;
      video.load();
      video.play().catch(() => {
        // Autoplay policy fallback: mute and play
        video.muted = true;
        setIsMuted(true);
        video.play().catch(() => setIsPlaying(false));
      });
    }

    const onPlay = () => {
      setIsPlaying(true);
      setIsBuffering(false);
    };
    const onPause = () => setIsPlaying(false);
    const onWaiting = () => setIsBuffering(true);
    const onPlaying = () => setIsBuffering(false);
    const onLoadedMetadata = () => {
      if (video.duration && isFinite(video.duration)) {
        setDuration(video.duration);
      }
    };
    const onTimeUpdate = () => {
      if (!isSeeking) {
        setCurrentTime(video.currentTime);
      }
      if (video.duration && isFinite(video.duration) && (!duration || duration === 0)) {
        setDuration(video.duration);
      }
    };
    const onError = () => {
      setIsBuffering(false);
      // If direct stream failed on an HTTP stream, suggest or auto-fallback to proxy
      if (!useProxy && !shouldProxy) {
        setErrorMsg('Direct stream connection failed. Switching to proxy stream bypass...');
        setUseProxy(true);
      } else {
        setErrorMsg(
          'Could not load stream. The remote IPTV server may be unreachable, offline, or requires active credentials.'
        );
      }
    };

    video.addEventListener('play', onPlay);
    video.addEventListener('pause', onPause);
    video.addEventListener('waiting', onWaiting);
    video.addEventListener('playing', onPlaying);
    video.addEventListener('loadedmetadata', onLoadedMetadata);
    video.addEventListener('timeupdate', onTimeUpdate);
    video.addEventListener('error', onError);

    return () => {
      if (hls) {
        hls.stopLoad();
        hls.detachMedia();
        hls.destroy();
        hls = null;
      }
      video.pause();
      video.removeAttribute('src');
      video.removeAttribute('crossorigin');
      video.load();
      video.removeEventListener('play', onPlay);
      video.removeEventListener('pause', onPause);
      video.removeEventListener('waiting', onWaiting);
      video.removeEventListener('playing', onPlaying);
      video.removeEventListener('loadedmetadata', onLoadedMetadata);
      video.removeEventListener('timeupdate', onTimeUpdate);
      video.removeEventListener('error', onError);
    };
  }, [channel, useProxy, isSeeking, duration]);

  // Auto-hide controls
  const handleMouseMove = () => {
    setShowControls(true);
    if (hideControlsTimeout.current) {
      window.clearTimeout(hideControlsTimeout.current);
    }
    hideControlsTimeout.current = window.setTimeout(() => {
      if (isPlaying) {
        setShowControls(false);
      }
    }, 3500);
  };

  const togglePlay = () => {
    if (!videoRef.current) return;
    if (isPlaying) {
      videoRef.current.pause();
    } else {
      videoRef.current.play().catch(() => {});
    }
  };

  const toggleMute = () => {
    if (!videoRef.current) return;
    const nextMuted = !isMuted;
    videoRef.current.muted = nextMuted;
    setIsMuted(nextMuted);
  };

  const handleVolumeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = parseFloat(e.target.value);
    setVolume(val);
    if (videoRef.current) {
      videoRef.current.volume = val;
      if (val === 0) {
        videoRef.current.muted = true;
        setIsMuted(true);
      } else if (isMuted) {
        videoRef.current.muted = false;
        setIsMuted(false);
      }
    }
  };

  // VOD Seek Slider Handlers
  const handleSeekChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const targetSec = parseFloat(e.target.value);
    setCurrentTime(targetSec);
    setIsSeeking(true);
  };

  const handleSeekCommit = () => {
    if (videoRef.current && isFinite(currentTime)) {
      videoRef.current.currentTime = currentTime;
    }
    setIsSeeking(false);
  };

  const seekBy = (seconds: number) => {
    if (!videoRef.current) return;
    const next = Math.max(0, Math.min(videoRef.current.duration || 999999, videoRef.current.currentTime + seconds));
    videoRef.current.currentTime = next;
    setCurrentTime(next);
  };

  const retryPlayback = (forceProxy?: boolean) => {
    if (!videoRef.current || !channel) return;
    setErrorMsg(null);
    setIsBuffering(true);
    if (typeof forceProxy === 'boolean') {
      setUseProxy(forceProxy);
    } else {
      videoRef.current.load();
      videoRef.current.play().catch(() => {});
    }
  };

  if (!channel) {
    return (
      <div className="h-full w-full bg-neutral-950 flex flex-col items-center justify-center text-center p-8">
        <div className="w-16 h-16 rounded-2xl bg-neutral-900 border border-neutral-800 flex items-center justify-center text-neutral-500 mb-4 shadow-xl">
          <Radio className="w-8 h-8" />
        </div>
        <h3 className="text-lg font-semibold text-neutral-200">No Stream Active</h3>
        <p className="text-sm text-neutral-400 max-w-sm mt-1">
          Select a channel, movie, or series from the list or load an M3U playlist / Xtream account to begin streaming.
        </p>
      </div>
    );
  }

  return (
    <div 
      ref={containerRef}
      onMouseMove={handleMouseMove}
      className={`relative select-none overflow-hidden group flex items-center justify-center bg-black transition-all ${
        isInAppFullscreen 
          ? 'fixed inset-0 z-[9999] w-screen h-screen' 
          : 'w-full h-full'
      }`}
    >
      {/* Video Element */}
      <video
        ref={videoRef}
        playsInline
        className={`w-full h-full ${aspectRatio === 'cover' ? 'object-cover' : 'object-contain'}`}
        onClick={togglePlay}
        onDoubleClick={toggleFullscreen}
      />

      {/* Buffering Indicator */}
      {isBuffering && !errorMsg && (
        <div className="absolute inset-0 flex flex-col items-center justify-center bg-black/60 backdrop-blur-xs pointer-events-none transition-opacity z-20">
          <Loader2 className="w-10 h-10 text-blue-400 animate-spin mb-3" />
          <span className="text-xs uppercase tracking-widest font-semibold text-white/90">
            Buffering Stream…
          </span>
        </div>
      )}

      {/* Error Notice View */}
      {errorMsg && (
        <div className="absolute inset-0 flex flex-col items-center justify-center bg-black/90 backdrop-blur-md p-6 text-center z-30">
          <div className="w-12 h-12 rounded-full bg-amber-500/20 text-amber-400 flex items-center justify-center mb-3">
            <AlertTriangle className="w-6 h-6" />
          </div>
          <h4 className="text-base font-semibold text-white">Stream Playback Notice</h4>
          <p className="text-xs text-neutral-300 max-w-md mt-1 mb-4 leading-relaxed">
            {errorMsg}
          </p>

          {/* Quick Format & Recovery Actions */}
          <div className="flex flex-wrap items-center justify-center gap-2 max-w-lg mb-3">
            <button
              onClick={() => {
                setFormatOverride('mp4');
                retryPlayback(true);
              }}
              className="px-3 py-1.5 bg-purple-600 hover:bg-purple-500 text-white text-xs font-semibold rounded-lg flex items-center gap-1.5 transition-colors cursor-pointer shadow-md"
            >
              <Film className="w-3.5 h-3.5" /> Try MP4 Stream
            </button>
            <button
              onClick={() => {
                setFormatOverride('mkv');
                retryPlayback(true);
              }}
              className="px-3 py-1.5 bg-indigo-600 hover:bg-indigo-500 text-white text-xs font-semibold rounded-lg flex items-center gap-1.5 transition-colors cursor-pointer shadow-md"
            >
              <Film className="w-3.5 h-3.5" /> Try MKV Format
            </button>
            <button
              onClick={() => {
                setFormatOverride('hls');
                retryPlayback(true);
              }}
              className="px-3 py-1.5 bg-blue-600 hover:bg-blue-500 text-white text-xs font-semibold rounded-lg flex items-center gap-1.5 transition-colors cursor-pointer shadow-md"
            >
              <Tv className="w-3.5 h-3.5" /> Try HLS (.m3u8)
            </button>
          </div>

          <div className="flex flex-wrap items-center justify-center gap-2">
            <button
              onClick={() => retryPlayback(!useProxy)}
              className="px-3.5 py-1.5 bg-neutral-800 hover:bg-neutral-700 text-white text-xs font-semibold rounded-lg flex items-center gap-1.5 transition-colors cursor-pointer border border-neutral-700"
            >
              <Zap className="w-3.5 h-3.5" />
              {useProxy ? 'Switch to Direct Stream' : 'Try Proxy Bypass'}
            </button>
            <button
              onClick={() => retryPlayback()}
              className="px-3 py-1.5 bg-neutral-800 hover:bg-neutral-700 text-white text-xs font-semibold rounded-lg flex items-center gap-1.5 transition-colors cursor-pointer border border-neutral-700"
            >
              <RotateCcw className="w-3.5 h-3.5" /> Retry
            </button>
          </div>
        </div>
      )}

      {/* Top HUD Overlay */}
      <div 
        className={`absolute top-0 inset-x-0 p-4 bg-gradient-to-b from-black/90 via-black/50 to-transparent transition-opacity duration-300 flex items-center justify-between pointer-events-auto z-20 ${
          showControls ? 'opacity-100' : 'opacity-0 pointer-events-none'
        }`}
      >
        <div className="flex items-center gap-3 min-w-0">
          {channel.logoURL ? (
            <img 
              src={
                isHttpsOrigin && channel.logoURL.startsWith('http://')
                  ? `/api/proxy-image?url=${encodeURIComponent(channel.logoURL)}`
                  : channel.logoURL
              } 
              alt={channel.name} 
              className="w-10 h-10 rounded-lg object-contain bg-neutral-900 border border-neutral-700/50 p-1 shrink-0"
              onError={(e) => { (e.target as HTMLElement).style.display = 'none'; }}
            />
          ) : (
            <div className="w-10 h-10 rounded-lg bg-neutral-800 border border-neutral-700/50 flex items-center justify-center text-neutral-400 shrink-0">
              {channel.contentType === 'movie' ? <Film className="w-5 h-5 text-purple-400" /> :
               channel.contentType === 'series' ? <Clapperboard className="w-5 h-5 text-amber-400" /> :
               <Radio className="w-5 h-5" />}
            </div>
          )}

          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <h2 className="text-sm font-semibold text-white truncate max-w-xs md:max-w-md">
                {channel.name}
              </h2>
              {channel.contentType === 'movie' ? (
                <span className="flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-bold bg-purple-600/90 text-white tracking-wider">
                  🎬 MOVIE (VOD)
                </span>
              ) : channel.contentType === 'series' ? (
                <span className="flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-bold bg-amber-600/90 text-white tracking-wider">
                  🍿 TV SHOW
                </span>
              ) : (
                <span className="flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-bold bg-red-600/90 text-white tracking-wider">
                  <span className="w-1.5 h-1.5 rounded-full bg-white animate-pulse" /> LIVE
                </span>
              )}
            </div>
            <p className="text-xs text-neutral-400 truncate mt-0.5">
              {channel.groupTitle} • {isVOD ? 'MP4 Video Stream' : 'Live HLS (m3u8)'}
            </p>
          </div>
        </div>

        {/* Top Action buttons */}
        <div className="flex items-center gap-2 shrink-0 relative">
          
          {/* Back to Series Details Button (When watching a TV Show episode) */}
          {onBackToSeriesOverview && (
            <button
              onClick={onBackToSeriesOverview}
              className="px-2.5 py-1.5 rounded-lg bg-blue-600 hover:bg-blue-500 text-white text-xs font-bold flex items-center gap-1.5 transition-colors cursor-pointer shadow-sm border border-blue-400/40"
              title="Return to TV Series Overview & Seasons"
            >
              <RotateCcw className="w-3.5 h-3.5" />
              <span>Back to Series Details</span>
            </button>
          )}

          {/* Live TV EPG Schedule Guide Button */}
          {(!channel.contentType || channel.contentType === 'live') && (
            <button
              onClick={() => setIsEPGOpen(true)}
              className="px-2.5 py-1.5 rounded-lg bg-red-600/80 hover:bg-red-600 text-white text-xs font-semibold flex items-center gap-1.5 transition-colors cursor-pointer shadow-xs border border-red-500/40"
              title="Open Live TV Program Guide / EPG"
            >
              <Calendar className="w-3.5 h-3.5" />
              <span>TV Guide</span>
            </button>
          )}

          {/* Movie / Stream Playback Options & Format Menu */}
          <div className="relative">
            <button
              onClick={() => setShowFormatMenu(!showFormatMenu)}
              className="px-2.5 py-1.5 rounded-lg bg-black/40 hover:bg-neutral-800/80 text-white text-xs border border-white/10 transition-colors cursor-pointer flex items-center gap-1.5"
              title="Stream Playback Format & Troubleshooting Options"
            >
              <Sliders className="w-3.5 h-3.5 text-neutral-300" />
              <span className="hidden sm:inline">Format</span>
            </button>

            {showFormatMenu && (
              <div className="absolute right-0 mt-2 w-56 bg-neutral-900 border border-neutral-800 rounded-xl shadow-2xl p-2 z-50 text-xs space-y-1 animate-in fade-in zoom-in-95">
                <div className="px-2 py-1 text-[10px] font-bold uppercase tracking-wider text-neutral-400 border-b border-neutral-800 mb-1">
                  Stream Format Options
                </div>
                {[
                  { id: 'auto', label: 'Auto Negotiate', desc: 'Recommended default' },
                  { id: 'mp4', label: 'Force MP4 Stream', desc: 'Standard video stream' },
                  { id: 'mkv', label: 'Force MKV Format', desc: 'Matroska VOD stream' },
                  { id: 'hls', label: 'Apple HLS (.m3u8)', desc: 'Adaptive bitrate stream' },
                  { id: 'ts', label: 'Direct MPEG-TS', desc: 'Raw transport stream' }
                ].map((fmt) => (
                  <button
                    key={fmt.id}
                    onClick={() => {
                      setFormatOverride(fmt.id as any);
                      setShowFormatMenu(false);
                      retryPlayback();
                    }}
                    className={`w-full text-left px-2 py-1.5 rounded-lg flex items-center justify-between transition-colors cursor-pointer ${
                      formatOverride === fmt.id ? 'bg-blue-600 text-white' : 'text-neutral-300 hover:bg-neutral-800'
                    }`}
                  >
                    <div>
                      <div className="font-semibold">{fmt.label}</div>
                      <div className="text-[10px] opacity-70">{fmt.desc}</div>
                    </div>
                    {formatOverride === fmt.id && <Check className="w-3.5 h-3.5" />}
                  </button>
                ))}

                <div className="pt-1 border-t border-neutral-800 mt-1">
                  <button
                    onClick={() => {
                      setUseProxy(!useProxy);
                      setShowFormatMenu(false);
                      retryPlayback(!useProxy);
                    }}
                    className="w-full text-left px-2 py-1.5 rounded-lg text-neutral-300 hover:bg-neutral-800 flex items-center justify-between cursor-pointer"
                  >
                    <span>HTTPS Proxy Bypass</span>
                    <span className={`text-[10px] px-1.5 py-0.5 rounded font-mono ${shouldProxy ? 'bg-green-500/20 text-green-400' : 'bg-neutral-800 text-neutral-400'}`}>
                      {shouldProxy ? 'Active' : 'Off'}
                    </span>
                  </button>
                </div>
              </div>
            )}
          </div>

          {/* Aspect Fit/Fill */}
          <button
            onClick={() => setAspectRatio(a => a === 'contain' ? 'cover' : 'contain')}
            className="px-2.5 py-1.5 rounded-lg bg-black/40 hover:bg-neutral-800/80 text-white text-xs border border-white/10 transition-colors cursor-pointer"
            title="Toggle Aspect Ratio (Fit / Fill)"
          >
            {aspectRatio === 'contain' ? 'Fit' : 'Fill'}
          </button>

          {/* Favorite toggle */}
          <button
            onClick={onToggleFavorite}
            className={`p-2 rounded-lg border transition-colors cursor-pointer ${
              isFavorite 
                ? 'bg-amber-500/20 border-amber-500/50 text-amber-400' 
                : 'bg-black/40 border-white/10 text-white/70 hover:text-white hover:bg-neutral-800/80'
            }`}
            title={isFavorite ? 'Remove Favorite' : 'Add to Favorites'}
          >
            <Star className={`w-4 h-4 ${isFavorite ? 'fill-amber-400' : ''}`} />
          </button>

          {/* Dedicated Fullscreen Toggle in Top Bar */}
          <button
            onClick={toggleFullscreen}
            className="p-2 rounded-lg bg-blue-600/80 hover:bg-blue-600 text-white text-xs border border-blue-400/40 transition-colors cursor-pointer flex items-center gap-1 shadow-xs"
            title={isFullscreen ? 'Exit Full Screen (Esc / F)' : 'Enter Full Screen (F)'}
          >
            {isFullscreen ? <Minimize2 className="w-4 h-4" /> : <Maximize2 className="w-4 h-4" />}
            <span className="hidden md:inline font-medium">
              {isFullscreen ? 'Exit Full' : 'Full Screen'}
            </span>
          </button>
        </div>
      </div>

      {/* Live EPG Schedule Modal */}
      <LiveEPGModal
        channel={channel}
        xtreamAccount={xtreamAccount}
        isOpen={isEPGOpen}
        onClose={() => setIsEPGOpen(false)}
      />

      {/* Center Play Button Overlay on Pause */}
      {!isPlaying && !isBuffering && !errorMsg && (
        <button
          onClick={togglePlay}
          className="absolute w-16 h-16 rounded-full bg-white/20 hover:bg-white/30 backdrop-blur-md text-white flex items-center justify-center transition-transform hover:scale-105 cursor-pointer shadow-2xl border border-white/30 z-20"
        >
          <Play className="w-8 h-8 ml-1 fill-white" />
        </button>
      )}

      {/* Bottom Controls Bar */}
      <div 
        className={`absolute bottom-0 inset-x-0 p-4 bg-gradient-to-t from-black/95 via-black/70 to-transparent transition-opacity duration-300 flex flex-col gap-2.5 pointer-events-auto z-20 ${
          showControls ? 'opacity-100' : 'opacity-0 pointer-events-none'
        }`}
      >
        {/* VOD MP4 Timeline Scrubber (Seek Bar) */}
        {isVOD && (
          <div className="flex items-center gap-3 w-full">
            <span className="text-[11px] font-mono text-neutral-300 shrink-0 w-12 text-right">
              {formatTime(currentTime)}
            </span>
            <input
              type="range"
              min={0}
              max={duration > 0 ? duration : 100}
              step={1}
              value={currentTime}
              onChange={handleSeekChange}
              onMouseUp={handleSeekCommit}
              onTouchEnd={handleSeekCommit}
              className="flex-1 h-1.5 bg-white/20 hover:bg-white/30 rounded-lg appearance-none cursor-pointer accent-blue-500"
              title="Seek progress"
            />
            <span className="text-[11px] font-mono text-neutral-400 shrink-0 w-12">
              {duration > 0 ? formatTime(duration) : 'Live / VOD'}
            </span>
          </div>
        )}

        {/* Lower Transport & Action Row */}
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2 sm:gap-3">
            {/* Play / Pause */}
            <button
              onClick={togglePlay}
              className="p-2 rounded-lg bg-white text-black hover:bg-neutral-200 transition-colors cursor-pointer"
              title={isPlaying ? 'Pause (Space)' : 'Play (Space)'}
            >
              {isPlaying ? <Pause className="w-4 h-4 fill-black" /> : <Play className="w-4 h-4 fill-black ml-0.5" />}
            </button>

            {/* VOD Skip Backward & Forward 10s */}
            {isVOD && (
              <>
                <button
                  onClick={() => seekBy(-10)}
                  className="p-2 rounded-lg hover:bg-white/10 text-white/80 hover:text-white transition-colors cursor-pointer flex items-center"
                  title="Rewind 10s (Left Arrow)"
                >
                  <RotateCcw className="w-4 h-4" />
                  <span className="text-[10px] ml-1 font-mono">10s</span>
                </button>
                <button
                  onClick={() => seekBy(10)}
                  className="p-2 rounded-lg hover:bg-white/10 text-white/80 hover:text-white transition-colors cursor-pointer flex items-center"
                  title="Forward 10s (Right Arrow)"
                >
                  <RotateCw className="w-4 h-4" />
                  <span className="text-[10px] ml-1 font-mono">10s</span>
                </button>
              </>
            )}

            {/* Volume Control */}
            <div className="flex items-center gap-2 text-white">
              <button
                onClick={toggleMute}
                className="p-2 rounded-lg hover:bg-white/10 transition-colors cursor-pointer text-white/80 hover:text-white"
                title={isMuted ? 'Unmute (M)' : 'Mute (M)'}
              >
                {isMuted || volume === 0 ? <VolumeX className="w-4 h-4" /> : <Volume2 className="w-4 h-4" />}
              </button>
              <input
                type="range"
                min="0"
                max="1"
                step="0.05"
                value={isMuted ? 0 : volume}
                onChange={handleVolumeChange}
                className="w-16 sm:w-20 h-1 bg-white/20 rounded-lg appearance-none cursor-pointer accent-white"
              />
            </div>

            <span className="hidden md:inline-block text-[11px] font-mono text-neutral-400">
              {isVOD ? 'MP4 Video' : 'AVPlayer Live HLS'} • {shouldProxy ? 'HTTPS Proxy' : 'Direct'}
            </span>
          </div>

          <div className="flex items-center gap-2">
            {/* Primary Fullscreen Toggle */}
            <button
              onClick={toggleFullscreen}
              className="px-3 py-1.5 rounded-lg bg-white/15 hover:bg-white/25 text-white text-xs font-semibold flex items-center gap-1.5 border border-white/20 transition-all cursor-pointer"
              title={isFullscreen ? 'Exit Full Screen (Esc / F)' : 'Make Full Screen (F)'}
            >
              {isFullscreen ? <Minimize2 className="w-4 h-4" /> : <Maximize2 className="w-4 h-4" />}
              <span>{isFullscreen ? 'Exit Full Screen' : 'Full Screen'}</span>
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};
