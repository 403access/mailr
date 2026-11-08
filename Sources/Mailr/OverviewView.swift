import SwiftUI
import MailCore

/// A dashboard for the whole mailbox collection: totals, recent activity,
/// account breakdowns, and the busiest senders.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var compact: Bool = false
    var onOpenDrawer: (() -> Void)? = nil

    private let statColumns = [
        GridItem(.adaptive(minimum: 148, maximum: 300), spacing: 12, alignment: .top)
    ]

    private let cardColumns = [
        GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if model.runtimes.isEmpty {
                    EmptyStateView(
                        icon: "chart.bar.xaxis",
                        title: "Nothing to Summarize",
                        message: "Add a mail account to see statistics across your mailboxes."
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 380)
                } else {
                    statGrid
                    activityCard

                    LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 14) {
                        accountsCard
                        sendersCard
                        mailboxRolesCard
                    }
                }

                if let error = model.overviewError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(MailrTheme.amber)
                        Text(error)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(MailrTheme.inkSecondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.top, compact ? 12 : 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("")
        .mailrInlineNavigationTitle()
        .toolbar {
            #if os(iOS)
            if let onOpenDrawer {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenDrawer) {
                        Label("Show Mailboxes", systemImage: "line.3.horizontal")
                    }
                }
            }
            #endif
        }
        .task { await model.loadOverview() }
        .refreshable { await model.loadOverview() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                MailrSectionLabel(text: "All accounts")

                Text("Overview")
                    .font(.system(size: compact ? 29 : 30, weight: .bold, design: .rounded))
                    .foregroundStyle(MailrTheme.inkGradient)

                Text(subtitle)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if model.isLoadingOverview {
                ProgressView()
                    .controlSize(.small)
                    .tint(MailrTheme.accent)
                    .frame(width: 36, height: 36)
            } else {
                Button {
                    Task { await model.loadOverview() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.mailrIcon)
                .mailrHelp("Refresh Overview")
            }
        }
    }

    private var subtitle: String {
        let accounts = model.runtimes.count
        let mailboxes = model.runtimes.reduce(0) { $0 + $1.mailboxes.count }
        let messages = model.totalMessagesInAllMailboxes

        var parts = [
            "\(accounts) account\(accounts == 1 ? "" : "s")",
            "\(mailboxes) mailbox\(mailboxes == 1 ? "" : "es")"
        ]
        if messages > 0 {
            parts.append("\(messages.formatted()) messages")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Stats

    private var statGrid: some View {
        LazyVGrid(columns: statColumns, alignment: .leading, spacing: 12) {
            OverviewStatCard(
                systemImage: "envelope.fill",
                value: model.totalMessagesInAllMailboxes.formatted(),
                label: "Messages",
                tint: MailrTheme.accent
            )

            OverviewStatCard(
                systemImage: "circle.fill",
                value: model.totalUnreadInAllMailboxes.formatted(),
                label: "Unread",
                tint: MailrTheme.cyan
            )

            OverviewStatCard(
                systemImage: "star.fill",
                value: recentFlagged.formatted(),
                label: "Flagged in cache",
                tint: MailrTheme.amber
            )

            OverviewStatCard(
                systemImage: "paperclip",
                value: recentAttachments.formatted(),
                label: "Cached attachments",
                tint: MailrTheme.mint
            )
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverviewCardHeader(
                title: "Activity",
                detail: "\(activityTotal.formatted()) message\(activityTotal == 1 ? "" : "s") in the last 14 days"
            ) {
                if recentFlagged > 0 {
                    MailrStatChip(
                        systemImage: "star.fill",
                        text: "\(recentFlagged.formatted()) flagged",
                        highlighted: true
                    )
                }
                if recentAttachments > 0 {
                    MailrStatChip(
                        systemImage: "paperclip",
                        text: "\(recentAttachments.formatted()) attached",
                        highlighted: true
                    )
                }
            }

            if activityTotal == 0 {
                Text("No cached mail arrived in this window yet.")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ActivityChart(days: activity)
            }
        }
        .padding(16)
        .mailrCard(radius: 18, shadowRadius: 12)
    }

    private var accountsCard: some View {
        OverviewCard(
            title: "Accounts",
            detail: "\(model.runtimes.count) connected"
        ) {
            if accountStats.isEmpty {
                OverviewEmptyRow(text: "No accounts configured.")
            } else {
                VStack(spacing: 0) {
                    ForEach(accountStats) { stat in
                        Button {
                            openMailbox(for: stat)
                        } label: {
                            AccountOverviewRow(stat: stat)
                        }
                        .buttonStyle(.plain)
                        .disabled(hasMailbox(stat.account.id) == false)

                        if stat.id != accountStats.last?.id {
                            Rectangle()
                                .fill(MailrTheme.hairline)
                                .frame(height: 1)
                                .padding(.vertical, 9)
                        }
                    }
                }
            }
        }
    }

    private var sendersCard: some View {
        OverviewCard(
            title: "Top senders",
            detail: "From cached mail"
        ) {
            if topSenders.isEmpty {
                OverviewEmptyRow(text: "No received mail in the cache yet.")
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(topSenders.enumerated()), id: \.element.id) { _, sender in
                        SenderOverviewRow(sender: sender, maximum: topSenders.first?.count ?? 1)
                    }
                }
            }
        }
    }

    private var mailboxRolesCard: some View {
        OverviewCard(
            title: "Mailboxes",
            detail: "\(model.runtimes.reduce(0) { $0 + $1.mailboxes.count }) total"
        ) {
            if roleStats.isEmpty {
                OverviewEmptyRow(text: "No mailboxes loaded yet.")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 136), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(roleStats) { stat in
                        MailboxRoleTile(stat: stat)
                    }
                }
            }
        }
    }

    // MARK: - Derived data

    private var recentFlagged: Int {
        model.overviewMessages.reduce(0) { $0 + ($1.summary.isFlagged ? 1 : 0) }
    }

    private var recentAttachments: Int {
        model.overviewMessages.reduce(0) { $0 + ($1.summary.hasAttachments ? 1 : 0) }
    }

    private var activity: [ActivityDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var buckets: [Date: Int] = [:]

        for offset in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            buckets[day] = 0
        }

        for entry in model.overviewMessages {
            let day = calendar.startOfDay(for: entry.summary.date)
            if buckets[day] != nil {
                buckets[day, default: 0] += 1
            }
        }

        return (0..<14).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return ActivityDay(date: day, count: buckets[day] ?? 0)
        }
    }

    private var activityTotal: Int {
        activity.reduce(0) { $0 + $1.count }
    }

    private var accountStats: [AccountOverview] {
        model.runtimes.map { runtime in
            AccountOverview(
                id: runtime.id,
                account: runtime.account,
                mailboxCount: runtime.mailboxes.count,
                total: runtime.mailboxes.reduce(0) { $0 + $1.totalCount },
                unread: runtime.mailboxes.reduce(0) { $0 + $1.unreadCount }
            )
        }
    }

    private var roleStats: [RoleOverview] {
        var totals: [MailboxRole: (total: Int, unread: Int, count: Int)] = [:]
        for runtime in model.runtimes {
            for box in runtime.mailboxes {
                var entry = totals[box.role] ?? (total: 0, unread: 0, count: 0)
                entry.total += box.totalCount
                entry.unread += box.unreadCount
                entry.count += 1
                totals[box.role] = entry
            }
        }

        return MailboxRole.allCases.compactMap { role in
            guard let entry = totals[role] else { return nil }
            return RoleOverview(
                role: role,
                total: entry.total,
                unread: entry.unread,
                mailboxCount: entry.count
            )
        }
    }

    private var topSenders: [SenderOverview] {
        let ownAddresses = Set(
            model.runtimes.map { $0.account.emailAddress.lowercased() }
        )

        var groups: [String: (name: String, address: String, count: Int, unread: Int)] = [:]
        for entry in model.overviewMessages {
            guard let sender = entry.summary.from.first else { continue }
            let key = sender.address.lowercased()
            guard !key.isEmpty, !ownAddresses.contains(key) else { continue }

            var group = groups[key] ?? (sender.displayName, sender.address, 0, 0)
            group.count += 1
            if entry.summary.isUnread {
                group.unread += 1
            }
            groups[key] = group
        }

        return groups.map { key, value in
            SenderOverview(
                id: key,
                name: value.name,
                address: value.address,
                count: value.count,
                unread: value.unread
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        .prefix(6)
        .map { $0 }
    }

    private func hasMailbox(_ accountID: UUID) -> Bool {
        model.runtimes.first(where: { $0.id == accountID })?.mailboxes.isEmpty == false
    }

    private func openMailbox(for stat: AccountOverview) {
        guard let runtime = model.runtimes.first(where: { $0.id == stat.id }) else { return }
        guard let mailbox = runtime.mailboxes.first(where: { $0.role == .inbox })
            ?? runtime.mailboxes.first else {
            return
        }
        model.selectMailbox(MailboxSelection(accountID: runtime.id, mailboxPath: mailbox.path))
    }
}

// MARK: - Cards

private struct OverviewStatCard: View {
    let systemImage: String
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(MailrTheme.inkGradient)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mailrCard(radius: 16, shadowRadius: 10)
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewCard<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverviewCardHeader(title: title, detail: detail)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mailrCard(radius: 18, shadowRadius: 12)
    }
}

