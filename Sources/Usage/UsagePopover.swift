import SwiftUI
import UsageCore

extension Provider {
    var tint: Color {
        switch self {
        case .anthropic: Color(red: 0.79, green: 0.49, blue: 0.36)
        case .openAI: Color(red: 0.23, green: 0.64, blue: 0.51)
        case .moonshot: Color(red: 0.40, green: 0.51, blue: 0.92)
        case .deepSeek: Color(red: 0.30, green: 0.42, blue: 1.0)
        case .openCode: Color(red: 0.61, green: 0.48, blue: 0.85)
        case .githubCopilot: Color(red: 0.48, green: 0.55, blue: 0.64)
        }
    }
    var monogram: String {
        switch self {
        case .anthropic: "A"
        case .openAI: "O"
        case .moonshot: "K"
        case .deepSeek: "DS"
        case .openCode: "OC"
        case .githubCopilot: "GH"
        }
    }
}

struct ProviderBadge: View {
    let provider: Provider
    var body: some View {
        Text(provider.monogram)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(provider.tint)
            .frame(width: 33, height: 33)
            .background(provider.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

struct UsagePopover: View {
    @ObservedObject var store: AppStore
    var addAccount: () -> Void
    var openAccounts: () -> Void
    var onResize: ((CGSize) -> Void)?
    private var isFetching: Bool { store.statuses.values.contains(where: \.refreshing) }
    private var popupHeight: CGFloat {
        guard !store.accounts.isEmpty else { return 290 }
        let rows = store.accounts.reduce(CGFloat.zero) { height, account in
            let status = store.statuses[account.id]
            let meters = status?.snapshot?.billing == nil ? status?.snapshot?.prominentWindows.count ?? 1 : 2
            return height + max(36, CGFloat(meters) * 24) + (status?.error == nil ? 0 : 52)
        }
        let footer: CGFloat = 40
        return min(540, max(110, rows + CGFloat(max(0, store.accounts.count - 1)) * 24 + 24 + footer))
    }
    var body: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                VStack(spacing: 12) {
                    Text("Add your accounts to track their usage")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add account", action: addAccount)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.primary.opacity(0.06))
                        .overlay(Rectangle().strokeBorder(.primary.opacity(0.2)))
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.accounts) { account in
                            PopoverAccountRow(account: account, status: store.statuses[account.id] ?? AccountStatus())
                            if account.id != store.accounts.last?.id { Divider() }
                        }
                    }.padding(12)
                }
            }
            if let error = store.storageError {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            HStack(spacing: 6) {
                if let lastCheck = store.lastCheckedAt {
                    Text("Last check \(lastCheck, style: .time)")
                }
                if isFetching {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Fetching usage")
                }
                Spacer()
                Button(action: openAccounts) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Configure accounts")
                .accessibilityLabel("Configure accounts")
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 12)
        }
        .frame(width: 370, height: popupHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().strokeBorder(.primary.opacity(0.15)))
        .tint(.primary)
        .onChange(of: popupHeight, initial: true) { _, height in
            onResize?(CGSize(width: 370, height: height))
        }
    }
}

