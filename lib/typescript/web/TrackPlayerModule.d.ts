import type { Spec } from '../src/NativeTrackPlayer';
import type { Track, UpdateOptions, PlaybackState } from '../src/interfaces';
import { PlaylistPlayer, RepeatMode } from './TrackPlayer';
export declare class TrackPlayerModule extends PlaylistPlayer implements Spec {
    protected emitter: import("react-native").DeviceEventEmitterStatic;
    protected progressUpdateEventInterval: NodeJS.Timeout | undefined;
    getConstants(): {
        CAPABILITY_JUMP_BACKWARD: number;
        CAPABILITY_JUMP_FORWARD: number;
        CAPABILITY_PAUSE: number;
        CAPABILITY_PLAY: number;
        CAPABILITY_PLAY_FROM_ID: number;
        CAPABILITY_PLAY_FROM_SEARCH: number;
        CAPABILITY_SEEK_TO: number;
        CAPABILITY_SET_RATING: number;
        CAPABILITY_SKIP: number;
        CAPABILITY_SKIP_TO_NEXT: number;
        CAPABILITY_SKIP_TO_PREVIOUS: number;
        CAPABILITY_STOP: number;
        RATING_HEART: number;
        RATING_THUMBS_UP_DOWN: number;
        RATING_3_STARS: number;
        RATING_4_STARS: number;
        RATING_5_STARS: number;
        RATING_PERCENTAGE: number;
        PITCH_ALGORITHM_LINEAR: number;
        PITCH_ALGORITHM_MUSIC: number;
        PITCH_ALGORITHM_VOICE: number;
        STATE_BUFFERING: string;
        STATE_LOADING: string;
        STATE_NONE: string;
        STATE_PAUSED: string;
        STATE_PLAYING: string;
        STATE_READY: string;
        STATE_STOPPED: string;
        REPEAT_OFF: RepeatMode;
        REPEAT_TRACK: RepeatMode;
        REPEAT_QUEUE: RepeatMode;
    };
    get state(): PlaybackState;
    set state(newState: PlaybackState);
    updateOptions(options: UpdateOptions): Promise<void>;
    protected setupProgressUpdates(interval?: number): void;
    protected clearUpdateEventInterval(): void;
    protected onPlaylistEnded(): Promise<void>;
    get playWhenReady(): boolean;
    set playWhenReady(pwr: boolean);
    getPlayWhenReady(): Promise<boolean>;
    setPlayWhenReady(pwr: boolean): Promise<boolean>;
    load(track: Track): Promise<void>;
    getQueue(): Promise<Track[]>;
    setQueue(queue: Track[]): Promise<void>;
    getActiveTrack(): Promise<Track | undefined>;
    getActiveTrackIndex(): Promise<number | undefined>;
    getPlaybackState(): Promise<PlaybackState>;
    /**
     * overrides to match interface definition
     *
     * NOTE: these can be removed once we migrate to a sync API
     */
    pause(): Promise<void>;
    seekBy(seconds: number): Promise<void>;
    seekTo(seconds: number): Promise<void>;
    setVolume(volume: number): Promise<void>;
    getVolume(): Promise<number>;
    setRate(rate: number): Promise<number>;
    /**
     * stubbed methods for cross-platform compat
     */
    addListener(): void;
    removeListeners(): void;
    acquireWakeLock(): Promise<void>;
    abandonWakeLock(): Promise<void>;
    validateOnStartCommandIntent(): Promise<boolean>;
}
//# sourceMappingURL=TrackPlayerModule.d.ts.map