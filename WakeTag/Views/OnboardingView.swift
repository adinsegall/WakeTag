import SwiftUI

/// Welcome → create account → grant permissions → register the NFC tag.
/// The model is only populated at the final step, so a partial run restarts
/// cleanly.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    private enum Step {
        case welcome, account, permissions, tag
    }

    @State private var step: Step = .welcome

    // Account draft
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var accountError: String?

    // Permissions
    @State private var alarmsGranted = false
    @State private var musicGranted = false

    // Tag
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var draftAccountRegistered = false

    var body: some View {
        ZStack {
            Design.backgroundGradient.ignoresSafeArea()
            switch step {
            case .welcome: welcome
            case .account: accountForm
            case .permissions: permissions
            case .tag: tagRegistration
            }
        }
        .animation(.easeInOut, value: stepAnimationKey)
    }

    private var stepAnimationKey: Int {
        switch step {
        case .welcome: 0
        case .account: 1
        case .permissions: 2
        case .tag: 3
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 72))
                .foregroundStyle(Design.sunriseGradient)
            Text("WakeTag")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("The alarm clock you can't talk your way out of. Your alarm plays any Apple Music song — and only scanning your NFC tag will stop it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            PrimaryButton(title: "Get Started", systemImage: "arrow.right") {
                step = .account
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    private var accountForm: some View {
        VStack(spacing: 20) {
            header(title: "Create your account",
                   subtitle: "WakeTag is registration-first: your alarms belong to you.")

            VStack(spacing: 12) {
                TextField("Name", text: $name)
                    .textContentType(.name)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                SecureField("Password (6+ characters)", text: $password)
                    .textContentType(.newPassword)
            }
            .textFieldStyle(.plain)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24)

            if let accountError {
                Text(accountError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()
            PrimaryButton(title: "Register", isDisabled: !accountValid) {
                accountError = nil
                step = .permissions
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .padding(.top, 60)
    }

    private var accountValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && email.contains("@") && email.contains(".")
            && password.count >= 6
    }

    private var permissions: some View {
        VStack(spacing: 20) {
            header(title: "Permissions",
                   subtitle: "Alarms ring even when the app is closed. Apple Music powers your wake-up song.")

            VStack(spacing: 12) {
                permissionRow(
                    icon: "alarm.fill",
                    title: "Alarms",
                    granted: alarmsGranted,
                    detail: "Required — this is the alarm.") {
                        alarmsGranted = await AlarmScheduler.ensureAuthorized()
                    }
                permissionRow(
                    icon: "music.note",
                    title: "Apple Music",
                    granted: musicGranted,
                    detail: "Pick any song as your alarm sound.") {
                        musicGranted = await MusicService.shared.requestAuthorization()
                    }
            }
            .padding(.horizontal, 24)

            Spacer()
            PrimaryButton(title: "Continue", isDisabled: !alarmsGranted) {
                step = .tag
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .padding(.top, 60)
    }

    private func permissionRow(icon: String, title: String, granted: Bool,
                               detail: String, request: @escaping () async -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(Design.sunriseGradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Allow") {
                    Task { await request() }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var tagRegistration: some View {
        VStack(spacing: 20) {
            header(title: "Register your tag",
                   subtitle: "This physical tag becomes the only way to stop an alarm. Keep it away from your bed — the walk is the point.")

            Spacer()

            Image(systemName: isScanning ? "wave.3.forward.circle.fill" : "wave.3.forward.circle")
                .font(.system(size: 96))
                .foregroundStyle(Design.sunriseGradient)
                .symbolEffect(.pulse, isActive: isScanning)

            Text("Works with NTAG213/215/216 stickers and most NFC tags. (MIFARE Classic isn't supported by iPhones.)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            if let scanError {
                Text(scanError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
            PrimaryButton(title: isScanning ? "Scanning…" : "Scan Tag",
                          systemImage: "dot.radiowaves.up.forward",
                          isDisabled: isScanning) {
                Task { await scanAndFinish() }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .padding(.top, 60)
    }

    private func header(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Actions

    private func scanAndFinish() async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        do {
            let uid = try await NFCService().scanTag(prompt: "Hold your iPhone near the tag you'll use to stop alarms.")
            if !draftAccountRegistered {
                try model.register(name: name.trimmingCharacters(in: .whitespaces),
                                   email: email.lowercased(), password: password)
                draftAccountRegistered = true
            }
            model.registeredTag = RegisteredTag(uid: uid)
        } catch {
            scanError = error.localizedDescription
        }
    }
}
