import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var isRescanning = false
    @State private var rescanError: String?
    @State private var showingSignOutConfirmation = false
    @State private var testAlarmScheduled = false

    var body: some View {
        NavigationStack {
            Form {
                if let account = model.account {
                    Section("Account") {
                        LabeledContent("Name", value: account.name)
                        LabeledContent("Email", value: account.email)
                        LabeledContent("Member since",
                                       value: account.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }

                if let tag = model.registeredTag {
                    Section {
                        LabeledContent("Name") {
                            TextField("Tag name", text: Binding(
                                get: { tag.name },
                                set: { model.registeredTag?.name = $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("UID") {
                            Text(tag.formattedUID).font(.caption.monospaced())
                        }
                        Button {
                            Task { await rescanTag() }
                        } label: {
                            if isRescanning {
                                ProgressView()
                            } else {
                                Text("Replace Tag…")
                            }
                        }
                        if let rescanError {
                            Text(rescanError).font(.footnote).foregroundStyle(.red)
                        }
                    } header: {
                        Text("NFC Tag")
                    } footer: {
                        Text("Only this tag can stop a ringing alarm or unlock volume controls.")
                    }
                }

                Section {
                    Toggle("Volume guard", isOn: $model.volumeGuardEnabled)
                        .tint(.orange)
                } footer: {
                    Text("While an alarm rings, the system volume snaps back up if it's lowered — until the tag is scanned.")
                }

                Section {
                    Button {
                        Task {
                            await model.scheduleTestAlarm()
                            testAlarmScheduled = true
                        }
                    } label: {
                        Label("Test alarm (rings in ~1 minute)", systemImage: "bell.badge")
                    }
                    if testAlarmScheduled {
                        Text("Scheduled. Lock the phone or close the app — it'll still ring.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Tip: alarms fire even with Silent mode or a Focus on.")
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        showingSignOutConfirmation = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign out and erase everything on this device?",
                                isPresented: $showingSignOutConfirmation,
                                titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    model.signOut()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .tint(.orange)
    }

    private func rescanTag() async {
        isRescanning = true
        rescanError = nil
        defer { isRescanning = false }
        do {
            let uid = try await NFCService().scanTag(prompt: "Scan the new tag to register it.")
            let name = model.registeredTag?.name ?? "My Tag"
            model.registeredTag = RegisteredTag(uid: uid, name: name)
        } catch {
            rescanError = error.localizedDescription
        }
    }
}
