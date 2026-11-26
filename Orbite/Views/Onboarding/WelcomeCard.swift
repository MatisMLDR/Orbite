import AppKit
import SwiftUI

/// First launch: three steps over the blurred map. Only the GeoIP database is required.
struct WelcomeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    Text("Welcome to Orbite")
                        .font(.system(size: 26, weight: .bold))
                    Text("Every connection your Mac makes, live, on the world map.\nEverything stays on this Mac.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    geoStep
                    locationStep
                    helperStep
                }

                Button {
                    model.finishOnboarding()
                } label: {
                    Text(model.geo.isReady ? "Get Started" : "Continue Without the Map")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
            }
            .padding(30)
            .frame(width: 500)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
            .shadow(color: .black.opacity(0.15), radius: 30, y: 12)
        }
    }

    private var geoStep: some View {
        StepRow(number: 1, symbol: "globe.europe.africa.fill", tint: Theme.download,
                title: "Geolocation database",
                detail: "DB-IP Lite, 65 MB, updated every month. It places servers on the map without sending anything.") {
            switch model.geo.phase {
            case .ready:
                Done()
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 80)
            case .failed:
                Button("Try Again") { Task { await model.geo.download() } }
            case .missing:
                Button("Download") { Task { await model.geo.download() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var locationStep: some View {
        StepRow(number: 2, symbol: "location.fill", tint: Theme.live,
                title: "Mac's location",
                detail: "To start from the right place and read the Wi-Fi name. Otherwise, Orbite uses your time zone's city.") {
            if model.home.isAuthorized {
                Done()
            } else {
                Button("Allow") { model.home.requestAccess() }
            }
        }
    }

    private var helperStep: some View {
        StepRow(number: 3, symbol: "text.magnifyingglass", tint: Theme.upload,
                title: "Real domain names",
                detail: "A small system service reads DNS answers to show youtube.com instead of “Google”. Needs an admin approval.") {
            switch model.helper.state {
            case .running:
                Done()
            case .starting:
                ProgressView().controlSize(.small)
            case .needsApproval:
                Button("Open Settings") { model.helper.openLoginItems() }
            case .notInstalled, .failed:
                Button("Turn On") { model.helper.enable() }
            }
        }
    }
}

private struct StepRow<Accessory: View>: View {
    let number: Int
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            ZStack {
                Circle().fill(tint.gradient)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Done: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(Theme.live)
            .symbolEffect(.bounce, value: true)
    }
}
