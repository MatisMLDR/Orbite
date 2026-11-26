import SwiftUI

/// The Mac: a white disc with a laptop, haloed in blue while data flows.
struct HomePin: View {
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.download.opacity(active ? 0.22 : 0))
                .frame(width: 60, height: 60)
            Circle()
                .fill(.white)
                .frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.28), radius: 7, y: 2.5)
            Circle()
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                .frame(width: 46, height: 46)
            Image(systemName: "laptopcomputer")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color(white: 0.13))
        }
        .frame(width: 64, height: 64)
        .contentShape(Circle())
        .animation(.easeInOut(duration: 0.6), value: active)
        .help("This Mac")
    }
}

/// White capsule with the city name, like Plans' labels.
struct CityPill: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let extra: Int
    let active: Bool
    let selected: Bool
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 5) {
            if active {
                Circle()
                    .fill(selected ? .white : Theme.download)
                    .frame(width: 6, height: 6)
                    .shadow(color: Theme.download.opacity(0.6), radius: 2.5)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background((selected ? Color.white : Color.primary).opacity(0.12), in: Capsule())
            }
        }
        .foregroundStyle(selected ? .white : Theme.pillText(scheme))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(selected ? Color.accentColor : Theme.pillBackground(scheme), in: Capsule())
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.2), radius: 4, y: 1.5)
        .opacity(dimmed && !selected ? 0.45 : 1)
        .scaleEffect(selected ? 1.08 : 1)
        .animation(Theme.selection, value: selected)
        .animation(.easeInOut(duration: 0.3), value: dimmed)
        .contentShape(Capsule())
    }
}

/// A place whose label would overlap: grey core in a white ring, blue when data flows.
struct SiteDot: View {
    let active: Bool
    let dimmed: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            Circle()
                .fill(active ? Theme.download : Color(white: 0.68))
                .frame(width: 9, height: 9)
        }
        .frame(width: 26, height: 26)
        .opacity(dimmed ? 0.4 : 1)
        .contentShape(Circle())
        .drawingGroup()
    }
}

/// An expanding ring that fades out, repeated.
struct PulseRing: View {
    let color: Color
    let size: CGFloat
    var duration: Double = 1.6
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.7), lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.9 : 1)
            .opacity(expanded ? 0 : 0.85)
            .onAppear {
                withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}
