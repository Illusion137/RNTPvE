import Foundation

// MARK: - Supporting Types

struct InitializedFormat {
    var format_initialization_metadata: FormatInitializationMetadata
    var downloaded_segments: [Int: Segment]
    var last_media_headers: [MediaHeader]
}

struct SabrStreamState {
    var duration_ms: Double
    var request_number: Int
    var player_time_ms: Double
    var active_sabr_contexts: [Int]
    var sabr_context_updates: [(Int, SabrContextUpdate)]
    var format_to_discard: String?
    var cached_buffered_ranges: [BufferedRange]
    var next_request_policy: NextRequestPolicy?
    var initialized_formats: [InitializedFormatState]
}

struct InitializedFormatState {
    var format_key: String
    var format_initialization_metadata: FormatInitializationMetadata
    var downloaded_segments: [(Int, Segment)]
    var last_media_headers: [MediaHeader]
}

struct SelectedFormats {
    var video_format: SabrFormat
    var audio_format: SabrFormat
}

struct ProgressTracker {
    var last_progress_time: Date
    var last_downloaded_duration: Double
    var stall_count: Int
}

// MARK: - SabrStream

private let tag = "SabrStream"
private let default_max_retries = 10
private let max_backoff_ms: Double = 8000
private let backoff_multiplier: Double = 500
private let default_stall_detection_ms: Double = 30000
private let max_stalls = 5

/**
 * Manages the download and processing of YouTube's Server-Adaptive Bitrate (SABR) streams.
 *
 * Handles the entire lifecycle of a SABR stream:
 * - Selecting appropriate video and audio formats.
 * - Making network requests to fetch media segments.
 * - Processing UMP parts in real-time.
 * - Handling server-side directives like redirects, context updates, and backoff policies.
 * - Emitting events for key stream updates.
 * - Providing separate AsyncStreams for video and audio data.
 */
class SabrStream {
    private let logger = Logger.get_instance()
    private let fetch_function: FetchFunction
    private var format_ids: [SabrFormat] = []

    // Video/audio streams and their continuations.
    private(set) var video_stream: AsyncThrowingStream<Data, Error>
    private(set) var audio_stream: AsyncThrowingStream<Data, Error>
    private var video_continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var audio_continuation: AsyncThrowingStream<Data, Error>.Continuation?

    // Event callbacks
    private var on_format_initialization_listeners: [(InitializedFormat) -> Void] = []
    private var on_stream_protection_status_listeners: [(StreamProtectionStatus) -> Void] = []
    private var on_reload_player_response_listeners: [(ReloadPlaybackContext) -> Void] = []
    private var on_duration_updated_listeners: [(Double) -> Void] = []
    private var on_finish_listeners: [() -> Void] = []
    private var on_abort_listeners: [() -> Void] = []

    private var server_abr_streaming_url: String?
    private var video_playback_ustreamer_config: String?
    private var client_info: ClientInfo?
    private var po_token: String?
    private var cookie: String?

    private var next_request_policy: NextRequestPolicy?
    private var stream_protection_status: StreamProtectionStatus?
    private var sabr_contexts = [Int: SabrContextUpdate]()
    private var active_sabr_context_types = Set<Int>()
    private var initialized_formats_map = [String: InitializedFormat]()
    private var abort_task: Task<Void, Never>?
    private var partial_segment_queue = [Int: Segment]()
    private var request_number = 0
    private var duration_ms: Double = .infinity
    private var cached_buffered_ranges: [BufferedRange]?
    private var format_to_discard: String?
    private var media_headers_processed = false
    private var main_format: InitializedFormat?
    private var _errored = false
    private var _aborted = false

    private var progress_tracker = ProgressTracker(
        last_progress_time: Date(),
        last_downloaded_duration: 0,
        stall_count: 0
    )

    init(config: SabrStreamConfig = SabrStreamConfig()) {
        self.fetch_function = config.fetch ?? default_fetch
        self.server_abr_streaming_url = config.server_abr_streaming_url
        self.video_playback_ustreamer_config = config.video_playback_ustreamer_config
        self.client_info = config.client_info
        self.po_token = config.po_token
        self.cookie = config.cookie
        self.duration_ms = config.duration_ms ?? .infinity
        self.format_ids = config.formats ?? []

        var video_cont: AsyncThrowingStream<Data, Error>.Continuation?
        var audio_cont: AsyncThrowingStream<Data, Error>.Continuation?

        video_stream = AsyncThrowingStream { video_cont = $0 }
        audio_stream = AsyncThrowingStream { audio_cont = $0 }

        video_continuation = video_cont
        audio_continuation = audio_cont
    }

    // MARK: - Event Emitter

    func on_format_initialization(_ listener: @escaping (InitializedFormat) -> Void) {
        on_format_initialization_listeners.append(listener)
    }

    func on_stream_protection_status_update(_ listener: @escaping (StreamProtectionStatus) -> Void) {
        on_stream_protection_status_listeners.append(listener)
    }

    func on_reload_player_response(_ listener: @escaping (ReloadPlaybackContext) -> Void) {
        on_reload_player_response_listeners.append(listener)
    }