struct PopoverAccountRow: View {
    let account: Account
    let status: AccountStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayProviderName).font(.system(size: 12, weight: .medium))
                    Text(account.provider == .githubCopilot && !account.email.hasPrefix("@") ? "@\(account.email)" : account.email)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).help(account.email)
                }
                .frame(width: 126, alignment: .leading)
                VStack(spacing: 4) {
                    if let snapshot = status.snapshot {
                        if let billing = snapshot.billing {
                            APIBillingView(billing: billing, stale: status.error != nil, compact: true)
                        }
                        ForEach(snapshot.prominentWindows) { window in
                            PopoverUsageMeter(window: window, stale: status.error != nil)
                        }
                    } else if status.error == nil {
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity)
            }
            if let error = status.error {
                Text(error).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct APIBillingView: View {
    let billing: APIBillingSummary
    var stale = false
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 8) {
            Text(billing.kind == .balance ? "Available balance" : "Month-to-date spend")
                .font(.caption).foregroundStyle(.secondary)
            Text(billing.amount, format: .currency(code: billing.currency).precision(.fractionLength(2...4)))
                .font(compact ? .system(size: 13, weight: .medium, design: .monospaced) : .title2)
                .monospacedDigit()
            if !compact {
                if let cash = billing.cashBalance {
                    Text("Cash: \(cash.formatted(.currency(code: billing.currency).precision(.fractionLength(2...4))))")
                }
                if let vouchers = billing.voucherBalance {
                    Text("Vouchers: \(vouchers.formatted(.currency(code: billing.currency).precision(.fractionLength(2...4))))")
                }
                if let start = billing.periodStart {
                    Text("Since \(start.formatted(.iso8601.year().month().day().dateSeparator(.dash))) (UTC)")
                }
                if let refreshed = billing.dataRefreshedAt {
                    Text("Provider data updated \(refreshed, style: .relative) ago")
                        .foregroundStyle(.secondary)
                }
            }
            if stale { Text("Stale").font(.caption2).foregroundStyle(.orange) }
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PopoverUsageMeter: View {
    let window: UsageWindow
    var stale = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    private var meterColor: Color {
        switch window.usedPercent {
        case ..<40: Color(red: 0.21, green: 0.36, blue: 0.51) // Slate blue
        case ..<70: Color(red: 0.21, green: 0.41, blue: 0.31) // Forest green
        case ..<90: Color(red: 0.55, green: 0.36, blue: 0.18) // Burnt amber
        default: Color(red: 0.57, green: 0.25, blue: 0.29) // Muted crimson
        }
    }

    private var creditValues: String? {
        guard let used = window.usedCredits, let limit = window.creditAllowance else { return nil }
        return "\(used.formatted(.number.precision(.fractionLength(0...2)))) / \(limit.formatted(.number.precision(.fractionLength(0...2))))"
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width * window.usedPercent / 100)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: isDark ? 0.13 : 0.92))
                Rectangle().fill(meterColor).frame(width: width)
                meterText.foregroundStyle(Color(white: isDark ? 0.94 : 0.10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Two clipped text passes keep every glyph legible over the fill and track,
                // without putting a separate badge or background behind the value.
                meterText.foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mask(alignment: .leading) { Rectangle().frame(width: width) }
            }
            .overlay {
                if stale {
                    Rectangle().strokeBorder(.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                } else {
                    Rectangle().strokeBorder(.primary.opacity(0.16), lineWidth: 1)
                }
            }
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(window.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(Int(window.usedPercent.rounded(.down))) percent used\(stale ? ", stale data" : "")")
        .accessibilityValue(creditValues ?? "")
    }

    private var meterText: some View {
        Text(isHovered ? creditValues ?? "\(Int(window.usedPercent.rounded(.down)))%" : "\(Int(window.usedPercent.rounded(.down)))%")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            .padding(.horizontal, 4)
    }
}

struct UsageMeter: View {
    let window: UsageWindow
    let color: Color
    var stale = false
    var showsAllowanceSource = true
    private var meterColor: Color {
        window.usedPercent >= 100 ? .red : window.usedPercent >= 70 ? .orange : color
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.usedPercent.rounded(.down)))%")
                    .monospacedDigit().fontWeight(.medium)
                    .foregroundStyle(stale ? Color.secondary : meterColor)
            }.font(.caption)
            GeometryReader { geometry in
                Capsule().fill(.primary.opacity(0.07))
                    .overlay(alignment: .leading) {
                        Capsule().fill(meterColor.opacity(stale ? 0.4 : 0.9))
                            .frame(width: max(0, geometry.size.width * window.usedPercent / 100))
                    }
            }.frame(height: 5)
            if let used = window.usedCredits, let allowance = window.creditAllowance {
                Text("\(used.formatted(.number.precision(.fractionLength(0...2)))) / \(allowance.formatted(.number.precision(.fractionLength(0...2)))) credits")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if showsAllowanceSource && window.isUserProvidedAllowance == true {
                Text("User-provided allowance").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let reset = window.resetsAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if reset > context.date {
                        Text("Resets \(reset, style: .relative)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    } else {
                        Text("Awaiting reset update").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(Int(window.usedPercent)) percent used\(window.isUserProvidedAllowance == true ? ", user-provided allowance" : "")\(stale ? ", stale data" : "")")
    }
}
