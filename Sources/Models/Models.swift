import Foundation

struct DeviceInfo: Codable, Identifiable, Hashable {
    let identifier: String
    let name: String
    let address: String
    let model: String?
    let services: [String]
    let isPaired: Bool

    var id: String { identifier }

    enum CodingKeys: String, CodingKey {
        case identifier, name, address, model, services
        case isPaired = "is_paired"
    }
}

struct PlayingState: Codable, Equatable {
    var deviceState: String?
    var mediaType: String?
    var title: String?
    var artist: String?
    var album: String?
    var app: String?
    var position: Int?
    var totalTime: Int?
    var volume: Double?
    var artworkURL: String?

    enum CodingKeys: String, CodingKey {
        case title, artist, album, app, position, volume
        case deviceState = "device_state"
        case mediaType = "media_type"
        case totalTime = "total_time"
        case artworkURL = "artwork_url"
    }
}

struct KeyboardEvent: Codable, Equatable {
    let focused: Bool
    let focusState: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case focused, text
        case focusState = "focus_state"
    }
}

struct StatusResponse: Codable {
    let connected: Bool
    let identifier: String?
    let supportedCommands: [String]

    enum CodingKeys: String, CodingKey {
        case connected, identifier
        case supportedCommands = "supported_commands"
    }
}

struct PairStartResponse: Codable {
    let sessionId: String?
    let identifier: String?
    let name: String?
    let protocolName: String?
    let needsPin: Bool?
    let completed: [String]?
    let failed: [PairFailure]?
    let remaining: [String]?
    let done: Bool?
    let pairedProtocols: [String]?

    enum CodingKeys: String, CodingKey {
        case identifier, name, completed, failed, remaining, done
        case sessionId = "session_id"
        case protocolName = "protocol"
        case needsPin = "needs_pin"
        case pairedProtocols = "paired_protocols"
    }
}

struct PairFailure: Codable, Equatable {
    let `protocol`: String
    let error: String
}

struct SavedDeviceEntry: Codable {
    let name: String
    let credentials: [String: String]
}
