import SwiftUI

/// Candidate C: model, effort and permissions as three columns of words on the composer's glass,
/// read the way Finder's columns are. One click chooses and a highlight glides to it; the arrows
/// walk between columns and down them. Each level carries a small meter that fills as it rises
/// and burns Claude's orange at Max, and Ultracode sits apart under the rays.
struct ColumnsPicker: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    /// The column the up and down arrows move in.
    @State private var column = Column.effort
    /// What a hovered row does, for the line at the foot.
    @State private var hoverLine: (words: String, cost: String?)?
    @State private var previewingReset = false
    @State private var resetTurns = 0
    @State private var blockedNote = false
    @Namespace private var glide
    @FocusState private var focused: Bool

    enum Column: Int { case model, effort, mode }

    var body: some View {
        let state = PickerState(model: model, chat: chat)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                models(state)
                    .frame(width: 150)
                efforts(state)
                    .frame(width: 150)
                modes(state)
                    .frame(width: 136)
            }
            Spacer(minLength: 0)
            footer(state)
                .frame(height: 30)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 500, height: 252)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            withAnimation(Motion.fade) { column = Column(rawValue: max(column.rawValue - 1, 0)) ?? column }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            withAnimation(Motion.fade) { column = Column(rawValue: min(column.rawValue + 1, 2)) ?? column }
            return .handled
        }
        .onKeyPress(.upArrow) { move(-1, state) }
        .onKeyPress(.downArrow) { move(1, state) }
        .onKeyPress(.delete) {
            withAnimation(Motion.move) { model.setEffort(nil, for: chat) }
            return .handled
        }
        .onKeyPress(.return) {
            model.modelPickerShown = false
            return .handled
        }
        .onAppear { focused = true }
    }

    private func heading(_ text: String, _ of: Column) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(column == of ? Ink.secondary : Ink.faint)
            .padding(.leading, 8)
            .frame(height: 18, alignment: .leading)
    }

    private func models(_ state: PickerState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading("Model", .model)
            ForEach(model.models) { option in
                let chosen = option.id == state.option?.id
                ColumnRow(chosen: chosen, glideID: "model", glide: glide, hover: { inside in
                    hoverLine = inside ? (option.description, nil) : nil
                }) {
                    withAnimation(Motion.move) { model.setModel(option.id, for: chat) }
                    column = .model
                } label: {
                    HStack(spacing: 7) {
                        ClaudeMark()
                            .frame(width: 11, height: 11)
                            .opacity(chosen ? 1 : 0.4)
                        Text(ModelMenu.shortName(option.name))
                            .foregroundStyle(chosen ? Ink.primary : Ink.primary.opacity(0.75))
                        if option.name.contains("1M") {
                            Text("1M")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Ink.faint)
                        }
                        Spacer(minLength: 0)
                        if option.fast {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Ink.faint)
                        }
                    }
                }
            }
        }
    }

    private func efforts(_ state: PickerState) -> some View {
        let stops = state.option?.stops ?? []
        let blocked = state.option.map { $0.ultraBlocked != nil && !$0.ultra } ?? false
        return VStack(alignment: .leading, spacing: 2) {
            heading("Effort", .effort)
            if stops.isEmpty {
                ColumnRow(chosen: true, glideID: "effort", glide: glide, hover: { _ in }) {} label: {
                    Text("Standard")
                        .foregroundStyle(Ink.primary)
                }
            }
            ForEach(stops, id: \.self) { stop in
                let chosen = stop == state.level
                if stop == Effort.ultracode {
                    // Past the scale, a mode of its own: a little apart, under the rays.
                    Color.clear.frame(height: 4)
                }
                ColumnRow(chosen: chosen, glideID: "effort", glide: glide, hover: { inside in
                    hoverLine = inside ? (blocked && stop == Effort.ultracode ? ("Needs dynamic workflows, see /config in Claude Code", nil) : EffortScale.line(stop)) : nil
                }) {
                    pick(stop, state, blocked: blocked)
                } label: {
                    HStack(spacing: 6) {
                        Text(ModelMenu.effortName(stop))
                            .foregroundStyle(stop == Effort.ultracode && blocked ? Ink.faint
                                             : chosen ? (EffortScale.spendsFaster(stop) ? Ink.claude : Ink.primary) : Ink.primary.opacity(0.75))
                        if stop == state.home {
                            Text("Default")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Ink.faint)
                        }
                        Spacer(minLength: 0)
                        if stop == Effort.ultracode {
                            RaysMark(lit: chosen ? RaysMark.rays : 0, turning: chosen, restingOpacity: 0.35, litOpacity: 0.95, dotOpacity: chosen ? 1 : 0.35,
                                     stagger: true, layered: true, settles: true)
                                .frame(width: 12, height: 12)
                                .opacity(blocked ? 0.4 : 1)
                        } else {
                            Meter(level: stop, lit: chosen)
                        }
                    }
                }
            }
        }
    }

    private func modes(_ state: PickerState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading("Permissions", .mode)
            ForEach(PermissionModeOption.allCases) { option in
                let chosen = option == state.mode
                ColumnRow(chosen: chosen, glideID: "mode", glide: glide, hover: { inside in
                    hoverLine = inside ? (option.summary, nil) : nil
                }) {
                    withAnimation(Motion.move) { model.setPermissionMode(option.rawValue, for: chat) }
                    column = .mode
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: option.icon)
                            .font(.system(size: 11))
                            .frame(width: 14)
                            .foregroundStyle(chosen ? Ink.primary : Ink.secondary)
                        Text(option.title)
                            .foregroundStyle(chosen ? Ink.primary : Ink.primary.opacity(0.75))
                    }
                }
            }
        }
    }

    /// The hovered row's line, or the level's, with the cost of Max and Ultracode in the usage
    /// circle's colour; fast mode and Back to Defaults on the right.
    private func footer(_ state: PickerState) -> some View {
        let words = blockedNote ? ("Needs dynamic workflows, see /config in Claude Code", nil)
            : hoverLine ?? state.fastProblem.map { ($0, nil) } ?? state.ultracodeMissing.map { ($0, nil) }
            ?? state.level.map(EffortScale.line) ?? ("Claude Code picks the level for this model", nil)
        return HStack(spacing: 8) {
            Group {
                if let cost = words.1 {
                    let band = model.usage?.headline?.used.map { Band.of($0).color } ?? Ink.secondary
                    Text("\(words.0) · \(Text(cost).foregroundStyle(band))")
                } else {
                    Text(words.0)
                }
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
            .lineLimit(1)
            .id(words.0)
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
            .padding(.leading, 8)
            Spacer(minLength: 8)
            if state.option?.fast == true {
                FastButton(asked: state.fastAsked, state: state.fastState, dimmed: previewingReset && !model.threadDefaults.fast) {
                    model.setFast(!state.fastAsked, for: chat)
                }
            }
            if !model.atDefaults(chat) {
                ResetButton(turns: resetTurns, previewing: $previewingReset) {
                    resetTurns += 1
                    previewingReset = false
                    withAnimation(Motion.move) { model.resetToDefaults(for: chat) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)).animation(Motion.move))
            }
        }
    }

    /// Landing on the level Default lands on is Default: the thread sends no level.
    private func pick(_ stop: String, _ state: PickerState, blocked: Bool) {
        column = .effort
        if blocked, stop == Effort.ultracode {
            blockedNote = true
            Task {
                try? await Task.sleep(for: .seconds(3))
                blockedNote = false
            }
            return
        }
        withAnimation(Motion.move) { model.setEffort(stop == state.home ? nil : stop, for: chat) }
    }

    private func move(_ by: Int, _ state: PickerState) -> KeyPress.Result {
        switch column {
        case .model:
            let ids = model.models.map(\.id)
            guard let at = state.option.flatMap({ ids.firstIndex(of: $0.id) }), ids.indices.contains(at + by) else { return .ignored }
            withAnimation(Motion.move) { model.setModel(ids[at + by], for: chat) }
        case .effort:
            let stops = state.option?.stops ?? []
            guard let at = state.level.flatMap(stops.firstIndex(of:)), stops.indices.contains(at + by) else { return .ignored }
            pick(stops[at + by], state, blocked: state.option.map { $0.ultraBlocked != nil && !$0.ultra } ?? false)
        case .mode:
            let modes = PermissionModeOption.allCases
            guard let at = modes.firstIndex(of: state.mode), modes.indices.contains(at + by) else { return .ignored }
            withAnimation(Motion.move) { model.setPermissionMode(modes[at + by].rawValue, for: chat) }
        }
        return .handled
    }
}

