//
//  Track.swift
//  RNTrackPlayer
//
//  Created by David Chavez on 12.08.17.
//  Copyright © 2017 David Chavez. All rights reserved.
//

import Foundation
import MediaPlayer
import AVFoundation
import SwiftAudioEx

class Track: AudioItem, TimePitching, AssetOptionsProviding, PendingSourceProviding {
    // nil = metadata-first ("pending") track: it sits in the queue and, when active, holds the
    // player in the loading state until updateSource() fills the URL in.
    private(set) var url: MediaURL?

    @objc var title: String?
    @objc var artist: String?

    var date: String?
    var desc: String?
    var genre: String?
    var duration: Double?
    var artworkURL: MediaURL?
    private(set) var headers: [String: Any]?
    var userAgent: String?
    let pitchAlgorithm: String?
    var isLiveStream: Bool?

    var album: String?
    var artwork: MPMediaItemArtwork?

    // SABR streaming params (YouTube server-adaptive bitrate)
    var isOpus: Bool?
    var isSabr: Bool?
    var sabrServerUrl: String?
    var sabrUstreamerConfig: String?
    var sabrFormats: [[String: Any]]?
    var poToken: String?

    private var originalObject: [String: Any] = [:]

    init?(dictionary: [String: Any]) {
        self.url = MediaURL(object: dictionary["url"])
        self.headers = dictionary["headers"] as? [String: Any]
        self.userAgent = dictionary["userAgent"] as? String
        self.pitchAlgorithm = dictionary["pitchAlgorithm"] as? String
        self.isOpus = dictionary["isOpus"] as? Bool
        self.isSabr = dictionary["isSabr"] as? Bool
        self.sabrServerUrl = dictionary["sabrServerUrl"] as? String
        self.sabrUstreamerConfig = dictionary["sabrUstreamerConfig"] as? String
        self.sabrFormats = dictionary["sabrFormats"] as? [[String: Any]]
        self.poToken = dictionary["poToken"] as? String

        updateMetadata(dictionary: dictionary);
    }


    // MARK: - Public Interface

    func toObject() -> [String: Any] {
        return originalObject
    }

    /// Fills in (or replaces) the playback source of the track. Used to complete a
    /// metadata-first track once its URL has been resolved.
    func updateSource(dictionary: [String: Any]) {
        if let newUrl = MediaURL(object: dictionary["url"]) {
            self.url = newUrl
        }
        if let headers = dictionary["headers"] as? [String: Any] { self.headers = headers }
        if let userAgent = dictionary["userAgent"] as? String { self.userAgent = userAgent }
        if let isOpus = dictionary["isOpus"] as? Bool { self.isOpus = isOpus }
        if let isSabr = dictionary["isSabr"] as? Bool { self.isSabr = isSabr }
        if let sabrServerUrl = dictionary["sabrServerUrl"] as? String { self.sabrServerUrl = sabrServerUrl }
        if let sabrUstreamerConfig = dictionary["sabrUstreamerConfig"] as? String { self.sabrUstreamerConfig = sabrUstreamerConfig }
        if let sabrFormats = dictionary["sabrFormats"] as? [[String: Any]] { self.sabrFormats = sabrFormats }
        if let poToken = dictionary["poToken"] as? String { self.poToken = poToken }
        updateMetadata(dictionary: dictionary)
    }

    func updateMetadata(dictionary: [String: Any]) {
        self.title = (dictionary["title"] as? String) ?? self.title
        self.artist = (dictionary["artist"] as? String) ?? self.artist
        self.date = dictionary["date"] as? String
        self.album = dictionary["album"] as? String
        self.genre = dictionary["genre"] as? String
        self.desc = dictionary["description"] as? String
        self.duration = dictionary["duration"] as? Double
        self.artworkURL = MediaURL(object: dictionary["artwork"])
        self.isLiveStream = dictionary["isLiveStream"] as? Bool

        self.originalObject = self.originalObject.merging(dictionary) { (_, new) in new }
    }

    // MARK: - PendingSourceProviding Protocol

    var isPendingSource: Bool {
        return url == nil
    }

    // MARK: - AudioItem Protocol

    func getSourceUrl() -> String {
        guard let url = url else { return "" }
        return url.isLocal ? url.value.path : url.value.absoluteString
    }

    func getArtist() -> String? {
        return artist
    }

    func getTitle() -> String? {
        return title
    }

    func getAlbumTitle() -> String? {
        return album
    }

    func getSourceType() -> SourceType {
        return (url?.isLocal ?? false) ? .file : .stream
    }

    func getArtwork(_ handler: @escaping (UIImage?) -> Void) {
        if let artworkURL = artworkURL?.value {
            if(self.artworkURL?.isLocal ?? false){
                let image = UIImage.init(contentsOfFile: artworkURL.path);
                handler(image);
            } else {
                URLSession.shared.dataTask(with: artworkURL, completionHandler: { (data, _, error) in
                    if let data = data, let artwork = UIImage(data: data), error == nil {
                        handler(artwork)
                    } else {
                        handler(nil)
                    }
                }).resume()
            }
        } else {
            handler(nil)
        }
    }

    func getDuration() -> Double? {
        return duration
    }

    // MARK: - TimePitching Protocol

    func getPitchAlgorithmType() -> AVAudioTimePitchAlgorithm {
        if let pitchAlgorithm = pitchAlgorithm {
            switch pitchAlgorithm {
            case PitchAlgorithm.linear.rawValue:
                return .varispeed
            case PitchAlgorithm.music.rawValue:
                return .spectral
            default: // voice
                return .timeDomain
            }
        }

        return .timeDomain
    }

    // MARK: - Authorizing Protocol

    func getAssetOptions() -> [String: Any] {
        var options: [String: Any] = [:]
        if let headers = headers {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        if #available(iOS 16, *) {
            if let userAgent = userAgent {
                // there is now an official, working way to set the user-agent for every request
                // https://developer.apple.com/documentation/avfoundation/avurlassethttpuseragentkey
                options[AVURLAssetHTTPUserAgentKey] = userAgent
            }
        }
        if isOpus == true {
            options["isOpus"] = true
        }
        // SABR params — only included when isSabr is true
        if isSabr == true, let sabrServerUrl = sabrServerUrl {
            options["isSabr"] = true
            options["sabrServerUrl"] = sabrServerUrl
            options["sabrUstreamerConfig"] = sabrUstreamerConfig ?? ""
            options["sabrFormats"] = sabrFormats ?? []
            options["poToken"] = poToken ?? ""
        }
        return options
    }

}
