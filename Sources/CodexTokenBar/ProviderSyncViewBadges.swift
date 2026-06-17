import SwiftUI

struct ProviderTargetPill: View {
    let snapshot: ProviderSyncSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.hasMixedProviders ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(snapshot.hasMixedProviders ? AppTheme.accentOrange : AppTheme.accentCyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.detectedProvider)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(snapshot.providerSource)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(AppTheme.raisedBackground)
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

struct ProviderSyncMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.raisedBackground)
        )
    }
}

struct ProviderDistributionRow: View {
    let title: String
    let values: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            if values.isEmpty {
                Text("暂无")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(values.prefix(4).joined(separator: "  ·  "))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
