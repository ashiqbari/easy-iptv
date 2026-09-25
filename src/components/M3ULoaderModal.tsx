import React, { useState, useEffect } from 'react';
import { 
  X, Globe, FileText, Check, AlertCircle, Sparkles, 
  KeyRound, Server, User, Lock, ExternalLink, RefreshCw,
  Clock, ShieldCheck, Download, History, Trash2
} from 'lucide-react';
import { ChannelItem, XtreamCredentials, XtreamAccountInfo } from '../types/iptv';
import { parseM3UString } from '../utils/m3uParser';

interface M3ULoaderModalProps {
  isOpen: boolean;
  onClose: () => void;
  onLoadChannels: (channels: ChannelItem[], sourceTitle: string) => void;
  onSaveXtreamInfo?: (info: XtreamAccountInfo | null) => void;
}

export const M3ULoaderModal: React.FC<M3ULoaderModalProps> = ({
  isOpen,
  onClose,
  onLoadChannels,
  onSaveXtreamInfo
}) => {
  const [tab, setTab] = useState<'m3u' | 'xtream' | 'raw'>('m3u');
  
  // M3U URL state
  const [urlInput, setUrlInput] = useState('');
  const [savedM3Us, setSavedM3Us] = useState<string[]>(() => {
    try {
      const saved = localStorage.getItem('iptv_saved_m3u_urls');
      return saved ? JSON.parse(saved) : [];
    } catch {
      return [];
    }
  });

  // Xtream Codes state
  const [xtreamServer, setXtreamServer] = useState('');
  const [xtreamUser, setXtreamUser] = useState('');
  const [xtreamPassword, setXtreamPassword] = useState('');
  const [savedXtream, setSavedXtream] = useState<XtreamCredentials | null>(() => {
    try {
      const saved = localStorage.getItem('iptv_saved_xtream_creds');
      return saved ? JSON.parse(saved) : null;
    } catch {
      return null;
    }
  });

  // Raw text state
  const [rawInput, setRawInput] = useState('');

  // UI state
  const [isLoading, setIsLoading] = useState(false);
  const [loadingStep, setLoadingStep] = useState<string>('');
  const [error, setError] = useState<string | null>(null);
  const [successInfo, setSuccessInfo] = useState<string | null>(null);
  const [xtreamAccount, setXtreamAccount] = useState<XtreamAccountInfo | null>(null);
  const [generatedM3UUrl, setGeneratedM3UUrl] = useState<string | null>(null);

  // Load saved inputs on mount
  useEffect(() => {
    if (savedXtream) {
      setXtreamServer(savedXtream.serverUrl);
      setXtreamUser(savedXtream.username);
      setXtreamPassword(savedXtream.password);
    }
    if (savedM3Us.length > 0 && !urlInput) {
      setUrlInput(savedM3Us[0]);
    }
  }, []);

  if (!isOpen) return null;

  // Persist M3U URL
  const persistM3UUrl = (url: string) => {
    try {
      const filtered = [url, ...savedM3Us.filter(u => u !== url)].slice(0, 5);
      setSavedM3Us(filtered);
      localStorage.setItem('iptv_saved_m3u_urls', JSON.stringify(filtered));
    } catch (e) {
      console.error(e);
    }
  };

  // Persist Xtream credentials
  const persistXtream = (creds: XtreamCredentials) => {
    try {
      setSavedXtream(creds);
      localStorage.setItem('iptv_saved_xtream_creds', JSON.stringify(creds));
    } catch (e) {
      console.error(e);
    }
  };

  // Clear Xtream
  const clearSavedXtream = () => {
    setSavedXtream(null);
    setXtreamServer('');
    setXtreamUser('');
    setXtreamPassword('');
    setXtreamAccount(null);
    setGeneratedM3UUrl(null);
    try {
      localStorage.removeItem('iptv_saved_xtream_creds');
    } catch (e) {
      console.error(e);
    }
  };

  // 1. Handle M3U URL load
  const handleLoadURL = async (urlToFetch?: string) => {
    const targetUrl = (urlToFetch || urlInput).trim();
    if (!targetUrl) {
      setError('Please provide a valid M3U or M3U8 URL.');
      return;
    }

    setIsLoading(true);
    setLoadingStep('Connecting & fetching playlist...');
    setError(null);
    setSuccessInfo(null);

    try {
      // First attempt via backend proxy endpoint to avoid CORS / Mixed Content
      let playlistText: string = '';
      let usedProxy = false;

      try {
        const proxyRes = await fetch(`/api/proxy-playlist?url=${encodeURIComponent(targetUrl)}`);
        if (proxyRes.ok) {
          playlistText = await proxyRes.text();
          usedProxy = true;
        } else {
          console.warn('Proxy returned non-200, trying direct fetch...');
        }
      } catch (proxyErr) {
        console.warn('Proxy fetch failed, attempting direct fetch...', proxyErr);
      }

      if (!playlistText) {
        // Direct browser fetch fallback
        const directRes = await fetch(targetUrl);
        if (!directRes.ok) {
          throw new Error(`HTTP error ${directRes.status}: ${directRes.statusText}`);
        }
        playlistText = await directRes.text();
      }

      setLoadingStep('Parsing #EXTINF channels...');
      const channels = parseM3UString(playlistText);

      if (channels.length === 0) {
        throw new Error('Playlist downloaded, but no valid channels (#EXTINF directives) were found.');
      }

      persistM3UUrl(targetUrl);
      onLoadChannels(channels, targetUrl.split('/').pop() || 'Remote M3U Playlist');
      onClose();
    } catch (err: any) {
      setError(`Failed to fetch playlist: ${err.message}. If the host has strict security or invalid credentials, verify the URL or try pasting raw M3U text.`);
    } finally {
      setIsLoading(false);
      setLoadingStep('');
    }
  };

  // 2. Handle Xtream Codes Login & Channel Fetch
  const handleLoadXtream = async () => {
    const server = xtreamServer.trim();
    const user = xtreamUser.trim();
    const pass = xtreamPassword.trim();

    if (!server || !user || !pass) {
      setError('Please provide Server URL, Username, and Password.');
      return;
    }

    setIsLoading(true);
    setLoadingStep('Authenticating with Xtream Codes server...');
    setError(null);
    setSuccessInfo(null);

    try {
      // Step 1: Authenticate
      const authRes = await fetch('/api/xtream/authenticate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ serverUrl: server, username: user, password: pass })
      });

      const authData = await authRes.json();
      if (!authRes.ok || !authData.success) {
        throw new Error(authData.error || 'Authentication failed. Verify your server URL, username, and password.');
      }

      const uInfo = authData.userInfo || {};
      const sInfo = authData.serverInfo || {};
      
      const accountInfo: XtreamAccountInfo = {
        status: uInfo.status || 'Active',
        expDate: uInfo.exp_date ? new Date(parseInt(uInfo.exp_date) * 1000).toLocaleDateString() : 'Unlimited',
        maxConnections: parseInt(uInfo.max_connections) || 1,
        activeConnections: parseInt(uInfo.active_cons) || 0,
        serverUrl: authData.serverUrl || server,
        username: user
      };
      setXtreamAccount(accountInfo);
      if (onSaveXtreamInfo) {
        onSaveXtreamInfo(accountInfo);
      }

      // Step 2: Fetch categories and streams
      setLoadingStep('Fetching categories and live channels...');
      const channelsRes = await fetch('/api/xtream/channels', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ serverUrl: server, username: user, password: pass })
      });

      const channelsData = await channelsRes.json();
      if (!channelsRes.ok || !channelsData.channels) {
        throw new Error(channelsData.error || 'Failed to retrieve live stream catalog.');
      }

      setGeneratedM3UUrl(channelsData.directM3UUrl || null);
      persistXtream({ serverUrl: server, username: user, password: pass });

      if (channelsData.channels.length === 0) {
        setError('Authentication succeeded, but 0 live streams are assigned to this Xtream account.');
        return;
      }

      onLoadChannels(
        channelsData.channels, 
        `Xtream: ${user} (${channelsData.channels.length} channels)`
      );
      onClose();
    } catch (err: any) {
      setError(`Xtream Codes error: ${err.message}`);
    } finally {
      setIsLoading(false);
      setLoadingStep('');
    }
  };

  // 3. Handle Raw Text Load
  const handleLoadRaw = () => {
    setError(null);
    if (!rawInput.trim()) {
      setError('Please paste raw M3U playlist text.');
      return;
    }

    const channels = parseM3UString(rawInput);
    if (channels.length === 0) {
      setError('No valid #EXTINF channels found in the provided text.');
      return;
    }

    onLoadChannels(channels, `Custom M3U (${channels.length} channels)`);
    onClose();
  };

  // Handle local .m3u file upload
  const handleFileUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (evt) => {
      const content = evt.target?.result as string;
      if (content) {
        setRawInput(content);
        const channels = parseM3UString(content);
        if (channels.length > 0) {
          onLoadChannels(channels, file.name || 'Local M3U File');
          onClose();
        } else {
          setError('File loaded but contained 0 valid channels.');
        }
      }
    };
    reader.readAsText(file);
  };

  const samplePresets = [
    {
      title: 'Mux Test Streams HLS',
      url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
      desc: 'High-quality multi-bitrate HLS streams'
    },
    {
      title: 'IPTV-Org US Channels (Public & Free)',
      url: 'https://iptv-org.github.io/iptv/countries/us.m3u',
      desc: 'Legal broadcast channels catalog'
    },
    {
      title: 'Unified Streaming 4K Demo',
      url: 'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
      desc: 'High bitrate 4K HLS stream demo'
    }
  ];

  return (
    <div className="fixed inset-0 z-50 bg-black/80 backdrop-blur-sm flex items-center justify-center p-4">
      <div className="bg-neutral-900 border border-neutral-800 rounded-2xl w-full max-w-xl overflow-hidden shadow-2xl animate-in fade-in zoom-in-95 duration-200 flex flex-col max-h-[90vh]">
        
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-neutral-800 bg-neutral-950/40">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded-lg bg-blue-500/20 text-blue-400 border border-blue-500/30 flex items-center justify-center">
              <KeyRound className="w-4 h-4" />
            </div>
            <div>
              <h3 className="text-sm font-bold text-white">Add IPTV Playlist & Credentials</h3>
              <p className="text-[11px] text-neutral-400">
                Custom M3U/M3U8 URLs, Xtream Codes API, or direct raw files
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 rounded-lg text-neutral-400 hover:text-white hover:bg-neutral-800 transition-colors cursor-pointer"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Tab Buttons */}
        <div className="flex border-b border-neutral-800 bg-neutral-950/70 p-1.5 gap-1.5">
          <button
            onClick={() => { setTab('m3u'); setError(null); }}
            className={`flex-1 py-2 text-xs font-semibold rounded-lg transition-colors flex items-center justify-center gap-2 cursor-pointer ${
              tab === 'm3u' ? 'bg-blue-600 text-white shadow-sm' : 'text-neutral-400 hover:text-white hover:bg-neutral-800/50'
            }`}
          >
            <Globe className="w-3.5 h-3.5" /> M3U / M3U8 URL
          </button>

          <button
            onClick={() => { setTab('xtream'); setError(null); }}
            className={`flex-1 py-2 text-xs font-semibold rounded-lg transition-colors flex items-center justify-center gap-2 cursor-pointer ${
              tab === 'xtream' ? 'bg-blue-600 text-white shadow-sm' : 'text-neutral-400 hover:text-white hover:bg-neutral-800/50'
            }`}
          >
            <Server className="w-3.5 h-3.5" /> Xtream Codes API
          </button>

          <button
            onClick={() => { setTab('raw'); setError(null); }}
            className={`flex-1 py-2 text-xs font-semibold rounded-lg transition-colors flex items-center justify-center gap-2 cursor-pointer ${
              tab === 'raw' ? 'bg-blue-600 text-white shadow-sm' : 'text-neutral-400 hover:text-white hover:bg-neutral-800/50'
            }`}
          >
            <FileText className="w-3.5 h-3.5" /> Raw Text / File
          </button>
        </div>

        {/* Body */}
        <div className="p-6 overflow-y-auto space-y-4 flex-1">
          {error && (
            <div className="p-3.5 rounded-xl bg-red-500/10 border border-red-500/30 text-red-300 text-xs flex items-start gap-2.5 leading-relaxed">
              <AlertCircle className="w-4 h-4 shrink-0 mt-0.5 text-red-400" />
              <div className="flex-1">
                <span className="font-semibold block mb-0.5">Connection Error</span>
                <span>{error}</span>
              </div>
            </div>
          )}

          {/* TAB 1: M3U URL */}
          {tab === 'm3u' && (
            <div className="space-y-4">
              <div>
                <label className="block text-xs font-semibold text-neutral-300 mb-1.5">
                  Remote M3U / M3U8 Playlist URL
                </label>
                <input
                  type="url"
                  placeholder="http://iptv-server.com:8080/get.php?username=...&password=...&type=m3u_plus"
                  value={urlInput}
                  onChange={(e) => setUrlInput(e.target.value)}
                  className="w-full px-3.5 py-2.5 rounded-xl bg-neutral-950 border border-neutral-700 text-white text-xs placeholder:text-neutral-500 focus:outline-none focus:border-blue-500 transition-colors"
                />
                <p className="text-[11px] text-neutral-400 mt-1.5">
                  All URLs are securely routed via our proxy backend to bypass CORS and mixed-content restrictions in modern browsers.
                </p>
              </div>

              {/* Saved Recent M3U URLs */}
              {savedM3Us.length > 0 && (
                <div>
                  <span className="block text-[11px] font-semibold uppercase tracking-wider text-neutral-400 mb-1.5 flex items-center gap-1.5">
                    <History className="w-3.5 h-3.5 text-neutral-500" /> Recently Used URLs
                  </span>
                  <div className="space-y-1.5">
                    {savedM3Us.map((savedUrl, idx) => (
                      <button
                        key={idx}
                        onClick={() => {
                          setUrlInput(savedUrl);
                          handleLoadURL(savedUrl);
                        }}
                        className="w-full text-left p-2 rounded-lg bg-neutral-950 hover:bg-neutral-800/80 border border-neutral-800 text-xs text-neutral-300 hover:text-white truncate flex items-center justify-between group cursor-pointer"
                      >
                        <span className="truncate max-w-[420px] font-mono text-[11px]">{savedUrl}</span>
                        <Sparkles className="w-3 h-3 text-blue-400 opacity-60 group-hover:opacity-100 shrink-0 ml-2" />
                      </button>
                    ))}
                  </div>
                </div>
              )}

              {/* Presets */}
              <div>
                <span className="block text-[11px] font-semibold uppercase tracking-wider text-neutral-400 mb-2">
                  Public Test Presets
                </span>
                <div className="grid grid-cols-1 gap-2">
                  {samplePresets.map((preset, i) => (
                    <button
                      key={i}
                      onClick={() => {
                        setUrlInput(preset.url);
                        handleLoadURL(preset.url);
                      }}
                      className="text-left p-3 rounded-xl bg-neutral-950 hover:bg-neutral-800 border border-neutral-800/80 text-xs transition-colors flex items-center justify-between group cursor-pointer"
                    >
                      <div>
                        <div className="text-white font-medium group-hover:text-blue-400 transition-colors">
                          {preset.title}
                        </div>
                        <div className="text-[11px] text-neutral-400 mt-0.5">
                          {preset.desc}
                        </div>
                      </div>
                      <Sparkles className="w-4 h-4 text-blue-400 opacity-60 group-hover:opacity-100 shrink-0 ml-2" />
                    </button>
                  ))}
                </div>
              </div>
            </div>
          )}

          {/* TAB 2: XTREAM CODES CREDENTIALS */}
          {tab === 'xtream' && (
            <div className="space-y-4">
              <div className="p-3.5 rounded-xl bg-blue-500/10 border border-blue-500/20 text-xs text-blue-200 flex items-start gap-2.5">
                <ShieldCheck className="w-4 h-4 text-blue-400 shrink-0 mt-0.5" />
                <div className="space-y-1 leading-relaxed">
                  <span className="font-semibold text-white block">Xtream Codes API Protocol</span>
                  Enter your IPTV provider's Server URL, Username, and Password. We query <code className="text-blue-300 font-mono">player_api.php</code> to fetch all live categories, channel IDs, logos, and EPG mapping automatically.
                </div>
              </div>

              {/* Saved Account Indicator */}
              {savedXtream && (
                <div className="flex items-center justify-between p-2.5 rounded-xl bg-neutral-950 border border-neutral-800 text-xs">
                  <div className="flex items-center gap-2">
                    <Check className="w-4 h-4 text-emerald-400" />
                    <span className="text-neutral-300">
                      Saved Account: <strong className="text-white font-mono">{savedXtream.username}</strong> on <span className="text-neutral-400 font-mono">{savedXtream.serverUrl}</span>
                    </span>
                  </div>
                  <button
                    onClick={clearSavedXtream}
                    className="text-neutral-500 hover:text-red-400 p-1 transition-colors cursor-pointer"
                    title="Clear saved credentials"
                  >
                    <Trash2 className="w-3.5 h-3.5" />
                  </button>
                </div>
              )}

              {/* Form Fields */}
              <div className="space-y-3">
                <div>
                  <label className="block text-xs font-semibold text-neutral-300 mb-1 flex items-center gap-1.5">
                    <Server className="w-3.5 h-3.5 text-neutral-400" /> Server URL or Host:Port
                  </label>
                  <input
                    type="text"
                    placeholder="http://iptv-provider.tv:8080"
                    value={xtreamServer}
                    onChange={(e) => setXtreamServer(e.target.value)}
                    className="w-full px-3.5 py-2 rounded-xl bg-neutral-950 border border-neutral-700 text-white text-xs placeholder:text-neutral-600 focus:outline-none focus:border-blue-500 font-mono"
                  />
                </div>

                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <div>
                    <label className="block text-xs font-semibold text-neutral-300 mb-1 flex items-center gap-1.5">
                      <User className="w-3.5 h-3.5 text-neutral-400" /> Username
                    </label>
                    <input
                      type="text"
                      placeholder="Your Xtream username"
                      value={xtreamUser}
                      onChange={(e) => setXtreamUser(e.target.value)}
                      className="w-full px-3.5 py-2 rounded-xl bg-neutral-950 border border-neutral-700 text-white text-xs placeholder:text-neutral-600 focus:outline-none focus:border-blue-500 font-mono"
                    />
                  </div>

                  <div>
                    <label className="block text-xs font-semibold text-neutral-300 mb-1 flex items-center gap-1.5">
                      <Lock className="w-3.5 h-3.5 text-neutral-400" /> Password
                    </label>
                    <input
                      type="password"
                      placeholder="••••••••"
                      value={xtreamPassword}
                      onChange={(e) => setXtreamPassword(e.target.value)}
                      className="w-full px-3.5 py-2 rounded-xl bg-neutral-950 border border-neutral-700 text-white text-xs placeholder:text-neutral-600 focus:outline-none focus:border-blue-500 font-mono"
                    />
                  </div>
                </div>
              </div>

              {/* Account details if connected */}
              {xtreamAccount && (
                <div className="p-3 rounded-xl bg-neutral-950 border border-neutral-800 space-y-2 text-xs">
                  <div className="flex items-center justify-between">
                    <span className="text-neutral-400">Account Status:</span>
                    <span className="px-2 py-0.5 rounded text-[11px] font-semibold bg-emerald-500/20 text-emerald-400 border border-emerald-500/30">
                      {xtreamAccount.status}
                    </span>
                  </div>
                  <div className="flex items-center justify-between">
                    <span className="text-neutral-400">Expiration:</span>
                    <span className="text-white font-mono">{xtreamAccount.expDate}</span>
                  </div>
                  <div className="flex items-center justify-between">
                    <span className="text-neutral-400">Max Active Connections:</span>
                    <span className="text-white font-mono">{xtreamAccount.maxConnections}</span>
                  </div>
                </div>
              )}
            </div>
          )}

          {/* TAB 3: RAW TEXT / FILE */}
          {tab === 'raw' && (
            <div className="space-y-4">
              <div>
                <div className="flex items-center justify-between mb-1.5">
                  <label className="text-xs font-semibold text-neutral-300">
                    Paste #EXTM3U Content
                  </label>
                  <label className="text-xs text-blue-400 hover:text-blue-300 cursor-pointer flex items-center gap-1">
                    <Download className="w-3 h-3" /> Upload .m3u File
                    <input
                      type="file"
                      accept=".m3u,.m3u8,text/plain"
                      onChange={handleFileUpload}
                      className="hidden"
                    />
                  </label>
                </div>
                <textarea
                  rows={9}
                  placeholder={`#EXTM3U\n#EXTINF:-1 tvg-id="101" tvg-name="Sky Sports" tvg-logo="https://..." group-title="Sports",Sky Sports HD\nhttp://server.com:8080/live/user/pass/101.m3u8`}
                  value={rawInput}
                  onChange={(e) => setRawInput(e.target.value)}
                  className="w-full px-3.5 py-2.5 rounded-xl bg-neutral-950 border border-neutral-700 text-white font-mono text-xs placeholder:text-neutral-600 focus:outline-none focus:border-blue-500 leading-relaxed"
                />
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-6 py-4 bg-neutral-950 border-t border-neutral-800 flex items-center justify-between">
          <div className="text-xs text-neutral-400">
            {isLoading ? (
              <div className="flex items-center gap-2 text-blue-400">
                <RefreshCw className="w-3.5 h-3.5 animate-spin" />
                <span>{loadingStep || 'Connecting...'}</span>
              </div>
            ) : (
              <span>Supports HLS (.m3u8), TS, and MP4 streams</span>
            )}
          </div>

          <div className="flex items-center gap-2.5">
            <button
              onClick={onClose}
              className="px-4 py-2 rounded-xl text-xs font-medium text-neutral-400 hover:text-white hover:bg-neutral-800 transition-colors cursor-pointer"
            >
              Cancel
            </button>
            <button
              disabled={isLoading}
              onClick={() => {
                if (tab === 'm3u') handleLoadURL();
                else if (tab === 'xtream') handleLoadXtream();
                else handleLoadRaw();
              }}
              className="px-5 py-2 rounded-xl text-xs font-semibold bg-blue-600 hover:bg-blue-500 text-white transition-all flex items-center gap-2 cursor-pointer shadow-md disabled:opacity-50"
            >
              {isLoading ? (
                <>
                  <RefreshCw className="w-3.5 h-3.5 animate-spin" />
                  <span>Loading…</span>
                </>
              ) : (
                <>
                  <Check className="w-3.5 h-3.5" />
                  <span>
                    {tab === 'xtream' ? 'Connect Xtream & Load' : 'Load Channels'}
                  </span>
                </>
              )}
            </button>
          </div>
        </div>

      </div>
    </div>
  );
};
