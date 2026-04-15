import SwiftUI

/// First-launch onboarding with 4 pages: Welcome, Features, Setup, Ready.
/// Shows once, persists via @AppStorage.
struct OnboardingView: View {

    @Binding var isPresented: Bool
    @State private var currentPage = 0
    @State private var depStatus: [String: Bool] = [:]
    @State private var isCheckingDeps = false

    private let pages = 4

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                featuresPage.tag(1)
                setupPage.tag(2)
                readyPage.tag(3)
            }
            .tabViewStyle(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation bar
            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation { currentPage -= 1 }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                // Page dots
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.indigo : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .scaleEffect(i == currentPage ? 1.2 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: currentPage)
                    }
                }

                Spacer()

                if currentPage < pages - 1 {
                    Button("Next") {
                        withAnimation { currentPage += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                } else {
                    Button("Get Started") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.large)
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 480)
        .task {
            isCheckingDeps = true
            depStatus = await withCheckedContinuation { c in
                DispatchQueue.global().async {
                    c.resume(returning: Shell.checkDependencies())
                }
            }
            isCheckingDeps = false
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "light.beacon.max")
                .font(.system(size: 72))
                .foregroundStyle(.indigo)
                .symbolRenderingMode(.hierarchical)

            Text("Welcome to Phosphor")
                .font(.largeTitle.weight(.bold))

            Text("The free, open-source iOS device manager.\nNo subscriptions. No iCloud lock-in. Just your device, your data.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Spacer()
        }
    }

    // MARK: - Page 2: Features

    private var featuresPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Everything you need")
                .font(.title.weight(.bold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                featureCard("externaldrive.fill", "Backups", "Full & incremental local backups with browsing")
                featureCard("message.fill", "Messages", "Export iMessage, WhatsApp, Notes to CSV/HTML")
                featureCard("photo.on.rectangle.angled", "Photos", "Extract Camera Roll without iCloud")
                featureCard("battery.100percent", "Battery", "Health, cycle count, voltage, temperature")
                featureCard("camera.viewfinder", "Screen", "Live screen capture and screenshot")
                featureCard("location.fill", "Location", "GPS spoofing with map and GPX routes")
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    private func featureCard(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.indigo)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Page 3: Setup

    private var setupPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Quick Setup")
                .font(.title.weight(.bold))

            Text("Phosphor needs pymobiledevice3 to talk to your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                setupRow(
                    "pymobiledevice3",
                    installed: depStatus["pymobiledevice3"] ?? false,
                    command: "pip3 install pymobiledevice3"
                )
                setupRow(
                    "libimobiledevice (optional fallback)",
                    installed: depStatus["ideviceinfo"] ?? false,
                    command: "brew install libimobiledevice"
                )

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("iOS 17+ Developer Tools (screen capture, location)")
                        .font(.system(size: 12, weight: .medium))
                    Text("Requires a one-time tunnel service:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("sudo pymobiledevice3 remote tunneld")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            "sudo pymobiledevice3 remote tunneld".copyToClipboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(6)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(20)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 440)

            if isCheckingDeps {
                ProgressView("Checking dependencies...")
                    .font(.system(size: 11))
            }

            Spacer()
        }
    }

    private func setupRow(_ name: String, installed: Bool, command: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(installed ? .green : .orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                if !installed {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Text(installed ? "Ready" : "Missing")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(installed ? .green : .orange)
        }
    }

    // MARK: - Page 4: Ready

    private var readyPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("You're all set")
                .font(.title.weight(.bold))

            Text("Connect your iPhone, iPad, or iPod touch via USB\nand start managing your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 8) {
                tipRow("1", "Connect your device via USB cable")
                tipRow("2", "Trust this computer on your device if prompted")
                tipRow("3", "Select any section from the sidebar to begin")
            }
            .padding(16)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Spacer()
        }
    }

    private func tipRow(_ num: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(num)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.indigo)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 13))
        }
    }
}