private struct OverviewCardHeader<Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                MailrSectionLabel(text: title)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                accessory
            }
        }
    }
}

private extension OverviewCardHeader where Accessory == EmptyView {
    init(title: String, detail: String) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

private struct OverviewEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(MailrTheme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

// MARK: - Rows and tiles

private struct AccountOverviewRow: View {
    let stat: AccountOverview

    private var unreadRatio: Double {
        guard stat.total > 0 else { return 0 }
        return min(1, Double(stat.unread) / Double(stat.total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                AvatarView(
                    name: stat.account.displayName,
                    address: stat.account.emailAddress,
                    size: 28
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(stat.account.displayName)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)
                        .lineLimit(1)
                    Text(stat.account.emailAddress)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(stat.total.formatted()) mail")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.inkSecondary)
                        .monospacedDigit()
                    if stat.unread > 0 {
                        Text("\(stat.unread.formatted()) unread")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(MailrTheme.accentDeep)
                            .monospacedDigit()
                    } else {
                        Text("\(stat.mailboxCount) mailbox\(stat.mailboxCount == 1 ? "" : "es")")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(MailrTheme.inkTertiary)
                            .monospacedDigit()
                    }
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(MailrTheme.surfaceSoft)
                    Capsule()
                        .fill(MailrTheme.accentGradient)
                        .frame(width: proxy.size.width * CGFloat(unreadRatio))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

private struct SenderOverviewRow: View {
    let sender: SenderOverview
    let maximum: Int

    private var ratio: Double {
        guard maximum > 0 else { return 0 }
        return min(1, Double(sender.count) / Double(maximum))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                AvatarView(name: sender.name, address: sender.address, size: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(sender.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)
                        .lineLimit(1)
                    Text(sender.address)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                HStack(spacing: 5) {
                    if sender.unread > 0 {
                        Text("\(sender.unread)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(MailrTheme.accentDeep)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MailrTheme.accent.opacity(0.10), in: Capsule())
                    }
                    Text("\(sender.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.inkSecondary)
                        .monospacedDigit()
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(MailrTheme.surfaceSoft)
                    Capsule()
                        .fill(MailrTheme.accentGradient)
                        .frame(width: proxy.size.width * CGFloat(ratio))
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }
}

private struct MailboxRoleTile: View {
    let stat: RoleOverview

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MailrTheme.surfaceSoft)
                Image(systemName: stat.role.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MailrTheme.inkSecondary)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(stat.role == .other ? "Other" : stat.role.displayName)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(MailrTheme.ink)
                    .lineLimit(1)
                Text("\(stat.total.formatted()) · \(stat.mailboxCount) box\(stat.mailboxCount == 1 ? "" : "es")")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            if stat.unread > 0 {
                CountBadge(count: stat.unread)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MailrTheme.surfaceSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(MailrTheme.hairline, lineWidth: 1)
        }
    }
}

// MARK: - Chart

private struct ActivityChart: View {
    let days: [ActivityDay]

    private var maximum: Int {
        max(days.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    Text(day.count > 0 ? "\(day.count)" : " ")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(MailrTheme.surfaceSoft)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(MailrTheme.accentGradient)
                            .frame(height: barHeight(for: day.count))
                    }
                    .frame(height: 84)

                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)

                    Text(day.date.formatted(.dateTime.day()))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary.opacity(0.75))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.count) messages"
                )
            }
        }
    }

    private func barHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(4, 84 * CGFloat(count) / CGFloat(maximum))
    }
}

// MARK: - Models

private struct ActivityDay: Identifiable {
    var date: Date
    var count: Int

    var id: Date { date }
}

private struct AccountOverview: Identifiable {
    var id: UUID
    var account: MailAccount
    var mailboxCount: Int
    var total: Int
    var unread: Int
}

private struct SenderOverview: Identifiable {
    var id: String
    var name: String
    var address: String
    var count: Int
    var unread: Int
}

private struct RoleOverview: Identifiable {
    var role: MailboxRole
    var total: Int
    var unread: Int
    var mailboxCount: Int

    var id: MailboxRole { role }
}
