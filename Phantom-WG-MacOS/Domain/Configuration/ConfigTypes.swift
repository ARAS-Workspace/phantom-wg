import Foundation
import Network

// MARK: - WireGuard Key

/// 32-byte Curve25519 key encoded as base64 (44 characters including padding).
/// Used for private, public, and preshared keys across interface and peer sections.
struct WireGuardKey: Equatable, Hashable, Codable {

    let base64: String

    enum ParseError: Error, Equatable {
        case notBase64
        case wrongByteCount(Int)
    }

    init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else {
            throw ParseError.notBase64
        }
        guard data.count == 32 else {
            throw ParseError.wrongByteCount(data.count)
        }
        self.base64 = trimmed
    }

    var textual: String { base64 }

    // MARK: Codable — single string representation

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try self.init(parsing: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64)
    }
}

// MARK: - Address With Prefix

/// IPv4 or IPv6 address paired with a CIDR prefix length.
/// Used for Interface `Address` entries and Peer `AllowedIPs` entries.
struct AddressWithPrefix: Equatable, Hashable, Codable {

    enum Family: Equatable, Hashable {
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
    }

    let family: Family
    let prefixLength: UInt8

    enum ParseError: Error, Equatable {
        case missingSlash
        case invalidPrefix(String)
        case invalidAddress(String)
        case prefixOutOfRange(family: String, prefix: UInt8, max: UInt8)
    }

    init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slashIndex = trimmed.firstIndex(of: "/") else {
            throw ParseError.missingSlash
        }
        let addrPart = String(trimmed[..<slashIndex])
        let prefixPart = String(trimmed[trimmed.index(after: slashIndex)...])

        guard let prefix = UInt8(prefixPart) else {
            throw ParseError.invalidPrefix(prefixPart)
        }

        if let v4 = IPv4Address(addrPart) {
            guard prefix <= 32 else {
                throw ParseError.prefixOutOfRange(family: "IPv4", prefix: prefix, max: 32)
            }
            self.family = .ipv4(v4)
            self.prefixLength = prefix
        } else if let v6 = IPv6Address(addrPart) {
            guard prefix <= 128 else {
                throw ParseError.prefixOutOfRange(family: "IPv6", prefix: prefix, max: 128)
            }
            self.family = .ipv6(v6)
            self.prefixLength = prefix
        } else {
            throw ParseError.invalidAddress(addrPart)
        }
    }

    var textual: String {
        switch family {
        case .ipv4(let v4): return "\(v4)/\(prefixLength)"
        case .ipv6(let v6): return "\(v6)/\(prefixLength)"
        }
    }

    // MARK: Codable — single string representation

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try self.init(parsing: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(textual)
    }
}

// MARK: - IP Address Entry

/// Single IPv4 or IPv6 address without a prefix — used for DNS server entries.
struct IPAddressEntry: Equatable, Hashable, Codable {

    enum Family: Equatable, Hashable {
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
    }

    let family: Family

    enum ParseError: Error, Equatable {
        case invalid(String)
    }

    init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v4 = IPv4Address(trimmed) {
            self.family = .ipv4(v4)
        } else if let v6 = IPv6Address(trimmed) {
            self.family = .ipv6(v6)
        } else {
            throw ParseError.invalid(trimmed)
        }
    }

    var textual: String {
        switch family {
        case .ipv4(let v4): return "\(v4)"
        case .ipv6(let v6): return "\(v6)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try self.init(parsing: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(textual)
    }
}

// MARK: - IP Endpoint

/// Host + port pair for WireGuard peer endpoints.
/// Host may be an IPv4 address, IPv6 address (bracketed in textual form),
/// or a DNS hostname — hostname resolution is deferred to connect time.
struct IPEndpoint: Equatable, Hashable, Codable {

    enum Host: Equatable, Hashable {
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
        case hostname(String)
    }

    let host: Host
    let port: UInt16

    enum ParseError: Error, Equatable {
        case missingPort
        case invalidPort(String)
        case portOutOfRange(Int)
        case invalidHost(String)
    }

    init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Bracketed IPv6 literal: [addr]:port
        if trimmed.hasPrefix("[") {
            guard let closingBracket = trimmed.firstIndex(of: "]") else {
                throw ParseError.invalidHost(trimmed)
            }
            let hostPart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            let afterBracket = trimmed.index(after: closingBracket)
            guard afterBracket < trimmed.endIndex, trimmed[afterBracket] == ":" else {
                throw ParseError.missingPort
            }
            let portPart = String(trimmed[trimmed.index(after: afterBracket)...])
            guard let v6 = IPv6Address(hostPart) else {
                throw ParseError.invalidHost(hostPart)
            }
            self.host = .ipv6(v6)
            self.port = try Self.parsePort(portPart)
            return
        }

        // Non-bracketed: rightmost ":" separates host from port
        guard let colonIndex = trimmed.lastIndex(of: ":") else {
            throw ParseError.missingPort
        }
        let hostPart = String(trimmed[..<colonIndex])
        let portPart = String(trimmed[trimmed.index(after: colonIndex)...])

        self.port = try Self.parsePort(portPart)

        if let v4 = IPv4Address(hostPart) {
            self.host = .ipv4(v4)
        } else if IPEndpoint.isValidHostname(hostPart) {
            self.host = .hostname(hostPart)
        } else {
            throw ParseError.invalidHost(hostPart)
        }
    }

    private static func parsePort(_ text: String) throws -> UInt16 {
        guard let value = Int(text) else {
            throw ParseError.invalidPort(text)
        }
        guard value > 0, value <= 65535 else {
            throw ParseError.portOutOfRange(value)
        }
        return UInt16(value)
    }

    /// RFC 1123 hostname SHAPE: labels 1–63 chars, total <= 253,
    /// hyphens never at label boundaries, dot-separated. The character
    /// classes are deliberately Unicode-wide (`isLetter`/`isNumber`)
    /// and the lengths count Characters, not octets — a non-ASCII
    /// hostname passes here and surfaces its failure at connect-time
    /// resolution instead of as a field error. Tightening to ASCII is
    /// a cross-repo decision (iOS parser parity).
    private static func isValidHostname(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 253 else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for ch in label {
                guard ch.isLetter || ch.isNumber || ch == "-" else { return false }
            }
        }
        return true
    }

    var textual: String {
        switch host {
        case .ipv4(let v4):       return "\(v4):\(port)"
        case .ipv6(let v6):       return "[\(v6)]:\(port)"
        case .hostname(let name): return "\(name):\(port)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try self.init(parsing: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(textual)
    }
}

// MARK: - Wstunnel URL

/// `wss://` or `ws://` URL pointing at the wstunnel server.
struct WstunnelURL: Equatable, Hashable, Codable {

    let url: URL

    enum ParseError: Error, Equatable {
        case notAURL
        case invalidScheme(String?)
        case missingHost
    }

    init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw ParseError.notAURL
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            throw ParseError.invalidScheme(url.scheme)
        }
        guard url.host != nil else {
            throw ParseError.missingHost
        }
        self.url = url
    }

    var textual: String { url.absoluteString }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try self.init(parsing: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(textual)
    }
}
