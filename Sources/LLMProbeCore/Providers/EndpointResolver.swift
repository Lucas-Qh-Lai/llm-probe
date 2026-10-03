import Foundation

/// An endpoint with its credential resolved and headers assembled.
///
/// This type holds a live secret, so it is never encoded, printed or persisted.
public struct ResolvedEndpoint: Sendable {
    public var endpoint: ProbeEndpoint
    public var baseURL: URL
    public var headers: [String: String]
    public var queryItems: [URLQueryItem]
    public var secret: String?

    public var wireAPI: WireAPI { endpoint.wireAPI }
    public var model: String { endpoint.model }
}

public enum EndpointResolverError: Error, Sendable {
    case invalidBaseURL(String)
    case missingCredential(String)

    public var displayMessage: String {
        switch self {
        case .invalidBaseURL(let value): return "Base URL is not a valid absolute URL: \(value)"
        case .missingCredential(let detail): return "Missing credential: \(detail)"
        }
    }
}

/// Turns a stored `ProbeEndpoint` into a request-ready `ResolvedEndpoint`,
/// applying each vendor's authentication convention.
public enum EndpointResolver {
    public static func resolve(_ endpoint: ProbeEndpoint) throws -> ResolvedEndpoint {
        guard let base = URL(string: endpoint.baseURL),
              let scheme = base.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw EndpointResolverError.invalidBaseURL(endpoint.baseURL)
        }

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "LLMProbe/\(LLMProbeVersion.short)",
        ]
        for (key, value) in endpoint.extraHeaders { headers[key] = value }
        for (key, value) in endpoint.auth.extraHeaders { headers[key] = value }

        var queryItems: [URLQueryItem] = endpoint.queryParams
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        let secret = SecretResolver.resolve(endpoint.auth.secret)

        switch endpoint.auth.style {
        case .none:
            break
        case .bearer:
            if let secret { headers["Authorization"] = "Bearer \(secret)" }
        case .xApiKey:
            if let secret { headers[endpoint.auth.headerName ?? "x-api-key"] = secret }
        case .header:
            if let secret, let name = endpoint.auth.headerName, !name.isEmpty { headers[name] = secret }
        case .query:
            if let secret, let name = endpoint.auth.queryName, !name.isEmpty {
                queryItems.append(URLQueryItem(name: name, value: secret))
            }
        }

        // Vendor conventions that must always hold, even when a user pasted a
        // minimal config.
        applyVendorDefaults(endpoint: endpoint, headers: &headers, queryItems: &queryItems, secret: secret)

        return ResolvedEndpoint(
            endpoint: endpoint,
            baseURL: base,
            headers: headers,
            queryItems: queryItems,
            secret: secret
        )
    }

    private static func applyVendorDefaults(
        endpoint: ProbeEndpoint,
        headers: inout [String: String],
        queryItems: inout [URLQueryItem],
        secret: String?
    ) {
        switch endpoint.wireAPI {
        case .anthropicMessages:
            if headers["anthropic-version"] == nil { headers["anthropic-version"] = "2023-06-01" }
            if headers["x-api-key"] == nil, headers["Authorization"] == nil, let secret {
                headers["x-api-key"] = secret
            }
        case .googleGemini:
            if headers["x-goog-api-key"] == nil, !queryItems.contains(where: { $0.name == "key" }), let secret {
                // Header auth keeps the key out of URLs, which is safer for logs.
                headers["x-goog-api-key"] = secret
            }
        default:
            break
        }
    }
}

public enum LLMProbeVersion {
    public static let short = "0.1.0"
}
