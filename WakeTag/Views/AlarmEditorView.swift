import SwiftUI

struct AlarmEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: WakeAlarm
    @State private var time: Date
    @State private var showingSongPicker = false
    private let isNew: Bool

    init(alarm: WakeAlarm) {
        _draft = State(initialValue: alarm)
        var components = DateComponents()
        components.hour = alarm.hour
        components.minute = alarm.minute
        _time = State(initialValue: Calendar.current.date(from: components) ?? .now)
        isNew = AppModel.shared.alarms.contains { $0.id == alarm.id } == false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                } header: {
                    Text("Time")
                }

                Section("Repeat") {
                    WeekdayPicker(selection: $draft.repeatDays)
                        .padding(.vertical, 4)
                }

                Section("Song") {
                    Button {
                        showingSongPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: draft.song?.artworkURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(draft.song?.title ?? "Choose a song")
                                    .foregroundStyle(draft.song == nil ? .secondary : .primary)
                                if let artist = draft.song?.artistName {
                                    Text(artist).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Label") {
                    TextField("Label", text: $draft.label)
                }
            }
            .navigationTitle(isNew ? "New Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingSongPicker) {
                SongPickerView(selection: $draft.song)
            }
        }
        .tint(.orange)
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        draft.hour = components.hour ?? 7
        draft.minute = components.minute ?? 0
        draft.isEnabled = true
        let alarm = draft
        Task { await model.upsertAlarm(alarm) }
        dismiss()
    }
}
