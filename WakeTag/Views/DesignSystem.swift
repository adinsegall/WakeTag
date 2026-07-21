import SwiftUI

enum Design {
    static let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.08, green: 0.07, blue: 0.16), Color(red: 0.02, green: 0.02, blue: 0.05)],
        startPoint: .top, endPoint: .bottom)

    static let sunriseGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.48, blue: 0.29), Color(red: 0.98, green: 0.29, blue: 0.42)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Full-width call-to-action button.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Design.sunriseGradient.opacity(isDisabled ? 0.35 : 1))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(isDisabled)
    }
}

/// Seven tappable weekday circles.
struct WeekdayPicker: View {
    @Binding var selection: Set<Weekday>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Weekday.allCases) { day in
                let isOn = selection.contains(day)
                Button {
                    if isOn {
                        selection.remove(day)
                    } else {
                        selection.insert(day)
                    }
                } label: {
                    Text(day.letter)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(isOn ? AnyShapeStyle(Design.sunriseGradient) : AnyShapeStyle(.quaternary))
                        .foregroundStyle(isOn ? .white : .secondary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Square artwork thumbnail with a music-note placeholder.
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 52

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
    }
}
