import SwiftUI

// MARK: - RecoveryRing
// Circular progress ring showing a recovery percentage, banded green/yellow/red.
// Thin wrapper around the generic PercentRing (see PercentRing.swift) — kept as its own type
// for backward compatibility with existing call sites (DesignGallery) and because recovery is
// the one ring with its own dynamic band coloring baked in.

struct RecoveryRing: View {

    /// Recovery percentage 0–100
    var percent: Double
    var size: CGFloat = 180
    var strokeWidth: CGFloat = 14

    private var clamped: Double { min(100, max(0, percent)) }

    var body: some View {
        PercentRing(
            value: clamped,
            size: size,
            strokeWidth: strokeWidth,
            color: WH.Color.recoveryColor(forPercent: clamped),
            label: "RECOVERY"
        )
    }
}

// MARK: - Preview

#Preview("Recovery Ring — all bands") {
    HStack(spacing: WH.Spacing.xl) {
        RecoveryRing(percent: 82, size: 140)
        RecoveryRing(percent: 51, size: 140)
        RecoveryRing(percent: 18, size: 140)
    }
    .padding(WH.Spacing.xl)
    .background(WH.Color.background)
}
