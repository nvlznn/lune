import Observation
import SwiftUI
import UIKit

/// Downloads photos through signed URLs and caches them in memory. Sent photos never change, so the storage path is the cache key.
@Observable
final class PhotoLoader {
    private let api: APIClient
    @ObservationIgnored private let cache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(api: APIClient) {
        self.api = api
        cache.countLimit = 100
    }

    private func key(_ path: String, _ bucket: StorageBucket) -> NSString {
        "\(bucket.rawValue)/\(path)" as NSString
    }

    func cachedImage(for path: String, in bucket: StorageBucket = .entries) -> UIImage? {
        cache.object(forKey: key(path, bucket))
    }

    func image(for path: String, in bucket: StorageBucket = .entries) async -> UIImage? {
        if let cached = cachedImage(for: path, in: bucket) { return cached }
        let key = key(path, bucket)
        if let task = inFlight[key as String] { return await task.value }

        let task = Task<UIImage?, Never> {
            guard let data = try? await api.downloadImage(at: path, in: bucket) else { return nil }
            return await Task.detached { UIImage(data: data)?.preparingForDisplay() }.value
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Your own just-sent photo doesn't need to be downloaded again.
    func store(_ image: UIImage, for path: String, in bucket: StorageBucket = .entries) {
        cache.setObject(image, forKey: key(path, bucket))
    }
}

/// A photo loaded from Storage, with a system placeholder fill while loading.
struct RemotePhoto: View {
    let path: String
    var bucket: StorageBucket = .entries
    var contentMode: ContentMode = .fit
    /// Hands the loaded image to the parent, e.g. for sharing. The cache can evict it at any time.
    var onLoad: (UIImage) -> Void = { _ in }

    @Environment(PhotoLoader.self) private var loader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(contentMode == .fit ? 4 / 3 : 1, contentMode: contentMode)
                    .overlay { ProgressView() }
            }
        }
        .task(id: path) {
            image = loader.cachedImage(for: path, in: bucket)
            if image == nil { image = await loader.image(for: path, in: bucket) }
            if let image { onLoad(image) }
        }
    }
}
