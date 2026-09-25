import { SwiftFileInfo } from '../types/iptv';

import m3uItemCode from '../../swift-sources/M3UItem.swift?raw';
import m3uParserCode from '../../swift-sources/M3UParser.swift?raw';
import xtreamCodesManagerCode from '../../swift-sources/XtreamCodesManager.swift?raw';
import iptvPlayerManagerCode from '../../swift-sources/IPTVPlayerManager.swift?raw';
import iptvPlaybackViewCode from '../../swift-sources/IPTVPlaybackView.swift?raw';
import channelListViewCode from '../../swift-sources/ChannelListView.swift?raw';
import contentViewCode from '../../swift-sources/ContentView.swift?raw';
import iptvPlayerAppCode from '../../swift-sources/IPTVPlayerApp.swift?raw';
import infoPlistCode from '../../swift-sources/Info.plist?raw';
import packageSwiftCode from '../../swift-sources/Package.swift?raw';
import buildDmgCode from '../../swift-sources/build_dmg.sh?raw';
import runAppCode from '../../swift-sources/run_app.command?raw';

export const SWIFT_FILES: SwiftFileInfo[] = [
  {
    filename: 'M3UItem.swift',
    title: 'Channel & Media Item Model',
    category: 'Model',
    description: 'Data model conforming to Identifiable, Hashable, Codable, and Sendable. Encapsulates channel identity, stream URL, logo, category group, MP4 vs HLS classification, and favorite status.',
    highlights: [
      'Identifiable & Sendable conformance for Swift Concurrency safety',
      'Smart content classification into Live TV, Movies (VOD), and TV Shows',
      'Computed isHLS, isMP4, and isVOD properties for dynamic buffer routing',
      'Graceful fallbacks for missing channel names and empty groups'
    ],
    code: m3uItemCode
  },
  {
    filename: 'M3UParser.swift',
    title: 'High-Speed Async M3U Playlist Parser',
    category: 'Networking',
    description: 'High-performance streaming M3U parser extracting tvg-id, tvg-name, tvg-logo, and group-title in O(N) linear time without regex overhead.',
    highlights: [
      'Async/await line-by-line streaming without loading entire files into memory',
      'Fast index scanning replacing expensive NSRegularExpression calls',
      'Extracts channel metadata: tvg-id, tvg-name, tvg-logo, group-title',
      'Handles multi-megabyte playlists with 20,000+ items in milliseconds'
    ],
    code: m3uParserCode
  },
  {
    filename: 'XtreamCodesManager.swift',
    title: 'Xtream Codes IPTV API Manager',
    category: 'Networking',
    description: 'Direct API integration for Xtream Codes IPTV servers, authenticating and fetching Live TV, VOD Movies, TV Series, and episode streams.',
    highlights: [
      'Authenticates with player_api.php and parses user subscription status',
      'Fetches Live Streams, VOD Movies, and Series categories',
      'Supports episode resolution via action=get_series_info',
      'Generates direct M3U Plus playlists with credentials'
    ],
    code: xtreamCodesManagerCode
  },
  {
    filename: 'IPTVPlayerManager.swift',
    title: 'Central State Coordinator & Player Manager',
    category: 'State',
    description: 'Main coordinator handling playlist management, fast indexed filtering, favorites persistence, MP4 VOD timeline tracking, and AVPlayer lifecycle.',
    highlights: [
      'Precomputed category counts and filtered channel indices for 0ms UI lag',
      'Hardware-accelerated AVPlayer with VLC/Browser User-Agent header bypass',
      'Dynamic buffer tuning: Progressive buffering for MP4, low-latency for Live TV',
      'VOD seeking (seek to second, skip ±10s) and periodic CMTime tracking',
      'Native full screen and detailOnly column visibility toggle'
    ],
    code: iptvPlayerManagerCode
  },
  {
    filename: 'IPTVPlaybackView.swift',
    title: 'Hardware AVPlayerLayer Video View',
    category: 'View',
    description: 'Hardware-accelerated AVPlayerLayer view wrapping Metal/CoreAnimation with interactive HUD overlays, VOD progress scrubber, buffering indicators, and full screen controls.',
    highlights: [
      'Direct AVPlayerLayer via AppKit NSViewRepresentable / UIKit UIViewRepresentable',
      'VOD Scrubber Slider with formatted current time and duration',
      'Skip -10s / +10s and play/pause transport controls',
      'Double-tap video to toggle Full Screen (or F key shortcut)',
      'Auto-hiding HUD controls on mouse inactivity'
    ],
    code: iptvPlaybackViewCode
  },
  {
    filename: 'ChannelListView.swift',
    title: 'Channel & Media Content List',
    category: 'View',
    description: 'Fast virtualized list rendering with LazyVStack, search filtering, channel badges, and favorite toggles.',
    highlights: [
      'Lazy loading for high-performance rendering of tens of thousands of channels',
      'Content-type badges (Live, VOD Movie, TV Series)',
      'Async image loading with cached fallbacks',
      'One-tap favorite toggling with instant visual feedback'
    ],
    code: channelListViewCode
  },
  {
    filename: 'ContentView.swift',
    title: 'Main App Split Navigation Layout',
    category: 'App',
    description: 'Three-column NavigationSplitView coordinating Categories Sidebar, Channel List, and Video Player with responsive layout and modal sheets.',
    highlights: [
      'Modern three-column NavigationSplitView with custom column widths',
      'Collapsible sidebars for theater/fullscreen video mode',
      'Toolbar full screen button and keyboard shortcuts',
      'Add Source sheet supporting both Xtream Codes and M3U playlists'
    ],
    code: contentViewCode
  },
  {
    filename: 'IPTVPlayerApp.swift',
    title: 'SwiftUI App Entry Point',
    category: 'App',
    description: 'Main application lifecycle with WindowGroup, minimum window constraints, and macOS toolbar styling.',
    highlights: [
      '@main SwiftUI App lifecycle structure',
      'Window frame constraints for optimal 3-column layout',
      'macOS unified compact toolbar title styling'
    ],
    code: iptvPlayerAppCode
  },
  {
    filename: 'Info.plist',
    title: 'macOS & iOS App Configuration',
    category: 'Config',
    description: 'App Transport Security (ATS) configuration allowing arbitrary HTTP stream playback, and background audio capabilities.',
    highlights: [
      'NSAllowsArbitraryLoads: true for non-HTTPS IPTV streams',
      'UIBackgroundModes audio capability',
      'LSMinimumSystemVersion 13.0+ for macOS Ventura / Sonoma'
    ],
    code: infoPlistCode
  },
  {
    filename: 'Package.swift',
    title: 'Swift Package Manager Manifest',
    category: 'Build',
    description: 'SPM manifest enabling pure command-line compilation and execution on macOS without requiring full Xcode.',
    highlights: [
      'Zero external dependencies (pure AVFoundation, SwiftUI, and Combine)',
      'Configured for macOS 13+ and iOS 16+',
      'Executable target running directly via swift run'
    ],
    code: packageSwiftCode
  },
  {
    filename: 'build_dmg.sh',
    title: 'DMG Packaging & Release Script',
    category: 'Build',
    description: 'Automated script compiling the Swift application in release mode and bundling it into a portable macOS .app or .dmg.',
    highlights: [
      'Compiles with swift build -c release',
      'Constructs macOS .app bundle directory structure',
      'Creates self-contained DMG installer'
    ],
    code: buildDmgCode
  },
  {
    filename: 'run_app.command',
    title: 'Double-Click Mac Launcher Script',
    category: 'Build',
    description: 'Interactive launcher allowing Mac users to double-click and run the IPTV application directly from Finder.',
    highlights: [
      'Double-click launcher in Finder',
      'Checks Swift installation and runs swift run',
      'Opens Terminal automatically'
    ],
    code: runAppCode
  }
];
