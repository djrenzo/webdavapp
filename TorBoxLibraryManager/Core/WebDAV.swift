import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

struct WebDAVCredentials: Sendable {
    /// Base URL without trailing '/', e.g. https://webdav.torbox.app
    let baseURL: String
    let username: String
    let password: String
}

struct WebDAVItem: Sendable, Equatable {
    let name: String
    /// scheme://host + the href path as listed (percent-encoded).
    let fullURL: String
    /// The href path as listed (percent-encoded).
    let path: String
    let isCollection: Bool
    let size: Int64

    var decodedPath: String { URLText.unquote(path) }
}

/// Port of torbox_webdav (propfind / parse_propfind / encode_webdav_url / build_authed_url).
enum WebDAV {
    static let defaultBaseURL = "https://webdav.torbox.app"

    private static let body = """
    <?xml version="1.0" encoding="utf-8"?>
    <propfind xmlns="DAV:">
      <prop>
        <resourcetype/>
        <getcontentlength/>
        <getlastmodified/>
        <displayname/>
        <getcontenttype/>
      </prop>
    </propfind>
    """

    static func normalizedBaseURL(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailing("/")
    }

    /// Like `encode_webdav_url`: percent-encode the (decoded) path of a URL with the addon's
    /// safe set. Unlike the addon, '%', '?' and '#' in names are encoded too, because the
    /// paths given here are always decoded.
    static func encode(_ url: String) -> String {
        let safe = "/:@!$&'()*+,;="
        guard let schemeEnd = url.range(of: "://") else { return URLText.quote(url, safe: safe) }
        let rest = url[schemeEnd.upperBound...]
        let pathStart = rest.firstIndex(of: "/") ?? rest.endIndex
        return String(url[..<pathStart]) + URLText.quote(String(rest[pathStart...]), safe: safe)
    }

    static func authorization(_ credentials: WebDAVCredentials) -> String {
        let token = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    /// PROPFIND `Depth: 1` on a decoded path ("/" or "/Folder/").
    static func propfind(_ credentials: WebDAVCredentials, path: String) async throws -> [WebDAVItem] {
        let target = encode(credentials.baseURL + path)
        guard let url = URL(string: target) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.httpBody = Data(body.utf8)
        request.setValue(authorization(credentials), forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("TorBoxLibrary-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusError(status: response.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        }
        return try parse(data, baseURL: credentials.baseURL, currentPath: path)
    }

    /// `parse_propfind`.
    static func parse(_ data: Data, baseURL: String, currentPath: String) throws -> [WebDAVItem] {
        let delegate = PropfindParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.coderReadCorrupt)
        }
        let current = URLText.unquote(currentPath).trimmingTrailing("/")
        let origin = URLText.origin(of: baseURL)
        var items: [WebDAVItem] = []
        for response in delegate.responses {
            let href = response.href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else { continue }
            let path = URLText.path(of: href)
            guard !path.isEmpty else { continue }
            if URLText.unquote(path).trimmingTrailing("/") == current { continue }
            let displayName = response.displayName.isEmpty ? nil : response.displayName
            let lastSegment = path.trimmingTrailing("/").split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let name = displayName ?? URLText.unquote(lastSegment)
            guard !name.isEmpty else { continue }
            let size = Int64(response.contentLength.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            items.append(WebDAVItem(
                name: name, fullURL: origin + path, path: path,
                isCollection: response.isCollection, size: size
            ))
        }
        return items
    }

    /// `build_authed_url`: the WebDAV URL with `user:pass@` (both percent-encoded).
    static func authedURL(_ url: String, username: String, password: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return url }
        let scheme = url[..<schemeEnd.lowerBound]
        let rest = url[schemeEnd.upperBound...]
        let hostEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = rest[..<hostEnd]
        guard !host.isEmpty else { return url }
        let user = URLText.quote(username, safe: "")
        let pass = URLText.quote(password, safe: "")
        return "\(scheme)://\(user):\(pass)@\(host)\(rest[hostEnd...])"
    }

    /// Root folders of an account (`root_folders`): collections under / not starting with '.'.
    static func rootFolders(_ credentials: WebDAVCredentials) async throws -> [WebDAVItem] {
        try await propfind(credentials, path: "/").filter { $0.isCollection && !$0.name.hasPrefix(".") }
    }

    /// Decoded folder path ending with '/' (`_folder_path`).
    static func folderPath(_ item: WebDAVItem) -> String {
        let path = item.decodedPath
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// Every listed video under a folder, recursively (`_walk`), and whether every
    /// subfolder could be listed.
    static func walk(_ credentials: WebDAVCredentials, path: String) async -> (files: [WebDAVItem], complete: Bool) {
        if Task.isCancelled { return ([], false) }
        let items: [WebDAVItem]
        do {
            items = try await propfind(credentials, path: path)
        } catch {
            AppLog.write("PROPFIND \(path) failed: \(error.localizedDescription)")
            return ([], false)
        }
        var files: [WebDAVItem] = []
        var complete = true
        for item in items {
            if item.isCollection {
                let child = folderPath(item)
                let result = await walk(credentials, path: child)
                files += result.files
                complete = complete && result.complete
            } else if Media.isListedVideo(item.name) {
                files.append(item)
            }
        }
        return (files, complete)
    }
}

private final class PropfindParser: NSObject, XMLParserDelegate {
    struct Response {
        var href = ""
        var displayName = ""
        var contentLength = ""
        var isCollection = false
    }

    var responses: [Response] = []
    private var current: Response?
    private var inResourceType = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        text = ""
        switch name {
        case "response": current = Response()
        case "resourcetype": inResourceType = true
        case "collection": if inResourceType { current?.isCollection = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        switch name {
        case "href":
            if current?.href.isEmpty == true { current?.href = text }
        case "displayname":
            current?.displayName = text
        case "getcontentlength":
            current?.contentLength = text
        case "resourcetype":
            inResourceType = false
        case "response":
            if let current { responses.append(current) }
            current = nil
        default:
            break
        }
        text = ""
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }
}