    func on_duration_updated(_ listener: @escaping (Double) -> Void) {
        on_duration_updated_listeners.append(listener)
    }

    func on_finish(_ listener: @escaping () -> Void) {
        on_finish_listeners.append(listener)
    }

    func on_abort(_ listener: @escaping () -> Void) {
        on_abort_listeners.append(listener)
    }

    // MARK: - Public API

    /// Sets Proof of Origin (PO) token.
    func set_po_token(po_token: String) {
        self.po_token = po_token
    }

    /// Sets the available server ABR formats.
    func set_server_abr_formats(formats: [SabrFormat]) {
        format_ids.append(contentsOf: formats)
    }

    /// Sets the total duration of the stream in milliseconds.
    func set_duration_ms(duration_ms: Double) {
        self.duration_ms = duration_ms
    }

    /// Sets the server ABR streaming URL for media requests.
    func set_streaming_url(url: String) {
        self.server_abr_streaming_url = url
    }

    /// Sets the Ustreamer configuration string.
    func set_ustreamer_config(config: String) {
        self.video_playback_ustreamer_config = config
    }

    /// Sets the client information used in SABR requests.
    func set_client_info(client_info: ClientInfo) {
        self.client_info = client_info
    }

    /// Aborts the download process, closing all streams and cleaning up resources.
    func abort() {
        logger.debug(tag: tag, message: "Aborting download process")
        _aborted = true
        abort_task?.cancel()
        video_continuation?.finish(throwing: CancellationError())
        audio_continuation?.finish(throwing: CancellationError())
        reset_state()
        on_abort_listeners.forEach { $0() }
    }

    // MARK: - State

    /// Returns a serializable state object to restore the stream later.
    func get_state() throws -> SabrStreamState {
        guard let main_format else {
            throw SabrStreamError.main_format_not_initialized
        }

        let player_time_ms = get_total_downloaded_duration(main_format)
        var initialized_formats_state: [InitializedFormatState] = []

        for (format_key, format) in initialized_formats_map {
            initialized_formats_state.append(InitializedFormatState(
                format_key: format_key,
                format_initialization_metadata: format.format_initialization_metadata,
                downloaded_segments: Array(format.downloaded_segments),
                last_media_headers: format.last_media_headers
            ))
        }

        return SabrStreamState(
            duration_ms: duration_ms,
            request_number: request_number,
            player_time_ms: player_time_ms,
            active_sabr_contexts: Array(active_sabr_context_types),
            sabr_context_updates: Array(sabr_contexts),
            format_to_discard: format_to_discard,
            cached_buffered_ranges: cached_buffered_ranges ?? [],
            next_request_policy: next_request_policy,
            initialized_formats: initialized_formats_state
        )
    }

    // MARK: - Start

    /**
     * Initiates the streaming process for the selected formats.
     * - Returns: The video/audio streams and selected formats.
     */
    func start(options: SabrPlaybackOptions) async throws -> (
        video_stream: AsyncThrowingStream<Data, Error>,
        audio_stream: AsyncThrowingStream<Data, Error>,
        selected_formats: SelectedFormats
    ) {
        let selected = try select_formats(options: options)

        abort_task = Task {
            await setup_streaming_process(
                video_format: selected.video_format,
                audio_format: selected.audio_format,
                options: options
            )
        }

        return (video_stream, audio_stream, selected)
    }

    // MARK: - Streaming Process

    private func setup_streaming_process(
        video_format: SabrFormat,
        audio_format: SabrFormat,
        options: SabrPlaybackOptions
    ) async {
        do {
            _errored = false
            _aborted = false

            var player_time_ms: Double = options.start_time_ms ?? 0

            if let state = options.state, restore_state(video_format: video_format, audio_format: audio_format, state: state) {
                player_time_ms = options.state?.player_time_ms ?? 0
            }

            let max_retries = options.max_retries ?? default_max_retries
            // Always audio-only: video is never needed for audio playback on Apple platforms.
            let enabled_track_types_bitfield = EnabledTrackTypes.audio_only

            var abr_state = AbrState(
                player_time_ms: player_time_ms,
                audio_track_id: audio_format.audio_track_id,
                playback_rate: 1,
                sticky_resolution: video_format.height ?? 360,
                drc_enabled: audio_format.is_drc ?? false,
                client_viewport_is_flexible: false,
                visibility: 1,
                enabled_track_types_bitfield: enabled_track_types_bitfield
            )

            if abr_state.enabled_track_types_bitfield == 1 || abr_state.enabled_track_types_bitfield == 2 {
                format_to_discard = abr_state.enabled_track_types_bitfield == 1
                    ? FormatKeyUtils.from_format(video_format)
                    : FormatKeyUtils.from_format(audio_format)
            }

            while abr_state.player_time_ms < duration_ms {
                if _aborted {
                    logger.debug(tag: tag, message: "Download process aborted, exiting streaming loop.")
                    break
                }

                logger.debug(tag: tag, message: "Starting new segment fetch at playback position: \(abr_state.player_time_ms)ms")

                main_format = abr_state.enabled_track_types_bitfield == 1
                    ? initialized_formats_map[FormatKeyUtils.from_format(audio_format) ?? ""]
                    : initialized_formats_map[FormatKeyUtils.from_format(video_format) ?? ""]

                if let main_format {
                    validate_and_correct_duration(format_initialization_metadata: main_format.format_initialization_metadata)
                }

                abr_state.player_time_ms = main_format.map { get_total_downloaded_duration($0) } ?? 0

                if abr_state.player_time_ms >= duration_ms { break }  // all segments downloaded

                let stall_check = check_for_stall(player_time_ms: abr_state.player_time_ms, stall_detection_ms: options.stall_detection_ms)

                if stall_check.should_stop { break }

                let success = await execute_with_retry(max_retries: max_retries) {
                    try await self.fetch_and_process_segments(
                        abr_state: abr_state,
                        selected_audio_format: audio_format,
                        selected_video_format: video_format
                    )
                }

                if !success { break }
            }
        } catch {
            if !_aborted {
                error_handler(error: error as NSError, notify_controllers: true)
            }
        }

        if !_aborted {
            validate_downloaded_segments()
            if !_errored {
                video_continuation?.finish()
                audio_continuation?.finish()
            }
            reset_state()
            on_finish_listeners.forEach { $0() }
        }
    }

