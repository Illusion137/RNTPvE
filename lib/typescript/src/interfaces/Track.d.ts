import type { PitchAlgorithm, TrackType } from '../constants';
import type { ResourceObject } from './ResourceObject';
import type { TrackMetadataBase } from './TrackMetadataBase';
export interface Track extends TrackMetadataBase {
    url: string;
    type?: TrackType;
    /** The user agent HTTP header */
    userAgent?: string;
    /** Mime type of the media file */
    contentType?: string;
    /** (iOS only) The pitch algorithm to apply to the sound. */
    pitchAlgorithm?: PitchAlgorithm;
    headers?: {
        [key: string]: any;
    };
    /** (iOS only) Force WebM/Opus playback pipeline for local downloaded files. */
    isOpus?: boolean;
    /** (iOS only) Activate YouTube SABR (server-adaptive bitrate) mode. */
    isSabr?: boolean;
    /** (iOS only) SABR server endpoint URL. */
    sabrServerUrl?: string;
    /** (iOS only) Base64-encoded ustreamer config from the YouTube player response. */
    sabrUstreamerConfig?: string;
    /** (iOS only) Audio format descriptors from the YouTube player response. */
    sabrFormats?: Record<string, unknown>[];
    /** (iOS only) PoToken for SABR stream authentication. */
    poToken?: string;
    [key: string]: any;
}
export type AddTrack = Track & {
    url: string | ResourceObject;
    artwork?: string | ResourceObject;
};
//# sourceMappingURL=Track.d.ts.map