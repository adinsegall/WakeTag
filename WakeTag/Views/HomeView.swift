import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingAlarm: WakeAlarm?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Design.backgroundGradient.ignoresSafeArea()
                if model.alarms.isEmpty {
                    emptyState
                } else {
                    alarmList
                }
            }
            .navigationTitle("WakeTag")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingAlarm = WakeAlarm()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editingAlarm) { alarm in
                AlarmEditorView(alarm: alarm)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        .tint(.orange)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "alarm")
                .font(.system(size: 56))
                .foregroundStyle(Design.sunriseGradient)
            Text("No alarms yet")
                .font(.title2.bold())
            Text("Add one, pick a song, and put your tag somewhere far from bed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            PrimaryButton(title: "New Alarm", systemImage: "plus") {
                editingAlarm = WakeAlarm()
            }
            .padding(.horizontal, 80)
        }
    }

    private var alarmList: some View {
        List {
            if let next = nextAlarmText {
                Section {
                    Label(next, systemImage: "clock.badge")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(model.alarms) { alarm in
                    AlarmRow(alarm: alarm) {
                        editingAlarm = alarm
                    }
                }
                .onDelete { offsets in
                    model.deleteAlarms(at: offsets)
                }
            }
            if let tag = model.registeredTag {
                Section {
                    HStack {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(Design.sunriseGradient)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.name).font(.subheadline.weight(.medium))
                            Text(tag.formattedUID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var nextAlarmText: String? {
        let upcoming = model.alarms
            .filter(\.isEnabled)
            .compactMap { $0.nextFireDate() }
            .min()
        guard let upcoming else { return nil }
        let delta = upcoming.formatted(.relative(presentation: .named))
        return "Next alarm \(delta) — \(upcoming.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct AlarmRow: View {
    @EnvironmentObject private var model: AppModel
    let alarm: WakeAlarm
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.timeString)
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .foregroundStyle(alarm.isEnabled ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(alarm.repeatDescription)
                    if let song = alarm.song {
                        Text("·")
                        Image(systemName: "music.note").font(.caption2)
                        Text(song.title).lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { alarm.isEnabled },
                set: { enabled in Task { await model.setAlarm(alarm, enabled: enabled) } }
            ))
            .labelsHidden()
            .tint(.orange)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .listRowBackground(Color.white.opacity(0.05))
    }
}