/// A row in a column: its label on the gliding highlight when it's the one, lit on hover.
private struct ColumnRow<Label: View>: View {
    let chosen: Bool
    let glideID: String
    let glide: Namespace.ID
    let hover: (Bool) -> Void
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(height: 25)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if chosen {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Surface.selected)
                            .matchedGeometryEffect(id: glideID, in: glide)
                    } else if hovering {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Surface.hover)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// How hard a level thinks as a little meter of five bars: lit up to the level, white until Max
/// burns Claude's orange, and filling one bar after another as the level is chosen.
private struct Meter: View {
    let level: String
    let lit: Bool

    private var rank: Int {
        switch level {
        case "low": 1
        case "medium": 2
        case "high": 3
        case "xhigh": 4
        default: 5
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { bar in
                let on = bar < rank
                Capsule()
                    .fill(on ? (level == "max" ? Ink.claude : Color.white.opacity(lit ? 0.9 : 0.45)) : Color.white.opacity(0.12))
                    .frame(width: 3, height: 5 + CGFloat(bar) * 2)
                    .scaleEffect(y: on && lit ? 1 : on ? 0.85 : 1, anchor: .bottom)
                    .animation(.spring(duration: 0.3, bounce: 0.4).delay(Double(bar) * 0.04), value: lit)
            }
        }
        .frame(height: 13, alignment: .bottom)
    }
}
