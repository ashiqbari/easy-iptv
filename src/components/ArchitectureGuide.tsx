import React from 'react';
import { 
  Tv, Cpu, ShieldCheck, Zap, Code2, Globe, Database, 
  ExternalLink, Layers, CheckCircle2, AlertTriangle, Monitor
} from 'lucide-react';

export const ArchitectureGuide: React.FC = () => {
  return (
    <div className="w-full h-full overflow-y-auto p-6 md:p-8 space-y-8 bg-neutral-950 text-neutral-200">
      
      {/* Header Banner */}
      <div className="relative rounded-2xl p-6 md:p-8 bg-gradient-to-r from-blue-900/30 via-indigo-900/20 to-neutral-900 border border-blue-500/20 overflow-hidden shadow-2xl">
        <div className="relative z-10 max-w-3xl">
          <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-blue-500/10 border border-blue-500/30 text-blue-400 text-xs font-semibold uppercase tracking-wider mb-4">
            <Cpu className="w-3.5 h-3.5" /> Apple Platforms Engineering Specification
          </div>
          <h1 className="text-2xl md:text-3xl font-bold text-white tracking-tight">
            Native Cross-Platform IPTV Player Architecture
          </h1>
          <p className="mt-2 text-sm md:text-base text-neutral-300 leading-relaxed">
            Engineered exclusively with Swift, SwiftUI, AVKit, and Swift Concurrency for iOS 16+ and macOS 13+.
            Zero 3rd-party dependencies, leveraging Apple hardware decoding and adaptive split navigation.
          </p>
        </div>
      </div>

      {/* 4 Pillars Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="p-5 rounded-xl bg-neutral-900/60 border border-neutral-800 flex flex-col gap-2">
          <div className="w-10 h-10 rounded-lg bg-blue-500/20 text-blue-400 flex items-center justify-center mb-1">
            <Tv className="w-5 h-5" />
          </div>
          <h3 className="text-sm font-semibold text-white">1. AVKit Video Engine</h3>
          <p className="text-xs text-neutral-400 leading-relaxed">
            Direct CoreMedia HLS engine using <code className="text-blue-300">AVPlayer</code> and <code className="text-blue-300">VideoPlayer</code>. Supports adaptive bitrate switching, low-latency HLS, and hardware-accelerated HEVC/H.264 decoding.
          </p>
        </div>

        <div className="p-5 rounded-xl bg-neutral-900/60 border border-neutral-800 flex flex-col gap-2">
          <div className="w-10 h-10 rounded-lg bg-cyan-500/20 text-cyan-400 flex items-center justify-center mb-1">
            <Code2 className="w-5 h-5" />
          </div>
          <h3 className="text-sm font-semibold text-white">2. Actor-Isolated Parser</h3>
          <p className="text-xs text-neutral-400 leading-relaxed">
            <code className="text-cyan-300">M3UParser</code> is an asynchronous Swift <code className="text-cyan-300">actor</code> that downloads playlists via <code className="text-cyan-300">URLSession</code> and parses thousands of channels off the main thread without stutter.
          </p>
        </div>

        <div className="p-5 rounded-xl bg-neutral-900/60 border border-neutral-800 flex flex-col gap-2">
          <div className="w-10 h-10 rounded-lg bg-purple-500/20 text-purple-400 flex items-center justify-center mb-1">
            <Layers className="w-5 h-5" />
          </div>
          <h3 className="text-sm font-semibold text-white">3. NavigationSplitView</h3>
          <p className="text-xs text-neutral-400 leading-relaxed">
            Three-column architecture adapts seamlessly: 3 columns on macOS and iPad Landscape, 2 columns on iPad Portrait, and collapsed navigation stack on iPhone.
          </p>
        </div>

        <div className="p-5 rounded-xl bg-neutral-900/60 border border-neutral-800 flex flex-col gap-2">
          <div className="w-10 h-10 rounded-lg bg-emerald-500/20 text-emerald-400 flex items-center justify-center mb-1">
            <Database className="w-5 h-5" />
          </div>
          <h3 className="text-sm font-semibold text-white">4. Persistent State</h3>
          <p className="text-xs text-neutral-400 leading-relaxed">
            Persistent favorites bookmarking and last-loaded playlist URLs backed by <code className="text-emerald-300">UserDefaults</code>. Reconnects and resumes active channels on cold launch.
          </p>
        </div>
      </div>

      {/* Detailed Technical Sections */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        
        {/* Section A: Extended M3U Parsing */}
        <div className="p-6 rounded-2xl bg-neutral-900/40 border border-neutral-800 space-y-4">
          <div className="flex items-center gap-2">
            <Zap className="w-5 h-5 text-amber-400" />
            <h3 className="text-base font-semibold text-white">#EXTINF Regex Extraction Engine</h3>
          </div>
          <p className="text-xs text-neutral-400 leading-relaxed">
            M3U/M3U8 playlists in IPTV contain varied non-standard attribute formats. The <code className="text-blue-300">M3UParser</code> uses case-insensitive regular expressions with quote delimiters to reliably pull structured metadata:
          </p>

          <div className="p-3.5 rounded-lg bg-neutral-950 font-mono text-[11px] text-neutral-300 border border-neutral-800/80 space-y-1">
            <div className="text-neutral-500">// Example raw EXTINF line</div>
            <div className="text-amber-300">#EXTINF:-1 tvg-id="101" tvg-name="Sky Sports" tvg-logo="https://.../logo.png" group-title="Sports",Sky Sports HD</div>
            <div className="text-blue-300">https://stream.server.com/live/101.m3u8</div>
          </div>

          <ul className="space-y-2 text-xs text-neutral-400">
            <li className="flex items-start gap-2">
              <CheckCircle2 className="w-4 h-4 text-emerald-400 shrink-0 mt-0.5" />
              <span><strong>Name extraction:</strong> Extracts comma-delimited title first, falling back to <code className="text-neutral-300">tvg-name</code> or URL filename.</span>
            </li>
            <li className="flex items-start gap-2">
              <CheckCircle2 className="w-4 h-4 text-emerald-400 shrink-0 mt-0.5" />
              <span><strong>Attribute sanitization:</strong> Strips whitespace, quotes, and invalid characters from URLs.</span>
            </li>
            <li className="flex items-start gap-2">
              <CheckCircle2 className="w-4 h-4 text-emerald-400 shrink-0 mt-0.5" />
              <span><strong>Encoding resilience:</strong> Decodes UTF-8 first, with automatic fallback to ISO-Latin-1 and ASCII.</span>
            </li>
          </ul>
        </div>

        {/* Section B: AVPlayer & Lifecycle */}
        <div className="p-6 rounded-2xl bg-neutral-900/40 border border-neutral-800 space-y-4">
          <div className="flex items-center gap-2">
            <Monitor className="w-5 h-5 text-blue-400" />
            <h3 className="text-base font-semibold text-white">AVPlayer & AVPlayerItem Lifecycle</h3>
          </div>
          <p className="text-xs text-neutral-400 leading-relaxed">
            SwiftUI's <code className="text-blue-300">VideoPlayer</code> is kept in lockstep with the manager via Combine and Key-Value Observing (KVO):
          </p>

          <div className="space-y-2 text-xs text-neutral-400">
            <div className="p-3 rounded-lg bg-neutral-950 border border-neutral-800">
              <strong className="text-white block mb-1">Item Recycling with replaceCurrentItem(with:)</strong>
              Reusing the existing <code className="text-blue-300">AVPlayer</code> instance instead of destroying and reallocating it avoids rendering freezes and optimizes CoreMedia buffers.
            </div>

            <div className="p-3 rounded-lg bg-neutral-950 border border-neutral-800">
              <strong className="text-white block mb-1">Buffer & Rate Monitoring</strong>
              Observing <code className="text-blue-300">timeControlStatus == .waitingToPlayAtSpecifiedRate</code> alerts the UI to display the buffering spinner overlay automatically.
            </div>

            <div className="p-3 rounded-lg bg-neutral-950 border border-neutral-800">
              <strong className="text-white block mb-1">iOS Audio Session Configuration</strong>
              <code className="text-blue-300">AVAudioSession.sharedInstance().setCategory(.playback)</code> ensures live stream audio continues playing seamlessly when the device is muted or locked.
            </div>
          </div>
        </div>

      </div>

      {/* Section C: Xtream Codes API Protocol Integration */}
      <div className="p-6 rounded-2xl bg-gradient-to-br from-indigo-950/40 to-neutral-900 border border-indigo-500/20 space-y-4">
        <div className="flex items-center gap-2">
          <Globe className="w-5 h-5 text-indigo-400" />
          <h3 className="text-base font-semibold text-white">
            Xtream Codes API Protocol Integration
          </h3>
        </div>
        <p className="text-xs text-neutral-300 leading-relaxed">
          The app natively supports both raw M3U/M3U8 playlists and Xtream Codes servers through <code className="text-indigo-300">XtreamCodesManager.swift</code>. It interacts directly with the standard Xtream endpoints:
        </p>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
          <div className="p-3.5 rounded-xl bg-neutral-950/80 border border-neutral-800 space-y-1.5">
            <span className="text-[11px] font-semibold text-indigo-400 uppercase tracking-wider block">1. Auth & Expiration</span>
            <code className="text-[11px] font-mono text-neutral-300 block">/player_api.php?username=&password=</code>
            <p className="text-[11px] text-neutral-400">
              Validates subscription status, active connection counts, and account expiration dates.
            </p>
          </div>

          <div className="p-3.5 rounded-xl bg-neutral-950/80 border border-neutral-800 space-y-1.5">
            <span className="text-[11px] font-semibold text-indigo-400 uppercase tracking-wider block">2. Category & Live Streams</span>
            <code className="text-[11px] font-mono text-neutral-300 block">&action=get_live_categories &streams</code>
            <p className="text-[11px] text-neutral-400">
              Fetches categorized channels, channel numbers, and logo assets mapped to Swift Codable structs.
            </p>
          </div>

          <div className="p-3.5 rounded-xl bg-neutral-950/80 border border-neutral-800 space-y-1.5">
            <span className="text-[11px] font-semibold text-indigo-400 uppercase tracking-wider block">3. HLS Direct Stream URLs</span>
            <code className="text-[11px] font-mono text-neutral-300 block">/live/{'{user}'}/{'{pass}'}/{'{id}'}.m3u8</code>
            <p className="text-[11px] text-neutral-400">
              Direct CoreMedia/AVPlayer streaming endpoints with zero latency and full hardware acceleration.
            </p>
          </div>
        </div>
      </div>

      {/* Section C: Critical Xcode & App Transport Security Setup */}
      <div className="p-6 rounded-2xl bg-amber-500/5 border border-amber-500/20 space-y-4">
        <div className="flex items-center gap-2">
          <ShieldCheck className="w-5 h-5 text-amber-400" />
          <h3 className="text-base font-semibold text-white">
            Essential Xcode Setup: App Transport Security (ATS)
          </h3>
        </div>
        <p className="text-xs text-neutral-300 leading-relaxed">
          Many public and private IPTV providers host their HLS chunk manifests over raw HTTP (unencrypted) or use dynamic IPs. Apple platforms block non-HTTPS traffic by default under ATS. To ensure all IPTV streams play in Xcode:
        </p>

        <div className="p-4 rounded-xl bg-black/60 border border-neutral-800 font-mono text-xs text-neutral-300 space-y-1">
          <div className="text-neutral-500">&lt;!-- Add to your Target's Info.plist --&gt;</div>
          <div className="text-emerald-400">&lt;key&gt;NSAppTransportSecurity&lt;/key&gt;</div>
          <div className="text-neutral-400">&lt;dict&gt;</div>
          <div className="text-blue-300 pl-4">&lt;key&gt;NSAllowsArbitraryLoads&lt;/key&gt;</div>
          <div className="text-amber-400 pl-4">&lt;true/&gt;</div>
          <div className="text-neutral-400">&lt;/dict&gt;</div>
        </div>

        <div className="flex items-center gap-2 text-xs text-amber-400/90 font-medium">
          <AlertTriangle className="w-4 h-4 shrink-0" />
          <span>Also enable Background Modes &rarr; Audio, AirPlay, and Picture in Picture in your Xcode Target capabilities!</span>
        </div>
      </div>

    </div>
  );
};
