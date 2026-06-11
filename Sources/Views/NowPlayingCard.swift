import SwiftUI

struct NowPlayingCard: View {
    @EnvironmentObject private var client: BackendClient

    private var artworkURL: URL? {
        let base = client.backendURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = (client.playing.title ?? "") + (client.playing.artist ?? "")
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "\(base)/api/artwork?ts=\(encoded)")
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(client.playing.title ?? client.playing.app ?? "Nothing playing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                let subline = [client.playing.artist, client.playing.album].compactMap { $0 }.joined(separator: " — ")
                if !subline.isEmpty {
                    Text(subline)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
                if let app = client.playing.app, !app.isEmpty {
                    Text(app.uppercased())
                        .font(.system(size: 10))
                        .tracking(0.6)
                        .foregroundColor(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = artworkURL, client.playing.title != nil || client.playing.artist != nil {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: artworkPlaceholder
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [Theme.surface2, Theme.surface],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 50, height: 50)
    }
}
