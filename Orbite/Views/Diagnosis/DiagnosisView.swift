import SwiftUI

/// « Pourquoi c'est lent ? »: measures for a few seconds, then explains in plain words.
struct DiagnosisView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let runner = model.diagnosis
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SymbolIcon(symbol: "stethoscope", size: 40, colors: [Color.teal.opacity(0.85), .teal])
                VStack(alignment: .leading, spacing: 2) {
                    Text("Why is it slow?").font(.system(size: 20, weight: .bold))
                    Text(model.network.currentNetwork?.name ?? String(localized: "Current network"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch runner.state {
                    case .idle, .running:
                        VStack(spacing: 14) {
                            ProgressView(value: { if case .running(let value) = runner.state { value } else { 0 } }())
                                .frame(width: 260)
                            Text("Orbite is measuring your router, the internet and what goes through right now…")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    case .done(let result):
                        DiagnosisFindings(result: result) { target in
                            open(target)
                            dismiss()
                        }
                    }

                    if !model.network.wifiHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Wi-Fi signal, last hour")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            SignalChart(samples: model.network.wifiHistory.filter { $0.date > Date().addingTimeInterval(-3600) })
                                .frame(height: 70)
                        }
                    }

                    let apps = model.store.liveApps(limit: 4)
                    if !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The hungriest right now")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(apps) { app in
                                HStack(spacing: 8) {
                                    AppIconView(identity: app.identity, size: 18)
                                    Text(app.identity.name).font(.system(size: 12.5, weight: .medium))
                                    Spacer()
                                    RatePair(rate: app.rate)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 10) {
                Text("Measured with 10 pings to your router\(model.network.router.map { " (\($0))" } ?? "") and to \(DiagnosisRunner.probe) (Cloudflare). Nothing else leaves the Mac.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Run Again") { Task { await model.diagnosis.run(model: model) } }
                    .disabled(runner.isRunning)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 620)
        .scrollIndicators(.never)
        .task {
            if !runner.isRunning, runner.result.map({ Date().timeIntervalSince($0.date) > 30 }) ?? true {
                await runner.run(model: model)
            }
        }
    }

    private func open(_ target: DiagnosisFinding.Target) {
        withAnimation(Theme.selection) {
            switch target {
            case .app(let id): model.ui.selection = .app(id)
            case .site(let id): model.ui.selection = .site(id)
            }
        }
        model.store.window = TimeWindow(span: model.store.window.span, end: nil)
    }
}

/// The verdict card and the other findings; a finding about an app or a place can be opened.
struct DiagnosisFindings: View {
    let result: DiagnosisResult
    var compact = false
    let open: (DiagnosisFinding.Target) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            ForEach(Array(result.findings.prefix(compact ? 2 : 8).enumerated()), id: \.element.id) { index, finding in
                FindingRow(finding: finding, headline: index == 0, compact: compact, open: open)
            }
        }
    }
}

private struct FindingRow: View {
    let finding: DiagnosisFinding
    let headline: Bool
    let compact: Bool
    let open: (DiagnosisFinding.Target) -> Void

    var body: some View {
        let color = Self.color(finding.severity)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.symbol)
                .font(.system(size: headline && !compact ? 20 : 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: headline && !compact ? 28 : 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.system(size: headline && !compact ? 15 : 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !compact || headline {
                    Text(finding.detail)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 3 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let target = finding.target, !compact {
                    Button("Show") { open(target) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(headline && !compact ? 14 : 0)
        .background(headline && !compact ? color.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func color(_ severity: DiagnosisFinding.Severity) -> Color {
        switch severity {
        case .good: Theme.live
        case .info: Theme.download
        case .warning: .orange
        case .problem: .red
        }
    }
}

/// RSSI over time, with the « weak » line at -75 dBm.
private struct SignalChart: View {
    let samples: [NetworkInfo.WiFiSample]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, let first = samples.first?.date, let last = samples.last?.date else { return }
            let span = max(1, last.timeIntervalSince(first))
            func y(_ rssi: Int) -> CGFloat { size.height * (1 - CGFloat(min(max(rssi, -95), -30) + 95) / 65) }
            var weak = Path()
            weak.move(to: CGPoint(x: 0, y: y(Diagnosis.weakSignal)))
            weak.addLine(to: CGPoint(x: size.width, y: y(Diagnosis.weakSignal)))
            context.stroke(weak, with: .color(.orange.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var line = Path()
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(x: size.width * sample.date.timeIntervalSince(first) / span, y: y(sample.rssi))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(Theme.download), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
        }
        .background(Theme.sectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let last = samples.last {
                Text("\(last.rssi) dBm")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
    }
}
