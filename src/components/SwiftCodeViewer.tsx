import React, { useState } from 'react';
import JSZip from 'jszip';
import { SWIFT_FILES } from '../data/swiftFiles';
import { SwiftFileInfo } from '../types/iptv';
import { 
  FileCode, Copy, Check, Download, Layers, ShieldCheck, 
  Sparkles, ExternalLink, Terminal, Cpu, Box, X, ChevronRight,
  Info, CheckCircle2
} from 'lucide-react';

export const SwiftCodeViewer: React.FC = () => {
  const [selectedFile, setSelectedFile] = useState<SwiftFileInfo>(SWIFT_FILES[0]);
  const [copied, setCopied] = useState(false);
  const [isZipping, setIsZipping] = useState(false);
  const [showDmgGuide, setShowDmgGuide] = useState(false);
  const [copiedCommand, setCopiedCommand] = useState(false);

  const handleCopy = () => {
    navigator.clipboard.writeText(selectedFile.code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleCopyScriptCmd = () => {
    navigator.clipboard.writeText('chmod +x build_dmg.sh && ./build_dmg.sh');
    setCopiedCommand(true);
    setTimeout(() => setCopiedCommand(false), 2000);
  };

  const handleDownloadZip = async () => {
    setIsZipping(true);
    try {
      // 1. Try server-side fresh download to prevent any browser caching
      try {
        const response = await fetch(`/api/download-zip?t=${Date.now()}`, {
          cache: 'no-store'
        });
        if (response.ok) {
          const blob = await response.blob();
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url;
          a.download = 'EasyIPTV-macOS-iOS.zip';
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
          URL.revokeObjectURL(url);
          return;
        }
      } catch (serverErr) {
        console.warn('Server zip download fell back to client generator:', serverErr);
      }

      // 2. Client-side fallback generator using synced SWIFT_FILES
      const zip = new JSZip();
      const folder = zip.folder('EasyIPTV');

      SWIFT_FILES.forEach((f) => {
        folder?.file(f.filename, f.code);
      });

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

      const content = await zip.generateAsync({ type: 'blob' });
      const url = URL.createObjectURL(content);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'EasyIPTV-macOS-iOS.zip';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    } catch (e) {
      console.error('Failed to create zip:', e);
    } finally {
      setIsZipping(false);
    }
  };

  return (
    <div className="w-full h-full flex flex-col bg-neutral-950 rounded-2xl border border-neutral-800 overflow-hidden shadow-2xl relative">
      
      {/* Top Bar */}
      <div className="h-14 px-4 sm:px-6 border-b border-neutral-800 bg-neutral-900/60 backdrop-blur-md flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 rounded-lg bg-orange-500/20 text-orange-400 border border-orange-500/30 flex items-center justify-center shrink-0">
            <FileCode className="w-4 h-4" />
          </div>
          <div>
            <h2 className="text-sm font-semibold text-white flex items-center gap-2">
              Swift Source Files & Xcode Architecture
              <span className="hidden sm:inline-block text-[10px] font-mono uppercase bg-neutral-800 text-neutral-400 px-2 py-0.5 rounded border border-neutral-700">
                macOS 13+ • iOS 16+
              </span>
            </h2>
            <p className="text-xs text-neutral-400 hidden sm:block">
              Native Swift with AVKit, 3-category sorting (Live TV, Movies, Series), and .DMG packager
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {/* How to make DMG button */}
          <button
            onClick={() => setShowDmgGuide(true)}
            className="px-3 py-1.5 rounded-lg bg-emerald-600/20 hover:bg-emerald-600/30 text-emerald-300 border border-emerald-500/30 text-xs font-semibold flex items-center gap-1.5 transition-all cursor-pointer shadow-xs"
          >
            <Box className="w-3.5 h-3.5 text-emerald-400" />
            <span className="hidden md:inline">How to make</span> .DMG File
          </button>

          <button
            onClick={handleCopy}
            className="px-3 py-1.5 rounded-lg bg-neutral-800 hover:bg-neutral-700 text-white text-xs font-medium flex items-center gap-1.5 transition-colors cursor-pointer"
          >
            {copied ? <Check className="w-3.5 h-3.5 text-emerald-400" /> : <Copy className="w-3.5 h-3.5" />}
            <span className="hidden sm:inline">{copied ? 'Copied' : 'Copy File'}</span>
          </button>

          <button
            disabled={isZipping}
            onClick={handleDownloadZip}
            className="px-3.5 py-1.5 rounded-lg bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white text-xs font-semibold flex items-center gap-1.5 transition-all shadow-md cursor-pointer disabled:opacity-50"
          >
            <Download className="w-3.5 h-3.5" />
            <span>{isZipping ? 'Zipping…' : 'Download All (.zip)'}</span>
          </button>
        </div>
      </div>

      {/* Main Content Area */}
      <div className="flex-1 flex overflow-hidden">
        
        {/* Left: File Explorer Sidebar */}
        <aside className="w-72 bg-neutral-900/30 border-r border-neutral-800 flex flex-col shrink-0">
          <div className="p-3 text-[11px] font-bold uppercase tracking-wider text-neutral-500 border-b border-neutral-800/80 flex items-center justify-between">
            <span>Project Files ({SWIFT_FILES.length})</span>
            <span className="text-[10px] text-neutral-400 font-mono">Native Swift</span>
          </div>

          <div className="flex-1 overflow-y-auto p-2 space-y-1">
            {SWIFT_FILES.map((file) => {
              const isSelected = selectedFile.filename === file.filename;
              return (
                <button
                  key={file.filename}
                  onClick={() => setSelectedFile(file)}
                  className={`w-full text-left p-2.5 rounded-xl transition-all cursor-pointer group flex flex-col gap-1 ${
                    isSelected
                      ? 'bg-blue-600/15 border border-blue-500/40 text-white shadow-sm'
                      : 'hover:bg-neutral-800/60 text-neutral-300 border border-transparent'
                  }`}
                >
                  <div className="flex items-center justify-between">
                    <span className="font-mono text-xs font-semibold text-white group-hover:text-blue-400 flex items-center gap-1.5">
                      {file.filename.endsWith('.sh') ? (
                        <Terminal className="w-3.5 h-3.5 text-emerald-400" />
                      ) : (
                        <FileCode className="w-3.5 h-3.5 text-orange-400" />
                      )}
                      {file.filename}
                    </span>
                    <span className={`text-[9px] font-mono uppercase px-1.5 py-0.5 rounded ${
                      file.category === 'Build'
                        ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                        : isSelected ? 'bg-blue-500/30 text-blue-200' : 'bg-neutral-800 text-neutral-400'
                    }`}>
                      {file.category}
                    </span>
                  </div>
                  <span className="text-[11px] text-neutral-400 line-clamp-1">
                    {file.title}
                  </span>
                </button>
              );
            })}
          </div>

          {/* Quick Info Footer */}
          <div className="p-3 border-t border-neutral-800 text-xs text-neutral-400 flex items-center gap-2 bg-neutral-900/40">
            <ShieldCheck className="w-4 h-4 text-emerald-400 shrink-0" />
            <span>Ready for Xcode 15/16 & CLI compilation</span>
          </div>
        </aside>

        {/* Right: Code Viewer & Documentation Header */}
        <main className="flex-1 flex flex-col bg-neutral-950 overflow-hidden">
          
          {/* File Header */}
          <div className="p-4 border-b border-neutral-800/80 bg-neutral-900/20">
            <div className="flex items-center justify-between mb-2">
              <div className="flex items-center gap-2">
                <span className="text-base font-bold text-white font-mono">{selectedFile.filename}</span>
                <span className="text-xs text-neutral-400">• {selectedFile.title}</span>
              </div>
              <span className="text-xs font-mono px-2 py-0.5 rounded bg-neutral-800 text-neutral-300 border border-neutral-700">
                {selectedFile.code.split('\n').length} lines
              </span>
            </div>

            <p className="text-xs text-neutral-300 leading-relaxed mb-3">
              {selectedFile.description}
            </p>

            {/* Architecture Highlights */}
            <div className="flex flex-wrap gap-2">
              {selectedFile.highlights.map((h, i) => (
                <div key={i} className="flex items-center gap-1.5 px-2.5 py-1 rounded-md bg-neutral-900 border border-neutral-800 text-[11px] text-neutral-300">
                  <Sparkles className="w-3 h-3 text-amber-400 shrink-0" />
                  <span>{h}</span>
                </div>
              ))}
            </div>
          </div>

          {/* Code Area */}
          <div className="flex-1 overflow-auto bg-neutral-950 p-4 font-mono text-xs">
            <div className="flex">
              {/* Line numbers */}
              <div className="pr-4 select-none text-right text-neutral-600 border-r border-neutral-800/60 font-mono space-y-0.5 shrink-0">
                {selectedFile.code.split('\n').map((_, index) => (
                  <div key={index} className="leading-5">
                    {index + 1}
                  </div>
                ))}
              </div>

              {/* Code lines */}
              <pre className="pl-4 text-neutral-200 overflow-x-auto space-y-0.5 leading-5 flex-1">
                <code>{selectedFile.code}</code>
              </pre>
            </div>
          </div>

        </main>

      </div>

      {/* DMG Creation Guide Modal */}
      {showDmgGuide && (
        <div className="fixed inset-0 z-50 bg-black/80 backdrop-blur-md flex items-center justify-center p-4">
          <div className="w-full max-w-2xl bg-neutral-900 border border-neutral-800 rounded-2xl p-6 shadow-2xl flex flex-col max-h-[90vh] overflow-y-auto">
            
            <div className="flex items-center justify-between pb-4 border-b border-neutral-800">
              <div className="flex items-center gap-2.5">
                <div className="w-9 h-9 rounded-xl bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 flex items-center justify-center">
                  <Box className="w-5 h-5" />
                </div>
                <div>
                  <h3 className="text-base font-bold text-white">How to make a .dmg file for your Mac</h3>
                  <p className="text-xs text-neutral-400">Two simple methods to build and run on macOS</p>
                </div>
              </div>
              <button
                onClick={() => setShowDmgGuide(false)}
                className="p-1.5 rounded-lg hover:bg-neutral-800 text-neutral-400 hover:text-white transition-colors cursor-pointer"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="space-y-6 pt-4 text-xs text-neutral-300">
              
              {/* Method 1: The 15-second terminal script */}
              <div className="p-4 rounded-xl bg-neutral-950 border border-neutral-800 space-y-3">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="w-5 h-5 rounded-full bg-emerald-600 text-white font-bold flex items-center justify-center text-[10px]">
                      1
                    </span>
                    <span className="font-bold text-white text-sm">
                      Automated 1-Command Script (Recommended)
                    </span>
                  </div>
                  <span className="text-[10px] font-mono bg-emerald-500/20 text-emerald-300 px-2 py-0.5 rounded border border-emerald-500/30">
                    No Xcode GUI needed
                  </span>
                </div>

                <p className="text-neutral-400 leading-relaxed">
                  We have included an automated <code className="text-amber-300 bg-neutral-900 px-1 py-0.5 rounded">build_dmg.sh</code> script inside the downloaded project. It uses macOS's built-in <code className="text-blue-400">swiftc</code> compiler and <code className="text-blue-400">hdiutil</code> disk imaging tool.
                </p>

                <div className="space-y-2">
                  <span className="text-neutral-400 font-medium">Steps:</span>
                  <ol className="list-decimal list-inside space-y-1.5 pl-1 text-neutral-300">
                    <li>Click <strong>Download All (.zip)</strong> and unzip the archive on your Mac.</li>
                    <li>Open <strong>Terminal</strong> and navigate to the unzipped folder:
                      <pre className="mt-1 p-2 rounded bg-neutral-900 border border-neutral-800 font-mono text-[11px] text-neutral-300 overflow-x-auto">
                        cd ~/Downloads/EasyIPTV-macOS-iOS/EasyIPTV
                      </pre>
                    </li>
                    <li>Run the automated build script:</li>
                  </ol>

                  <div className="relative mt-2">
                    <pre className="p-3 bg-neutral-900 border border-neutral-800 rounded-lg font-mono text-[11px] text-emerald-400 overflow-x-auto flex items-center justify-between">
                      <code>chmod +x build_dmg.sh && ./build_dmg.sh</code>
                      <button
                        onClick={handleCopyScriptCmd}
                        className="ml-2 px-2.5 py-1 bg-neutral-800 hover:bg-neutral-700 text-white rounded text-[10px] flex items-center gap-1 cursor-pointer transition-colors"
                      >
                        {copiedCommand ? <Check className="w-3 h-3 text-emerald-400" /> : <Copy className="w-3 h-3" />}
                        <span>{copiedCommand ? 'Copied' : 'Copy'}</span>
                      </button>
                    </pre>
                  </div>

                  <div className="flex items-center gap-2 p-2 rounded-lg bg-emerald-500/10 border border-emerald-500/20 text-emerald-300 text-[11px]">
                    <CheckCircle2 className="w-4 h-4 shrink-0 text-emerald-400" />
                    <span>In ~10 seconds, <strong>EasyIPTV-macOS.dmg</strong> will be created in that folder! Double-click and drag to Applications.</span>
                  </div>
                </div>
              </div>

              {/* Method 2: Xcode GUI */}
              <div className="p-4 rounded-xl bg-neutral-950 border border-neutral-800 space-y-3">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="w-5 h-5 rounded-full bg-blue-600 text-white font-bold flex items-center justify-center text-[10px]">
                      2
                    </span>
                    <span className="font-bold text-white text-sm">
                      Building via Xcode GUI
                    </span>
                  </div>
                  <span className="text-[10px] font-mono bg-blue-500/20 text-blue-300 px-2 py-0.5 rounded border border-blue-500/30">
                    Xcode 15 / 16
                  </span>
                </div>

                <p className="text-neutral-400 leading-relaxed">
                  If you prefer developing and archiving inside the official Apple Xcode IDE:
                </p>

                <ol className="list-decimal list-inside space-y-1.5 pl-1 text-neutral-300">
                  <li>Open Xcode &gt; <strong>File &gt; New &gt; Project</strong> &gt; Select <strong>macOS &gt; App</strong> (SwiftUI). Name it <strong>EasyIPTV</strong>.</li>
                  <li>Drag the <code className="text-orange-300">.swift</code> files and <code className="text-orange-300">Info.plist</code> from the zip into your project.</li>
                  <li>In <strong>Signing & Capabilities</strong>, enable:
                    <ul className="list-disc list-inside pl-4 text-neutral-400 mt-1 space-y-0.5">
                      <li><strong>Incoming/Outgoing Connections (Client)</strong> in App Sandbox.</li>
                      <li><strong>Background Modes &gt; Audio, AirPlay, Picture in Picture</strong>.</li>
                    </ul>
                  </li>
                  <li>Go to <strong>Product &gt; Archive &gt; Distribute App &gt; Copy App</strong> to export <code className="text-white">EasyIPTV.app</code>.</li>
                  <li>Package into a DMG using Terminal:
                    <pre className="mt-1 p-2 rounded bg-neutral-900 border border-neutral-800 font-mono text-[11px] text-neutral-300 overflow-x-auto">
                      hdiutil create -volname "EasyIPTV" -srcfolder EasyIPTV.app -ov -format UDZO EasyIPTV.dmg
                    </pre>
                  </li>
                </ol>
              </div>

              {/* Gatekeeper Note */}
              <div className="p-3 rounded-lg bg-amber-500/10 border border-amber-500/20 text-amber-300 text-[11px] flex items-start gap-2">
                <Info className="w-4 h-4 shrink-0 mt-0.5 text-amber-400" />
                <div>
                  <strong>macOS Gatekeeper tip:</strong> Because this app is built locally without an Apple Developer ID certificate ($99/yr), the first time you run it, macOS may say <em>"App from an unidentified developer"</em>. Simply right-click <code className="text-white">EasyIPTV.app</code> and choose <strong>Open</strong>, or go to <strong>System Settings &gt; Privacy & Security</strong> and click <strong>Open Anyway</strong>.
                </div>
              </div>

            </div>

            <div className="pt-4 mt-4 border-t border-neutral-800 flex justify-end">
              <button
                onClick={() => setShowDmgGuide(false)}
                className="px-4 py-1.5 rounded-lg bg-blue-600 hover:bg-blue-500 text-white text-xs font-semibold transition-colors cursor-pointer"
              >
                Got it
              </button>
            </div>

          </div>
        </div>
      )}

    </div>
  );
};
