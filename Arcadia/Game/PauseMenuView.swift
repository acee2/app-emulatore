import SwiftUI

struct PauseMenuView: View {
    @ObservedObject var session: GameSession
    @ObservedObject private var settings = AppSettings.shared
    let onExit: () -> Void

    private enum Page { case main, save, load }
    @State private var page: Page = .main

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { if page == .main { session.closeMenu() } else { page = .main } }

            VStack(spacing: 14) {
                header
                switch page {
                case .main: mainPage
                case .save: slotList(saving: true)
                case .load: slotList(saving: false)
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            if page != .main {
                Button { page = .main } label: {
                    Image(systemName: "chevron.left").font(.headline)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.game.title).font(.headline).lineLimit(1)
                Text(session.game.system.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { session.closeMenu() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
            }
        }
    }

    private var mainPage: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MenuTile(icon: "play.fill", title: "Riprendi") { session.closeMenu() }
                MenuTile(icon: "square.and.arrow.down", title: "Salva stato") { page = .save }
                MenuTile(icon: "clock.arrow.circlepath", title: "Carica stato") { page = .load }
                MenuTile(icon: "arrow.counterclockwise", title: "Riavvia") { session.reset() }
                MenuTile(icon: settings.showTouchControls ? "hand.tap.fill" : "hand.tap",
                         title: settings.showTouchControls ? "Nascondi comandi" : "Mostra comandi") {
                    settings.showTouchControls.toggle()
                }
                MenuTile(icon: "rectangle.portrait.and.arrow.right", title: "Salva ed esci", tint: .red) {
                    onExit()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Velocità").font(.caption).foregroundStyle(.secondary)
                Picker("Velocità", selection: Binding(get: { session.speed }, set: { session.setSpeed($0) })) {
                    ForEach(AppSettings.speedOptions, id: \.self) { s in
                        Text("\(Int(s))×").tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func slotList(saving: Bool) -> some View {
        let slots: [SaveSlot] = saving
            ? SaveSlot.manualSlots.map { .manual($0) }
            : [.auto, .backup] + SaveSlot.manualSlots.map { .manual($0) }
        return ScrollView {
            VStack(spacing: 8) {
                ForEach(slots) { slot in
                    let date = session.stateStore.date(for: slot)
                    Button {
                        if saving {
                            session.save(to: slot)
                            page = .main
                        } else {
                            session.load(slot)
                        }
                    } label: {
                        HStack {
                            Image(systemName: icon(for: slot)).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.title).font(.subheadline.weight(.medium))
                                Text(date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Vuoto")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if saving && date != nil {
                                Text("Sovrascrivi").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(12)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(!saving && date == nil)
                    .opacity(!saving && date == nil ? 0.45 : 1)
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private func icon(for slot: SaveSlot) -> String {
        switch slot {
        case .auto: return "arrow.triangle.2.circlepath"
        case .backup: return "clock.badge.checkmark"
        case .manual(let n): return "\(n).circle"
        }
    }
}

private struct MenuTile: View {
    let icon: String
    let title: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
