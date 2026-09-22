import SwiftUI

/// Inline permission request: what the agent wants to do, its scope, and
/// Approve / Always allow / Deny while pending; a settled badge afterwards.
struct PermissionRequestCard: View {
    let record: PermissionRequestRecord
    let onDecision: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "hand.raised.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text(record.isPending ? "Approval needed" : decisionTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                BadgeView(scopeTitle, tint: Theme.warning)
            }

            Text(record.summary)
                .font(.subheadline)

            if let detail = record.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }

            if record.isPending {
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        onDecision(.denied)
                    } label: {
                        Text("Deny")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(A11yID.Session.permissionDeny(record.id))

                    Button {
                        onDecision(.approvedOnce)
                    } label: {
                        Text("Approve")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(A11yID.Session.permissionApprove(record.id))

                    Button {
                        onDecision(.approvedAlways)
                    } label: {
                        Text("Always")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(A11yID.Session.permissionApproveAlways(record.id))
                }
                .font(.subheadline)
            } else {
                BadgeView(
                    decisionTitle,
                    tint: record.decision == .denied ? Theme.danger : Theme.success,
                    systemImage: record.decision == .denied ? "xmark" : "checkmark"
                )
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.warning.opacity(0.4), lineWidth: 1)
        }
        .accessibilityIdentifier(A11yID.Session.permissionCard(record.id))
        .accessibilityElement(children: .contain)
    }

    private var scopeTitle: String {
        switch record.scope {
        case .read: return "Read"
        case .write: return "Write"
        case .command: return "Command"
        case .network: return "Network"
        case .other: return "Action"
        }
    }

    private var decisionTitle: String {
        switch record.decision {
        case .approvedOnce: return "Approved"
        case .approvedAlways: return "Always allowed"
        case .denied: return "Denied"
        case nil: return "Approval needed"
        }
    }
}

#Preview("Permission cards") {
    VStack(spacing: 12) {
        PermissionRequestCard(
            record: {
                if case .permissionRequest(let record) = PreviewData.transcript[5] {
                    return record
                }
                return PermissionRequestRecord(id: TranscriptItemID("x"), summary: "Run npm install")
            }(),
            onDecision: { _ in }
        )
        PermissionRequestCard(
            record: PermissionRequestRecord(
                id: TranscriptItemID("y"),
                summary: "Read Secrets.swift",
                scope: .read,
                decision: .denied
            ),
            onDecision: { _ in }
        )
    }
    .padding()
}
