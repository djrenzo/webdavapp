import Foundation

actor PosterCache {
    static let shared = PosterCache()
    private let cache: URLCache
    private let session: URLSession

    init() {
        let cache = URLCache(
            memoryCapacity: 24 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            diskPath: "TorBoxPosters"
        )
        self.cache = cache
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func clear() {
        cache.removeAllCachedResponses()
    }

    func data(for url: URL) async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil else {
            throw URLError(.badURL)
        }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        if let cached = cache.cachedResponse(for: request) { return cached.data }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              response.mimeType?.hasPrefix("image/") == true else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        return data
    }
}
