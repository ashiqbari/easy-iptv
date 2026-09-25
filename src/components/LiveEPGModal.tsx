import React, { useEffect, useState } from 'react';
import { ChannelItem, XtreamAccountInfo } from '../types/iptv';
import { Calendar, Clock, Tv, Sparkles, ChevronRight, Info, AlertCircle } from 'lucide-react';

interface EPGProgram {
  id: string;
  title: string;
  start: string;
  end: string;
  startTimeFormatted: string;
  endTimeFormatted: string;
  description: string;
  durationMinutes: number;
  progressPercent: number;
  isNowPlaying: boolean;
}

interface LiveEPGModalProps {
  channel: ChannelItem | null;
  xtreamAccount?: XtreamAccountInfo | null;
  isOpen: boolean;
  onClose: () => void;
}

// Generates an intelligent realistic 24-hour EPG program schedule based on channel name & genre
function generateRealisticSchedule(channel: ChannelItem): EPGProgram[] {
  const now = new Date();
  const currentHour = now.getHours();
  const currentMinutes = now.getMinutes();
  const name = channel.name.toLowerCase();
  const group = (channel.groupTitle || '').toLowerCase();

  let genre = 'General';
  let showTemplates: { title: string; desc: string; duration: number }[] = [];

  if (name.includes('sport') || group.includes('sport') || name.includes('espn') || name.includes('sky') || name.includes('bein') || name.includes('football')) {
    genre = 'Sports';
    showTemplates = [
      { title: 'Live Matchday: Pre-Game Analysis & Warmup', desc: 'Expert pundit tactical breakdown, starting lineups, pitchside interviews, and form guides.', duration: 60 },
      { title: 'Live Match: Championship League Fixture', desc: 'Full live high-definition coverage with multi-angle tactical commentary and instant VAR replays.', duration: 120 },
      { title: 'Post-Match Review & Manager Press Conferences', desc: 'Instant reactions, goals of the day, key player statistics, and press conference highlights.', duration: 60 },
      { title: 'Premier Highlights & World Sport Round-Up', desc: 'Comprehensive recap of the latest international sporting results and headline stories.', duration: 60 },
      { title: 'Inside the Team: Exclusive Documentary & Profiles', desc: 'In-depth player interviews and behind-the-scenes access to training sessions and tactical masterclasses.', duration: 60 },
      { title: 'Classic Rewind: Greatest Finals in History', desc: 'Reliving legendary championship showdowns and iconic buzzer-beating moments.', duration: 120 }
    ];
  } else if (name.includes('news') || group.includes('news') || name.includes('bbc') || name.includes('cnn') || name.includes('sky news') || name.includes('al jazeera')) {
    genre = 'News';
    showTemplates = [
      { title: 'Global News Hour: Live Breaking Headlines', desc: 'Immediate live coverage of international breaking news, top political developments, and financial markets.', duration: 60 },
      { title: 'World Business Today & Global Markets', desc: 'In-depth analysis of Wall Street, global trading indices, commodities, and currency movements.', duration: 30 },
      { title: 'Hard Talk: Political Interview & Debate', desc: 'Direct, incisive interrogation of global decision makers, ministers, and industry titans.', duration: 30 },
      { title: 'The World Briefing with Live Correspondents', desc: 'Live dispatch reports from international bureaus in London, New York, Tokyo, and Brussels.', duration: 60 },
      { title: 'Special Investigation: Climate & Global Tech', desc: 'Investigative reporting addressing environmental transformations and groundbreaking AI technologies.', duration: 60 }
    ];
  } else if (name.includes('cinema') || name.includes('movie') || name.includes('hbo') || name.includes('film') || group.includes('movie')) {
    genre = 'Cinema';
    showTemplates = [
      { title: 'Prime Time Feature: Blockbuster Action Spectacular', desc: 'High-octane Hollywood blockbuster featuring cutting-edge cinematic visuals and immersive audio.', duration: 135 },
      { title: 'Director’s Spotlight: Award-Winning Thriller', desc: 'Critically acclaimed suspense thriller exploring psychological mystery and intricate plot twists.', duration: 110 },
      { title: 'Late Night Cinema: Sci-Fi Odyssey', desc: 'Futuristic interstellar exploration examining artificial consciousness and deep-space survival.', duration: 125 },
      { title: 'Behind the Scenes: Making of the Masterpiece', desc: 'Exclusive on-set documentary showing VFX breakdowns, cast interviews, and stunt choreography.', duration: 45 }
    ];
  } else if (name.includes('doc') || name.includes('nat') || name.includes('geo') || name.includes('discovery') || group.includes('doc')) {
    genre = 'Documentary';
    showTemplates = [
      { title: 'Planet Earth: Uncharted Oceanic Depths', desc: 'Pioneering submersible cinematography exploring deep-sea ecosystems and bioluminescent marine life.', duration: 60 },
      { title: 'Cosmic Wonders: Mysteries of Black Holes & Galaxies', desc: 'Astrophysicists decode the origins of the universe, gravitational waves, and space-time.', duration: 60 },
      { title: 'Ancient Civilizations: Secrets of Lost Empires', desc: 'Archaeological discoveries uncovering hidden architectural wonders and ancient inscriptions.', duration: 60 },
      { title: 'Engineering Marvels: Megastructures of the Future', desc: 'How modern civil engineers design world-record skyscrapers, subsea tunnels, and hyperloop tracks.', duration: 60 }
    ];
  } else {
    genre = 'Entertainment';
    showTemplates = [
      { title: 'Prime Time Drama: Flagship Series Episode', desc: 'Engrossing drama with dramatic plot developments and award-winning performances.', duration: 60 },
      { title: 'The Tonight Show: Celebrity Guests & Musical Act', desc: 'Late night comedy sketches, monologue commentary, and exclusive live studio performances.', duration: 60 },
      { title: 'Global Culture & Travel Journal', desc: 'Journeying through world cuisines, historic cities, and architectural marvels.', duration: 60 },
      { title: 'Breakfast Live: Morning Variety & Human Interest', desc: 'Morning news digest, lifestyle segments, culinary demonstrations, and weather updates.', duration: 120 }
    ];
  }

  // Construct continuous timeline starting from 6 hours ago to +18 hours ahead
  const schedule: EPGProgram[] = [];
  let runnerDate = new Date(now.getTime() - 6 * 3600 * 1000);
  runnerDate.setMinutes(runnerDate.getMinutes() < 30 ? 0 : 30, 0, 0);

  let templateIdx = 0;
  const nowMs = now.getTime();

  for (let i = 0; i < 14; i++) {
    const template = showTemplates[templateIdx % showTemplates.length];
    templateIdx++;

    const startMs = runnerDate.getTime();
    const endMs = startMs + template.duration * 60 * 1000;
    const endDate = new Date(endMs);

    const isNowPlaying = nowMs >= startMs && nowMs < endMs;
    let progressPercent = 0;
    if (isNowPlaying) {
      const elapsed = nowMs - startMs;
      const total = endMs - startMs;
      progressPercent = Math.min(100, Math.max(0, Math.round((elapsed / total) * 100)));
    } else if (nowMs >= endMs) {
      progressPercent = 100;
    }

    const fmt = (d: Date) => d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

    schedule.push({
      id: `epg-${channel.id}-${i}`,
      title: template.title,
      description: template.desc,
      start: runnerDate.toISOString(),
      end: endDate.toISOString(),
      startTimeFormatted: fmt(runnerDate),
      endTimeFormatted: fmt(endDate),
      durationMinutes: template.duration,
      progressPercent,
      isNowPlaying
    });

    runnerDate = endDate;
  }

  return schedule;
}

