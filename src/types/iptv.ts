export type ContentType = 'live' | 'movie' | 'series';

export interface ChannelItem {
  id: string;
  name: string;
  groupTitle: string;
  logoURL?: string;
  streamURL: string;
  tvgID?: string;
  tvgName?: string;
  isFavorite?: boolean;
  contentType?: ContentType;
}

export interface XtreamCredentials {
  serverUrl: string;
  username: string;
  password: string;
  label?: string;
}

export interface XtreamAccountInfo {
  status: string;
  expDate?: string;
  maxConnections?: number;
  activeConnections?: number;
  message?: string;
  serverUrl: string;
  username: string;
}

export interface SeriesEpisode {
  id: string | number;
  episodeNum?: number;
  title: string;
  containerExtension?: string;
  info?: {
    duration?: string;
    plot?: string;
    rating?: string;
    releasedate?: string;
  };
  season: string | number;
  streamUrl?: string;
}

export interface SeriesDetail {
  seasons?: { season_number: number; name?: string; episode_count?: number }[];
  info?: {
    name?: string;
    cover?: string;
    plot?: string;
    genre?: string;
    releaseDate?: string;
    rating?: string;
    backdrop_path?: string[];
  };
  episodes?: Record<string, any[]>;
}

export interface SwiftFileInfo {
  filename: string;
  title: string;
  category: 'Model' | 'Networking' | 'State' | 'View' | 'App' | 'Config' | 'Build';
  description: string;
  code: string;
  highlights: string[];
}