    // MARK: - State Restoration

    private func restore_state(video_format: SabrFormat, audio_format: SabrFormat, state: SabrStreamState) -> Bool {
        reset_state()

        guard !state.initialized_formats.isEmpty, state.duration_ms > 0, state.player_time_ms > 0 else {
            logger.warn(tag: tag, message: "Invalid or corrupt state object provided. Starting fresh.")
            return false
        }

        let expected_video_format_key = FormatKeyUtils.from_format(video_format) ?? ""
        let expected_audio_format_key = FormatKeyUtils.from_format(audio_format) ?? ""

        for format in state.initialized_formats {
            let format_key = format.format_key

            guard format_key == expected_video_format_key || format_key == expected_audio_format_key else {
                logger.warn(tag: tag, message: "State contains an unexpected format key \"\(format_key)\". It will be ignored.")
                continue
            }

            initialized_formats_map[format_key] = InitializedFormat(
                format_initialization_metadata: format.format_initialization_metadata,
                downloaded_segments: Dictionary(uniqueKeysWithValues: format.downloaded_segments),
                last_media_headers: format.last_media_headers
            )
        }

        guard initialized_formats_map[expected_video_format_key] != nil,
              initialized_formats_map[expected_audio_format_key] != nil else {
            logger.warn(tag: tag, message: "State is missing required format data for the selected video/audio formats. Starting fresh.")
            reset_state()
            return false
        }

        duration_ms = state.duration_ms
        request_number = state.request_number
        active_sabr_context_types = Set(state.active_sabr_contexts)
        sabr_contexts = Dictionary(uniqueKeysWithValues: state.sabr_context_updates)
        format_to_discard = state.format_to_discard
        cached_buffered_ranges = state.cached_buffered_ranges
        next_request_policy = state.next_request_policy

        return true
    }

    // MARK: - Stall Detection