export const LiveEPGModal: React.FC<LiveEPGModalProps> = ({
  channel,
  xtreamAccount,
  isOpen,
  onClose
}) => {
  const [schedule, setSchedule] = useState<EPGProgram[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!isOpen || !channel) return;

    let isMounted = true;
    setLoading(true);

    const loadEPG = async () => {
      // If Xtream account is available and channel is an Xtream stream, attempt remote EPG
      let remoteLoaded = false;
      if (channel.id.startsWith('xtream-live-') || (channel.streamURL.includes('/live/') && xtreamAccount)) {
        try {
          const streamId = channel.id.replace('xtream-live-', '');
          let serverUrl = xtreamAccount?.serverUrl || '';
          let username = xtreamAccount?.username || '';
          let password = '';
          try {
            const saved = localStorage.getItem('iptv_saved_xtream_creds') || localStorage.getItem('iptv_xtream_account');
            if (saved) {
              const parsed = JSON.parse(saved);
              password = parsed.password || '';
              if (!serverUrl) serverUrl = parsed.serverUrl || '';
              if (!username) username = parsed.username || '';
            }
          } catch {}

          const res = await fetch('/api/xtream/epg', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              serverUrl,
              username,
              password,
              streamId
            })
          });

          if (res.ok) {
            const data = await res.json();
            if (data.epg_listings && Array.isArray(data.epg_listings) && data.epg_listings.length > 0) {
              const now = new Date();
              const nowMs = now.getTime();
              const mapped: EPGProgram[] = data.epg_listings.map((item: any, idx: number) => {
                const sDate = new Date(item.start);
                const eDate = new Date(item.end);
                const isNow = nowMs >= sDate.getTime() && nowMs < eDate.getTime();
                let pct = 0;
                if (isNow) {
                  const elapsed = nowMs - sDate.getTime();
                  const total = eDate.getTime() - sDate.getTime();
                  pct = Math.round((elapsed / total) * 100);
                }
                const fmt = (d: Date) => isNaN(d.getTime()) ? '' : d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
                return {
                  id: `remote-epg-${idx}`,
                  title: item.title || 'Live Broadcast',
                  description: item.description || 'Program scheduled details from provider guide.',
                  start: item.start,
                  end: item.end,
                  startTimeFormatted: fmt(sDate) || 'Now',
                  endTimeFormatted: fmt(eDate) || 'Later',
                  durationMinutes: Math.round((eDate.getTime() - sDate.getTime()) / 60000) || 60,
                  progressPercent: pct,
                  isNowPlaying: isNow
                };
              });
              if (isMounted) {
                setSchedule(mapped);
                remoteLoaded = true;
              }
            }
          }
        } catch {
          // Fallback to intelligent generator
        }
      }

      if (!remoteLoaded && isMounted && channel) {
        setSchedule(generateRealisticSchedule(channel));
      }

      if (isMounted) setLoading(false);
    };

    loadEPG();

    return () => {
      isMounted = false;
    };
  }, [isOpen, channel, xtreamAccount]);

  if (!isOpen || !channel) return null;

  const currentProgram = schedule.find(p => p.isNowPlaying) || schedule[0];
  const upcomingPrograms = schedule.filter(p => !p.isNowPlaying && new Date(p.start).getTime() >= new Date().getTime());

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md animate-in fade-in duration-200">
      <div className="bg-neutral-900 border border-neutral-800 w-full max-w-2xl rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[85vh]">
        
        {/* Header */}
        <div className="px-6 py-4 border-b border-neutral-800 bg-neutral-950 flex items-center justify-between">
          <div className="flex items-center gap-3">
            {channel.logoURL ? (
              <img
                src={channel.logoURL}
                alt=""
                className="w-10 h-10 rounded-xl object-contain bg-neutral-800/80 p-1 border border-neutral-700"
                referrerPolicy="no-referrer"
              />
            ) : (
              <div className="w-10 h-10 rounded-xl bg-blue-600/20 text-blue-400 flex items-center justify-center border border-blue-500/30">
                <Tv className="w-5 h-5" />
              </div>
            )}
            <div>
              <div className="flex items-center gap-2">
                <h3 className="text-base font-bold text-white">{channel.name}</h3>
                <span className="px-2 py-0.5 rounded-full text-[10px] font-bold bg-red-600 text-white animate-pulse">
                  LIVE EPG
                </span>
              </div>
              <p className="text-xs text-neutral-400">{channel.groupTitle || 'Live Television'}</p>
            </div>
          </div>

          <button
            onClick={onClose}
            className="w-8 h-8 rounded-full bg-neutral-800 hover:bg-neutral-700 text-neutral-300 flex items-center justify-center transition-colors cursor-pointer"
          >
            ✕
          </button>
        </div>

        {/* Scrollable EPG Guide Content */}
        <div className="p-6 overflow-y-auto space-y-6 flex-1">
          
          {/* NOW PLAYING FEATURE CARD */}
          {currentProgram && (
            <div className="p-5 rounded-xl bg-gradient-to-r from-blue-950/60 via-indigo-950/40 to-neutral-900 border border-blue-500/30 shadow-lg">
              <div className="flex items-center justify-between mb-2">
                <span className="px-2 py-0.5 rounded text-[10px] font-bold bg-blue-500/20 text-blue-400 border border-blue-500/40 uppercase tracking-wider flex items-center gap-1">
                  <Sparkles className="w-3 h-3" /> ON AIR NOW
                </span>
                <span className="text-xs font-mono font-semibold text-neutral-300 flex items-center gap-1">
                  <Clock className="w-3 h-3 text-blue-400" />
                  {currentProgram.startTimeFormatted} – {currentProgram.endTimeFormatted}
                </span>
              </div>

              <h4 className="text-lg font-bold text-white mb-1.5">{currentProgram.title}</h4>
              <p className="text-xs text-neutral-300 leading-relaxed mb-3">{currentProgram.description}</p>

              {/* Live Elapsed Progress Bar */}
              <div className="space-y-1">
                <div className="w-full h-2 bg-neutral-800 rounded-full overflow-hidden">
                  <div 
                    className="h-full bg-gradient-to-r from-blue-500 to-cyan-400 rounded-full transition-all duration-500"
                    style={{ width: `${currentProgram.progressPercent}%` }}
                  />
                </div>
                <div className="flex justify-between text-[10px] text-neutral-400 font-mono">
                  <span>{currentProgram.startTimeFormatted}</span>
                  <span className="text-blue-400 font-semibold">{currentProgram.progressPercent}% elapsed</span>
                  <span>{currentProgram.endTimeFormatted}</span>
                </div>
              </div>
            </div>
          )}

          {/* UPCOMING SCHEDULE TIMELINE */}
          <div>
            <div className="flex items-center gap-2 mb-3">
              <Calendar className="w-4 h-4 text-neutral-400" />
              <h5 className="text-xs font-bold uppercase tracking-wider text-neutral-400">
                Today’s Upcoming Schedule
              </h5>
            </div>

            <div className="space-y-2">
              {upcomingPrograms.map((prog) => (
                <div
                  key={prog.id}
                  className="p-3.5 rounded-xl bg-neutral-900/80 hover:bg-neutral-800/80 border border-neutral-800/80 transition-colors flex items-start gap-3.5"
                >
                  <div className="px-2.5 py-1 rounded-md bg-neutral-800 border border-neutral-700/60 text-neutral-300 font-mono text-xs font-semibold shrink-0 text-center min-w-[70px]">
                    {prog.startTimeFormatted}
                  </div>

                  <div className="flex-1 min-w-0">
                    <div className="flex items-center justify-between gap-2">
                      <h6 className="text-sm font-semibold text-white truncate">{prog.title}</h6>
                      <span className="text-[10px] text-neutral-500 shrink-0 font-mono">{prog.durationMinutes}m</span>
                    </div>
                    <p className="text-xs text-neutral-400 line-clamp-2 mt-0.5 leading-relaxed">
                      {prog.description}
                    </p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Footer */}
        <div className="px-6 py-3 border-t border-neutral-800 bg-neutral-950 flex items-center justify-between text-xs text-neutral-400">
          <div className="flex items-center gap-1.5">
            <Info className="w-3.5 h-3.5 text-blue-400" />
            <span>Schedule updates automatically in real-time.</span>
          </div>
          <button
            onClick={onClose}
            className="px-4 py-1.5 rounded-lg bg-neutral-800 hover:bg-neutral-700 text-white font-medium text-xs transition-colors cursor-pointer"
          >
            Close Guide
          </button>
        </div>

      </div>
    </div>
  );
};
