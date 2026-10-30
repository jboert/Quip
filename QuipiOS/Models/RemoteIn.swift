import Foundation

/// Q-88 US-010: open this Mac in a remote-desktop app. Each preset is an app
/// and its documented link; nothing is hard-wired, and Custom takes any link.
enum RemoteInPreset: String, CaseIterable, Codable, Identifiable {
    case vnc, berriscope, screens, jump, realvnc, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vnc: return "Any VNC app"
        case .berriscope: return "Berriscope"
        case .screens: return "Screens"
        case .jump: return "Jump Desktop"
        case .realvnc: return "RealVNC Viewer"
        case .custom: return "Custom"
        }
    }

    /// The link, with `{host}` and `{name}`; nil for Custom.
    var template: String? {
        switch self {
        // RFC 7869. Screens documents vnc:// for a Mac it has not saved.
        case .vnc: return "vnc://{host}"
        // Q-88 US-012 (Berriscope repo): opens a saved host by its name.
        case .berriscope: return "berriscope://open?saved={name}"
        // https://help.edovia.com/en/screens-5/features/url-schemes
        // "screens://[ip address|hostname|name]"
        case .screens: return "screens://{host}"
        // https://support.jumpdesktop.com/hc/en-us/articles/216423723
        // host required; protocol rdp|fluid|vnc, default rdp, so name vnc.
        case .jump: return "jump://?host={host}&protocol=vnc"
        // https://help.realvnc.com/hc/en-us/articles/6449870411037
        // com.realvnc.vncviewer.connect://<hostname|ip>[:<port>]
        case .realvnc: return "com.realvnc.vncviewer.connect://{host}"
        case .custom: return nil
        }
    }

    var help: String? {
        switch self {
        case .vnc: return "Opens whichever VNC app you have."
        case .berriscope: return "Opens Berriscope; connecting by name needs Berriscope 2026-11+."
        default: return nil
        }
    }

    /// Every preset's scheme, for `LSApplicationQueriesSchemes` (project.yml).
    static var querySchemes: [String] {
        allCases.compactMap { $0.template.flatMap(RemoteInURLBuilder.scheme(of:)) }
    }
}

/// One Mac's Remote-in setting.
struct RemoteInSettings: Codable, Equatable {
    var preset: RemoteInPreset = .vnc
    /// nil: this Mac's Tailscale host.
    var host: String?
    /// nil: the name the Mac was paired under.
    var name: String?
    var customTemplate: String = ""

    var template: String { preset.template ?? customTemplate }

    init(preset: RemoteInPreset = .vnc, host: String? = nil, name: String? = nil, customTemplate: String = "") {
        self.preset = preset
        self.host = host
        self.name = name
        self.customTemplate = customTemplate
    }

    /// Tolerant: a field this build does not know (a preset from a newer
    /// build) falls back to the default rather than losing the whole row.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? c.decode(RemoteInPreset.self, forKey: .preset)) ?? .vnc
        host = try? c.decodeIfPresent(String.self, forKey: .host)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        customTemplate = (try? c.decodeIfPresent(String.self, forKey: .customTemplate)) ?? ""
    }
}

/// Settings per backend id, as one JSON string in UserDefaults so the prefs
/// backup carries them (`PreferencesSnapshot.remoteInJSON`).
enum RemoteInStore {
    static let key = "remoteIn.v1"

    static func all(in d: UserDefaults = .standard) -> [String: RemoteInSettings] {
        decode(d.string(forKey: key)) ?? [:]
    }

    static func settings(for backendID: String, in d: UserDefaults = .standard) -> RemoteInSettings {
        all(in: d)[backendID] ?? RemoteInSettings()
    }

    static func save(_ settings: RemoteInSettings, for backendID: String, in d: UserDefaults = .standard) {
        var map = all(in: d)
        map[backendID] = settings
        guard let data = try? JSONEncoder().encode(map), let s = String(data: data, encoding: .utf8) else { return }
        d.set(s, forKey: key)
    }

    static func decode(_ json: String?) -> [String: RemoteInSettings]? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: RemoteInSettings].self, from: data)
    }
}

/// Fills a template into a link. Pure, so every preset is tested.
enum RemoteInURLBuilder {
    enum Failure: Error, Equatable {
        /// The link needs a host (or a name) and there is none.
        case noHost
        case unknownPlaceholder(String)
        case badURL
    }

    static let placeholders: Set<String> = ["host", "name"]

    /// `{x}` names in the template, in order.
    static func placeholders(in template: String) -> [String] {
        var out: [String] = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "}") else { break }
            out.append(String(after[..<close]))
            rest = after[after.index(after: close)...]
        }
        return out
    }

    /// The template's own faults, before any host is known: an unknown
    /// placeholder, or no link even with sample values. Drives Save.
    static func check(_ template: String) -> Failure? {
        switch build(template, host: "host", name: "name") {
        case .failure(let f): return f
        case .success: return nil
        }
    }

    static func build(_ template: String, host: String, name: String) -> Result<URL, Failure> {
        let used = placeholders(in: template)
        if let unknown = used.first(where: { !placeholders.contains($0) }) {
            return .failure(.unknownPlaceholder(unknown))
        }
        let host = host.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        if (used.contains("host") && host.isEmpty) || (used.contains("name") && name.isEmpty) {
            return .failure(.noHost)
        }
        let filled = template
            .replacingOccurrences(of: "{host}", with: encode(host))
            .replacingOccurrences(of: "{name}", with: encode(name))
        guard scheme(of: filled) != nil, let url = URL(string: filled) else { return .failure(.badURL) }
        return .success(url)
    }

    /// The scheme before `:`, lowercased, or nil when there is none.
    static func scheme(of link: String) -> String? {
        guard let colon = link.firstIndex(of: ":") else { return nil }
        let s = link[..<colon]
        guard let first = s.first, first.isLetter,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return s.lowercased()
    }

    /// RFC 3986 unreserved characters pass; everything else is escaped, so a
    /// name with spaces or `&` cannot break the link.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// This Mac's Tailscale host: a MagicDNS name if it has one, else a
    /// 100.64/10 address; nil when it has neither.
    @MainActor
    static func defaultHost(urls: [String]) -> String? {
        let hosts = urls
            .filter { BackendConnectionManager.urlPriority($0) == BackendConnectionManager.tailscalePriority }
            .compactMap { URL(string: $0)?.host }
        return hosts.first { $0.lowercased().hasSuffix(".ts.net") } ?? hosts.first
    }
}
