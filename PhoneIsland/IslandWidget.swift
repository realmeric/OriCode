import ActivityKit
import Link
import SwiftUI
import WidgetKit

@main
struct IslandWidgets: WidgetBundle {
    var body: some Widget {
        IslandActivity()
    }
}

/// What's running, in the Dynamic Island and on the Lock Screen: no words in the small
/// presentations, and when the Mac hasn't been heard from for a while everything rests, as home
/// does while the Mac is away.
struct IslandActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IslandAttributes.self) { context in
            IslandLock(state: context.state, rests: context.isStale)
                .activityBackgroundTint(.black.opacity(0.9))
                .activitySystemActionForegroundColor(Ink.secondary)
                .widgetURL(context.state.link)
        } dynamicIsland: { context in
            let state = context.state
            let rests = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandMark(state: state, rests: rests)
                        .frame(width: 26, height: 26)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandCount(state: state, rests: rests, both: true)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // 160 points at most, 52 of them beside the camera: a third row is cut in half.
                    IslandRows(state: state, rests: rests, fits: 2)
                }
            } compactLeading: {
                IslandMark(state: state, rests: rests)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                IslandCount(state: state, rests: rests)
            } minimal: {
                IslandMark(state: state, rests: rests, hand: state.asks > 0)
                    .frame(width: 24, height: 24)
            }
            .widgetURL(state.link)
            .keylineTint(.white.opacity(0.18))
        }
    }
}

/// The Mac's mark, its rays lit in the agents' colours. Asking, its dot is white, and where the
/// mark stands alone a raised hand takes the dot's place, since the Mac's pulse can't run here: the
/// system ignores repeating animation.
struct IslandMark: View {
    let state: IslandState
    let rests: Bool
    var hand = false

    var body: some View {
        Mark(
            lit: rests ? [:] : state.rays.mapValues(Palette.agent),
            dot: rests || state.asks > 0 ? .white : Palette.agent(state.rays[0] ?? ""),
            dotOpacity: rests ? 0.28 : hand ? 0 : 0.92,
            restingOpacity: 0.28)
            .overlay {
                if hand { IslandHand(rests: rests, size: 11) }
            }
    }
}

struct IslandHand: View {
    let rests: Bool
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(rests ? Ink.faint : Ink.primary)
            .accessibilityLabel("Waiting on you")
    }
}

/// How many are at work, or the hand when something waits, or `both` where there's room.
struct IslandCount: View {
    let state: IslandState
    let rests: Bool
    var both = false

    var body: some View {
        HStack(spacing: 8) {
            if state.asks == 0 || both {
                Text(state.working, format: .number)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(rests ? Ink.faint : Ink.primary)
                    .contentTransition(.numericText())
            }
            if state.asks > 0 { IslandHand(rests: rests) }
        }
    }
}

/// The threads, what waits first, as many as fit; a tap on one opens it.
struct IslandRows: View {
    let state: IslandState
    let rests: Bool
    let fits: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.rows.prefix(fits)) { row in
                Link(destination: IslandLink.thread(row.id)) {
                    HStack(spacing: 10) {
                        Badge(project: row.project)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(rests ? Ink.secondary : Ink.primary)
                                .lineLimit(1)
                            if let step = row.step {
                                Text(step)
                                    .font(.footnote)
                                    .foregroundStyle(rests ? Ink.faint : row.asking ? Ink.secondary : Ink.faint)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// The same on the Lock Screen, calm: the mark beside the threads.
struct IslandLock: View {
    let state: IslandState
    let rests: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IslandMark(state: state, rests: rests, hand: state.asks > 0)
                .frame(width: 26, height: 26)
            IslandRows(state: state, rests: rests, fits: 3)
        }
        .padding(14)
    }
}