    private func check_for_stall(player_time_ms: Double, stall_detection_ms: Double?) -> (should_stop: Bool, stalled: Bool) {
        let current_time = Date()
        let current_progress = player_time_ms
        let stall_threshold = stall_detection_ms ?? default_stall_detection_ms

        if current_progress > progress_tracker.last_downloaded_duration {
            progress_tracker.last_progress_time = current_time
            progress_tracker.last_downloaded_duration = current_progress
            progress_tracker.stall_count = 0
            return (false, false)
        }

        let elapsed_ms = current_time.timeIntervalSince(progress_tracker.last_progress_time) * 1000

        if elapsed_ms > stall_threshold {
            progress_tracker.stall_count += 1
            logger.warn(tag: tag, message: "Stream stalled for \(stall_threshold)ms (stall #\(progress_tracker.stall_count))")

            if progress_tracker.stall_count >= max_stalls {
                error_handler(error: NSError(domain: "SabrStream", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream stalled \(max_stalls) times, aborting"]), notify_controllers: true)
                return (true, true)
            }

            progress_tracker.last_progress_time = current_time

            let downloaded_duration_closeness = abs(duration_ms - current_progress)

            if downloaded_duration_closeness < 5000 {
                logger.warn(tag: tag, message: "Stream is close to completion, but stalled. Checking if we have the last segment.")

                let end_segment_number = Int(main_format?.format_initialization_metadata.end_segment_number ?? "0") ?? -1
                let last_segment = main_format?.downloaded_segments[end_segment_number]

                if let last_segment, last_segment.segment_number == end_segment_number {
                    logger.warn(tag: tag, message: "Last segment is already downloaded. Stopping further processing.")
                    return (true, true)
                }
            }

            return (false, true)
        }

        return (false, false)
    }

    // MARK: - Format Selection

    private func select_formats(options: SabrPlaybackOptions) throws -> SelectedFormats {
        let video_format = choose_format(format_ids, options.video_format, options: FormatOptions(
            quality: options.video_quality,
            prefer_web_m: options.prefer_web_m,
            prefer_h264: options.prefer_h264,
            prefer_mp4: options.prefer_mp4,
            is_audio: false
        ))

        let audio_format = choose_format(format_ids, options.audio_format, options: FormatOptions(
            quality: options.audio_quality,
            language: options.audio_language,
            prefer_web_m: options.prefer_web_m,
            prefer_mp4: options.prefer_mp4,
            prefer_opus: options.prefer_opus,
            is_audio: true
        ))

        if duration_ms < 0 { throw SabrStreamError.invalid_duration }
        guard let video_format, let audio_format else {
            throw SabrStreamError.no_suitable_formats
        }

        return SelectedFormats(video_format: video_format, audio_format: audio_format)
    }

    // MARK: - Segment Fetching

    private func fetch_and_process_segments(
        abr_state: AbrState,
        selected_audio_format: SabrFormat,
        selected_video_format: SabrFormat
    ) async throws {
        let initialized_video_format = initialized_formats_map[FormatKeyUtils.from_format(selected_video_format) ?? ""]
        let initialized_audio_format = initialized_formats_map[FormatKeyUtils.from_format(selected_audio_format) ?? ""]

        if cached_buffered_ranges?.isEmpty != false {
            cached_buffered_ranges = build_buffered_ranges(
                initialized_video_format: initialized_video_format,
                initialized_audio_format: initialized_audio_format
            )
        }

        let request_body = try build_request_body(
            abr_state: abr_state,
            selected_audio_format: selected_audio_format,
            selected_video_format: selected_video_format
        )

        media_headers_processed = false
        let (data, response) = try await make_streaming_request(body: request_body)
        let processed_parts = try await process_streaming_response(data: data, response: response)

        guard !processed_parts.isEmpty else {
            throw SabrStreamError.no_valid_parts
        }

        if processed_parts.contains(UMPPartId.MEDIA_HEADER) &&
            ((initialized_video_format?.last_media_headers.isEmpty == false && initialized_audio_format?.last_media_headers.isEmpty == false) ||
             (abr_state.enabled_track_types_bitfield != 0 && main_format?.last_media_headers.isEmpty == false)) {
            media_headers_processed = true
        }
    }

    private func build_buffered_ranges(
        initialized_video_format: InitializedFormat?,
        initialized_audio_format: InitializedFormat?
    ) -> [BufferedRange] {
        var buffered_ranges: [BufferedRange] = []
        let formats: [InitializedFormat?] = [initialized_video_format, initialized_audio_format]

        for initialized_format in formats.compactMap({ $0 }) {
            guard !initialized_format.last_media_headers.isEmpty else { continue }

            if FormatKeyUtils.from_format_initialization_metadata(initialized_format.format_initialization_metadata) == format_to_discard {
                continue
            }

            let media_headers = initialized_format.last_media_headers
            let total_duration_ms = media_headers.reduce(0) { $0 + (Int($1.duration_ms ?? "0") ?? 0) }

            buffered_ranges.append(BufferedRange(
                format_id: initialized_format.format_initialization_metadata.format_id,
                duration_ms: String(total_duration_ms),
                start_time_ms: String(media_headers.first?.start_ms ?? "0"),
                start_segment_index: media_headers.first?.sequence_number ?? 1,
                end_segment_index: media_headers.last?.sequence_number ?? 1,
                time_range: TimeRange(
                    timescale: media_headers.first?.time_range?.timescale,
                    duration_ticks: String(total_duration_ms),
                    start_ticks: media_headers.first?.start_ms
                )
            ))

            initialized_formats_map[FormatKeyUtils.from_format_initialization_metadata(initialized_format.format_initialization_metadata) ?? ""]?.last_media_headers = []
        }

        return buffered_ranges
    }

    private func build_request_body(
        abr_state: AbrState,
        selected_audio_format: SabrFormat,
        selected_video_format: SabrFormat
    ) throws -> Data {
        guard let video_playback_ustreamer_config else {
            throw SabrStreamError.missing_ustreamer_config
        }

        let buffered_ranges = cached_buffered_ranges ?? []
        let (sabr_contexts_list, unsent_sabr_contexts) = prepare_sabr_contexts()

        let (selected_format_ids, updated_buffered_ranges) = prepare_format_selections(
            formats: [selected_video_format, selected_audio_format],
            current_buffered_ranges: buffered_ranges
        )

        return VideoPlaybackAbrRequest.encode(VideoPlaybackAbrRequest(
            client_abr_state: abr_state,
            preferred_audio_format_ids: [selected_audio_format],
            preferred_video_format_ids: [selected_video_format],
            preferred_subtitle_format_ids: [],
            selected_format_ids: selected_format_ids,
            video_playback_ustreamer_config: base64_to_u8(video_playback_ustreamer_config as String),
            streamer_context: StreamerContext(
                sabr_contexts: sabr_contexts_list,
                unsent_sabr_contexts: unsent_sabr_contexts,
                po_token: po_token.map { base64_to_u8($0) },
                playback_cookie: next_request_policy?.playback_cookie.map { (try? $0.serializedData()) ?? Data() },
                client_info: client_info
            ),
            buffered_ranges: updated_buffered_ranges,
            field1000: []
        )).finish()
    }

    private func prepare_sabr_contexts() -> ([SabrContextUpdate], [Int]) {
        var sabr_contexts_list: [SabrContextUpdate] = []
        var unsent_sabr_contexts: [Int] = []

        for ctx_update in sabr_contexts.values {
            if active_sabr_context_types.contains(ctx_update.type ?? -1) {
                sabr_contexts_list.append(ctx_update)
            } else {
                unsent_sabr_contexts.append(ctx_update.type ?? 0)
            }
        }

        return (sabr_contexts_list, unsent_sabr_contexts)
    }

    private func prepare_format_selections(
        formats: [SabrFormat],
        current_buffered_ranges: [BufferedRange]
    ) -> ([SabrFormat], [BufferedRange]) {
        var selected_format_ids: [SabrFormat] = []
        var updated_buffered_ranges = current_buffered_ranges
        let formats_initialized = !initialized_formats_map.isEmpty

        for format in formats {
            let format_key = FormatKeyUtils.from_format(format)
            let should_discard = format_to_discard != nil && format_key == format_to_discard

            if should_discard {
                updated_buffered_ranges.append(BufferedRange(
                    format_id: format.format_id,
                    duration_ms: max_int32_value,
                    start_time_ms: "0",
                    start_segment_index: Int(max_int32_value) ?? 0,
                    end_segment_index: Int(max_int32_value) ?? 0,
                    time_range: TimeRange(
                        timescale: 1000,
                        duration_ticks: max_int32_value,
                        start_ticks: "0"
                    )
                ))
            }

            if formats_initialized || should_discard {
                selected_format_ids.append(format)
            }
        }

        return (selected_format_ids, updated_buffered_ranges)
    }

    private func make_streaming_request(body: Data) async throws -> (Data, URLResponse) {
        guard let streaming_url_str = server_abr_streaming_url,
              var url_components = URLComponents(string: streaming_url_str) else {
            throw SabrStreamError.missing_streaming_url
        }

        var query_items = url_components.queryItems ?? []
        query_items.append(URLQueryItem(name: "rn", value: String(request_number)))
        url_components.queryItems = query_items

        guard let url = url_components.url else {
            throw SabrStreamError.invalid_url
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "content-type")
        request.setValue("identity", forHTTPHeaderField: "accept-encoding")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "accept")
        if let cookie = cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpBody = body
        request.timeoutInterval = 60

        request_number += 1

        return try await fetch_function(request)
    }

    private func process_streaming_response(data: Data, response: URLResponse) async throws -> [Int] {
        guard let http_response = response as? HTTPURLResponse else {
            throw SabrStreamError.invalid_response
        }

        guard http_response.statusCode == 200 else {
            throw SabrStreamError.server_error(status: http_response.statusCode)
        }

        let ct = http_response.value(forHTTPHeaderField: "content-type") ?? ""
        guard ct.contains("yt-ump") else {
            throw SabrStreamError.unexpected_content_type(ct)
        }

        // Parse the full UMP response body
        var processed_parts: [Int] = []
        let buffer = CompositeBuffer(chunks: [data])
        let reader = UmpReader(composite_buffer: buffer)

        _ = reader.read { [weak self] part in
            guard let self = self else { return }
            self.dispatch_ump_part(part)
            processed_parts.append(part.type)
        }

        return processed_parts
    }

    private func dispatch_ump_part(_ part: Part) {
        switch part.type {
        case UMPPartId.FORMAT_INITIALIZATION_METADATA:
            handle_format_initialization_metadata(part: part)
        case UMPPartId.NEXT_REQUEST_POLICY:
            handle_next_request_policy(part: part)
        case UMPPartId.SABR_ERROR:
            handle_sabr_error(part: part)
        case UMPPartId.SABR_REDIRECT:
            handle_sabr_redirect(part: part)
        case UMPPartId.SABR_CONTEXT_UPDATE:
            handle_sabr_context_update(part: part)
        case UMPPartId.SABR_CONTEXT_SENDING_POLICY:
            handle_sabr_context_sending_policy(part: part)
        case UMPPartId.STREAM_PROTECTION_STATUS:
            handle_stream_protection_status(part: part)
        case UMPPartId.RELOAD_PLAYER_RESPONSE:
            handle_reload_player_response(part: part)
        case UMPPartId.MEDIA_HEADER:
            handle_media_header(part: part)
        case UMPPartId.MEDIA:
            handle_media(part: part)
        case UMPPartId.MEDIA_END:
            handle_media_end(part: part)
        default:
            break
        }
    }

    // MARK: - Retry Logic

    private func execute_with_retry(max_retries: Int, fetch_fn: () async throws -> Void) async -> Bool {
        let backoff_time_ms = Double(next_request_policy?.backoff_time_ms ?? 0)

        if backoff_time_ms > 0 {
            logger.debug(tag: tag, message: "Respecting server backoff policy: waiting \(backoff_time_ms)ms before request")
            try? await Task.sleep(nanoseconds: UInt64(backoff_time_ms) * 1_000_000)
        }

        for attempt in 1...(max_retries + 1) {
            defer { partial_segment_queue.removeAll() }

            do {
                try await fetch_fn()
                if media_headers_processed {
                    cached_buffered_ranges = nil
                }
                return true
            } catch {
                if _aborted {
                    logger.debug(tag: tag, message: "Download process aborted, skipping retry.")
                    return false
                }

                if attempt > max_retries {
                    logger.error(tag: tag, message: "Maximum retries (\(max_retries)) exceeded while fetching segment: \(error.localizedDescription)")
                    error_handler(error: error as NSError, notify_controllers: true)
                    break
                }

                let retry_backoff_ms = min(backoff_multiplier * pow(2.0, Double(attempt - 1)), max_backoff_ms)
                logger.warn(tag: tag, message: "Segment fetch attempt \(attempt)/\(max_retries + 1) failed - retrying in \(retry_backoff_ms)ms")
                try? await Task.sleep(nanoseconds: UInt64(retry_backoff_ms) * 1_000_000)
            }
        }

        return false
    }

    // MARK: - UMP Part Handlers

    private func decode_part<T>(part: Part, decoder: ProtobufDecoder<T>) -> T? {
        guard !part.data.chunks.isEmpty else { return nil }
        return try? decoder.decode(concatenate_chunks(part.data.chunks))
    }

    private func handle_format_initialization_metadata(part: Part) {
        guard let format_init_metadata = decode_part(part: part, decoder: FormatInitializationMetadata.decoder) else { return }

        let format_id_key = FormatKeyUtils.from_format_initialization_metadata(format_init_metadata) ?? ""

        let initialized_format = InitializedFormat(
            format_initialization_metadata: format_init_metadata,
            downloaded_segments: [:],
            last_media_headers: []
        )

        initialized_formats_map[format_id_key] = initialized_format
        logger.debug(tag: tag, message: "Initialized format: \(format_id_key)")
        on_format_initialization_listeners.forEach { $0(initialized_format) }
    }

    private func handle_next_request_policy(part: Part) {
        next_request_policy = decode_part(part: part, decoder: NextRequestPolicy.decoder)
    }

    private func handle_sabr_error(part: Part) {
        guard let sabr_error = decode_part(part: part, decoder: SabrError.decoder) else { return }
        // Propagate as thrown error — in this architecture we surface it through the error handler.
        error_handler(error: NSError(
            domain: "SabrStream",
            code: sabr_error.code ?? 0,
            userInfo: [NSLocalizedDescriptionKey: "SABR Error: \(sabr_error.type as Any) - \(sabr_error.code as Any)"]
        ), notify_controllers: true)
    }

    private func handle_sabr_redirect(part: Part) {
        guard let sabr_redirect = decode_part(part: part, decoder: SabrRedirect.decoder) else { return }
        if let url = sabr_redirect.url {
            server_abr_streaming_url = url
            logger.debug(tag: tag, message: "Redirecting to \(url)")
        }
    }

    private func handle_sabr_context_update(part: Part) {
        guard let sabr_context_update = decode_part(part: part, decoder: SabrContextUpdate.decoder) else { return }
        guard let update_type = sabr_context_update.type,
              let value = sabr_context_update.value, !value.isEmpty else { return }

        if sabr_context_update.write_policy == .KEEP_EXISTING && sabr_contexts[update_type] != nil {
            logger.debug(tag: tag, message: "Skipping SABR context update for type \(update_type)")
            return
        }

        sabr_contexts[update_type] = sabr_context_update

        if sabr_context_update.send_by_default == true {
            active_sabr_context_types.insert(update_type)
        }

        logger.debug(tag: tag, message: "Received SABR context update (type: \(update_type), sendByDefault: \(sabr_context_update.send_by_default as Any))")
    }

    private func handle_sabr_context_sending_policy(part: Part) {
        guard let policy = decode_part(part: part, decoder: SabrContextSendingPolicy.decoder) else { return }

        for start_policy in policy.start_policy where !active_sabr_context_types.contains(start_policy) {
            active_sabr_context_types.insert(start_policy)
            logger.debug(tag: tag, message: "Activated SABR context for type \(start_policy)")
        }

        for stop_policy in policy.stop_policy where active_sabr_context_types.contains(stop_policy) {
            active_sabr_context_types.remove(stop_policy)
            logger.debug(tag: tag, message: "Deactivated SABR context for type \(stop_policy)")
        }

        for discard_policy in policy.discard_policy where sabr_contexts[discard_policy] != nil {
            sabr_contexts.removeValue(forKey: discard_policy)
            logger.debug(tag: tag, message: "Discarded SABR context for type \(discard_policy)")
        }
    }

    private func handle_stream_protection_status(part: Part) {
        stream_protection_status = decode_part(part: part, decoder: StreamProtectionStatus.decoder)
        guard let status = stream_protection_status else { return }
        on_stream_protection_status_listeners.forEach { $0(status) }
        if status.status == 3 {
            error_handler(error: NSError(domain: "SabrStream", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot proceed with stream: attestation required"]), notify_controllers: true)
        } else if status.status == 2 {
            logger.warn(tag: tag, message: "Attestation pending.")
        }
    }

    private func handle_reload_player_response(part: Part) {
        guard let reload_playback_context = decode_part(part: part, decoder: ReloadPlaybackContext.decoder) else { return }
        let error_message = "Player response reload requested by server"
        logger.debug(tag: tag, message: "\(error_message) (token: \(reload_playback_context.reload_playback_params?.token as Any))")
        on_reload_player_response_listeners.forEach { $0(reload_playback_context) }
        // Terminate the stream — we cannot reload the player from the native side.
        // Setting _aborted stops the streaming loop on its next iteration check.
        error_handler(error: NSError(domain: "SabrStream", code: -2, userInfo: [NSLocalizedDescriptionKey: error_message]), notify_controllers: true)
        _aborted = true
    }

    private func handle_media_header(part: Part) {
        guard let media_header = decode_part(part: part, decoder: MediaHeader.decoder) else { return }

        let header_id = media_header.header_id ?? 0
        let format_id_key = FormatKeyUtils.from_media_header(media_header) ?? ""
        let segment_number = media_header.is_init_seg == true ? 0 : media_header.sequence_number ?? 0
        let duration_ms_val: String

        if let d = media_header.duration_ms {
            duration_ms_val = d
        } else {
            let ticks = Double(media_header.time_range?.duration_ticks ?? "0") ?? 0
            let timescale = Double(media_header.time_range?.timescale ?? 0)
            duration_ms_val = timescale > 0 ? String(Int(ceil(ticks / timescale * 1000))) : "0"
        }

        guard let initialized_format = initialized_formats_map[format_id_key] else {
            logger.warn(tag: tag, message: "No initialized format found for key: \(format_id_key) (segment \(segment_number))")
            return
        }

        let media_type = get_media_type(initialized_format)

        guard initialized_format.downloaded_segments[segment_number] == nil else {
            logger.debug(tag: tag, message: "Segment \(format_id_key) (segment: \(segment_number)) already downloaded. Ignoring.")
            return
        }

        partial_segment_queue[header_id] = Segment(
            format_id_key: format_id_key,
            segment_number: segment_number,
            duration_ms: duration_ms_val,
            media_header: media_header,
            buffered_chunks: []
        )

        logger.debug(tag: tag, message: "Enqueued \(media_type) segment \(segment_number) (Header ID: \(header_id), key: \(format_id_key), duration: \(duration_ms_val)ms)")
    }

    private func handle_media(part: Part) {
        let header_id = Int(part.data.get_uint8(position: 0))
        guard var segment = partial_segment_queue[header_id] else {
            logger.debug(tag: tag, message: "Received Media part for an unknown Header ID: \(header_id)")
            return
        }

        guard initialized_formats_map[segment.format_id_key] != nil else {
            logger.warn(tag: tag, message: "No initialized format found for key \(segment.format_id_key) (segment \(segment.segment_number))")
            return
        }

        let data_buffer = part.data.split(position: 1).remaining_buffer

        for chunk in data_buffer.chunks {
            segment.buffered_chunks.append(chunk)
        }

        partial_segment_queue[header_id] = segment
    }

    private func handle_media_end(part: Part) {
        let header_id = Int(part.data.get_uint8(position: 0))
        guard var segment = partial_segment_queue[header_id] else {
            logger.debug(tag: tag, message: "Received MediaEnd for an unknown Header ID: \(header_id)")
            return
        }

        let loaded_bytes = segment.buffered_chunks.reduce(0) { $0 + $1.count }

        if let cl_str = segment.media_header.content_length,
           let expected_bytes = Int(cl_str),
           expected_bytes > 0,
           loaded_bytes != expected_bytes {
            logger.warn(tag: tag, message: "Content length mismatch for segment \(segment.segment_number) (Header ID: \(header_id), key: \(segment.format_id_key), expected: \(expected_bytes), received: \(loaded_bytes)) — continuing with received data")
            // Continue processing — don't discard received data
        }

        guard var initialized_format = initialized_formats_map[segment.format_id_key] else { return }

        let media_type = get_media_type(initialized_format)

        // Gate: skip segments whose start time falls at or beyond the known stream duration.
        // AVFoundation's AVAssetResourceLoader does not honour edts/elst edit lists for fMP4
        // streams; suppressing the silent-tail fragments here is the only reliable cutoff.
        if segment.media_header.is_init_seg != true,
           duration_ms < .infinity,
           let startStr = segment.media_header.start_ms,
           let segStartMs = Double(startStr),
           segStartMs >= duration_ms {
            logger.debug(tag: tag, message: "Skipping \(media_type) segment \(segment.segment_number) (start \(segStartMs)ms ≥ duration \(duration_ms)ms — silent tail)")
            segment.buffered_chunks = []
            initialized_format.last_media_headers.append(segment.media_header)
            initialized_format.downloaded_segments[segment.segment_number] = segment
            initialized_formats_map[segment.format_id_key] = initialized_format
            partial_segment_queue.removeValue(forKey: header_id)
            return
        }

        for chunk in segment.buffered_chunks {
            if media_type == "audio" {
                audio_continuation?.yield(chunk)
            } else {
                video_continuation?.yield(chunk)
            }
        }

        logger.debug(tag: tag, message: "Received MediaEnd for \(media_type) segment \(segment.segment_number) (Header ID: \(header_id), key: \(segment.format_id_key))")

        segment.buffered_chunks = []
        initialized_format.last_media_headers.append(segment.media_header)
        initialized_format.downloaded_segments[segment.segment_number] = segment
        initialized_formats_map[segment.format_id_key] = initialized_format
        partial_segment_queue.removeValue(forKey: header_id)
    }

    // MARK: - Validation

    private func validate_and_correct_duration(format_initialization_metadata: FormatInitializationMetadata) {
        let duration_units = Int(format_initialization_metadata.duration_units ?? "0") ?? 0
        let duration_timescale = Int(format_initialization_metadata.duration_timescale ?? "0") ?? 0

        guard duration_timescale != 0 else {
            logger.warn(tag: tag, message: "Invalid timescale (0) in format initialization metadata")
            return
        }

        let expected_duration = Double(duration_units) / (Double(duration_timescale) / 1000.0)

        if duration_ms != expected_duration {
            duration_ms = expected_duration
            logger.debug(tag: tag, message: "Corrected stream duration to \(duration_ms)ms based on format initialization metadata")
            on_duration_updated_listeners.forEach { $0(expected_duration) }
        }
    }

    private func validate_downloaded_segments() {
        for (format_id_key, initialized_format) in initialized_formats_map {
            if format_id_key == format_to_discard {
                logger.debug(tag: tag, message: "Skipping validation for discarded format: \(format_id_key)")
                continue
            }

            let total_duration = get_total_downloaded_duration(initialized_format)
            let duration_units = Int(initialized_format.format_initialization_metadata.duration_units ?? "0") ?? 0
            let duration_timescale = Int(initialized_format.format_initialization_metadata.duration_timescale ?? "0") ?? 0
            let expected_duration = duration_timescale > 0 ? Double(duration_units) / (Double(duration_timescale) / 1000.0) : 0

            let duration_mismatch = abs(total_duration - expected_duration)
            if expected_duration > 0 && duration_mismatch > expected_duration * 0.01 {
                let duration_coverage = Int((total_duration / expected_duration) * 100)
                logger.warn(tag: tag, message: "Incomplete stream for format \(format_id_key): downloaded \(total_duration)ms (\(duration_coverage)%), expected \(expected_duration)ms")
            }

            let segments = Array(initialized_format.downloaded_segments).sorted { $0.key < $1.key }
            if segments.isEmpty { continue }

            let expected_segment_count = Int(initialized_format.format_initialization_metadata.end_segment_number ?? "0") ?? 0
            var missing_segments: [Int] = []

            for i in 0...expected_segment_count {
                if initialized_format.downloaded_segments[i] == nil {
                    missing_segments.append(i)
                }
            }

            let unique_segment_count = Set(segments.map { $0.key }).count
            let has_duplicates = unique_segment_count != segments.count

            if !missing_segments.isEmpty {
                let message = "Format \(format_id_key): Missing segments: [\(missing_segments.map(String.init).joined(separator: ", "))]. Expected range: 0-\(expected_segment_count)."
                logger.warn(tag: tag, message: message)
            } else {
                logger.debug(tag: tag, message: "Format \(format_id_key): All \(expected_segment_count) segments present (100% coverage)")
            }

            if has_duplicates {
                let message = "Format \(format_id_key): Found duplicate segment numbers (\(segments.count) segments but \(unique_segment_count) unique numbers)"
                logger.warn(tag: tag, message: message)
            }
        }
    }

    // MARK: - State Reset

    private func reset_state() {
        initialized_formats_map.removeAll()
        partial_segment_queue.removeAll()
        active_sabr_context_types.removeAll()
        sabr_contexts.removeAll()
        next_request_policy = nil
        main_format = nil
        request_number = 0
        cached_buffered_ranges = nil
        media_headers_processed = false
        stream_protection_status = nil
        format_to_discard = nil
        abort_task = nil
        progress_tracker = ProgressTracker(
            last_progress_time: Date(),
            last_downloaded_duration: 0,
            stall_count: 0
        )
    }

    // MARK: - Error Handling

    private func error_handler(error: NSError, notify_controllers: Bool = true) {
        reset_state()
        logger.error(tag: tag, message: "Stream error: \(error.localizedDescription)")
        if notify_controllers {
            _errored = true
            video_continuation?.finish(throwing: error)
            audio_continuation?.finish(throwing: error)
        }
    }
}
