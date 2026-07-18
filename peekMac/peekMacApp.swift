import SwiftUI
import AppKit

// MARK: - Display Mode

enum DisplayMode: String, CaseIterable, Identifiable {
    case cpuUsage    = "CPU Usage"
    case cpuTemp     = "CPU Temperature"
    case ramUsage    = "RAM Usage"
    case gpuUsage    = "GPU Usage"
    case batteryTemp = "Battery Temperature"
    var id: String { rawValue }
}

// MARK: - App Entry Point

@main
struct StatBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // No WindowGroup needed; the whole UI lives in the status bar.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var statsMonitor = SystemStatsMonitor()
    private var activeModes: Set<DisplayMode> = [.cpuUsage, .cpuTemp, .ramUsage] {
        didSet { refreshLabel() }
    }

    // The hosting view that renders our SwiftUI label directly inside the button.
    private var labelHost: NSHostingView<StatusBarLabel>?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Hide dock icon – this is a menu bar only app
        NSApp.setActivationPolicy(.accessory)

        buildStatusItem()
        buildPopover()

        // Refresh the label every 2 s to match the stats update interval
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshLabel()
        }
    }

    // MARK: - Status Item Setup

    private func buildStatusItem() {
        // Start with variableLength; we'll set an explicit length after measuring content.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover)
        button.target  = self

        // Host the SwiftUI label inside the AppKit button.
        // We do NOT pin leading/trailing — that would create a circular sizing constraint.
        // Instead we let the view measure its own intrinsicContentSize and set the
        // status-item length accordingly.
        let label = StatusBarLabel(statsMonitor: statsMonitor, activeModes: activeModes)
        let host  = NSHostingView(rootView: label)
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)

        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        labelHost = host
        updateItemLength()
    }

    /// Measures the hosting view's ideal size and applies it as the status-item length.
    private func updateItemLength() {
        guard let host = labelHost else { return }
        let padding: CGFloat = 16
        let idealWidth = host.fittingSize.width + padding
        statusItem.length = idealWidth
    }

    private func refreshLabel() {
        let label = StatusBarLabel(statsMonitor: statsMonitor, activeModes: activeModes)
        labelHost?.rootView = label
        // Re-measure after content changes (active modes or new values)
        DispatchQueue.main.async { [weak self] in
            self?.updateItemLength()
        }
    }

    // MARK: - Popover Setup

    private func buildPopover() {
        popover.behavior       = .transient
        popover.animates       = true
        popover.contentViewController = NSHostingController(
            rootView: StatsPanel(
                statsMonitor: statsMonitor,
                activeModes: activeModes,
                onToggle: { [weak self] mode in
                    guard let self else { return }
                    if self.activeModes.contains(mode) {
                        if self.activeModes.count > 1 { self.activeModes.remove(mode) }
                    } else {
                        self.activeModes.insert(mode)
                    }
                },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Rebuild with fresh activeModes before showing
            popover.contentViewController = NSHostingController(
                rootView: StatsPanel(
                    statsMonitor: statsMonitor,
                    activeModes: activeModes,
                    onToggle: { [weak self] mode in
                        guard let self else { return }
                        if self.activeModes.contains(mode) {
                            if self.activeModes.count > 1 { self.activeModes.remove(mode) }
                        } else {
                            self.activeModes.insert(mode)
                        }
                        // Rebuild popover after toggle so checkmarks update
                        self.popover.performClose(nil)
                    },
                    onQuit: { NSApplication.shared.terminate(nil) }
                )
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

// MARK: - Status Bar Label (SwiftUI)

/// Renders directly inside NSStatusBarButton via NSHostingView.
/// Free from all MenuBarExtra label constraints — multiple images work fine here.
struct StatusBarLabel: View {
    @ObservedObject var statsMonitor: SystemStatsMonitor
    let activeModes:  Set<DisplayMode>

    private var cpuActive:     Bool { activeModes.contains(.cpuUsage) || activeModes.contains(.cpuTemp) }
    private var showBothCpu:   Bool { activeModes.contains(.cpuUsage) && activeModes.contains(.cpuTemp) }
    private var ramActive:     Bool { activeModes.contains(.ramUsage) }
    private var gpuActive:     Bool { activeModes.contains(.gpuUsage) }
    private var batteryActive: Bool { activeModes.contains(.batteryTemp) }

    // MARK: Threshold colours
    private var cpuUsageColor: Color {
        if statsMonitor.cpuUsage >= 90 { return .red }
        if statsMonitor.cpuUsage >= 50 { return .yellow }
        return .primary
    }
    private var cpuTempColor: Color {
        if statsMonitor.cpuTemperature >= 90 { return .red }
        if statsMonitor.cpuTemperature >= 50 { return .yellow }
        return .primary
    }
    /// When both CPU usage and temp are shown together, pick the more severe colour.
    private var cpuCombinedColor: Color {
        let colors = [cpuUsageColor, cpuTempColor]
        if colors.contains(.red)    { return .red }
        if colors.contains(.yellow) { return .yellow }
        return .primary
    }
    private var ramColor: Color {
        if statsMonitor.ramUsage >= 90 { return .red }
        if statsMonitor.ramUsage >= 50 { return .yellow }
        return .primary
    }
    private var gpuColor: Color {
        if statsMonitor.gpuUsage >= 90 { return .red }
        if statsMonitor.gpuUsage >= 50 { return .yellow }
        return .primary
    }
    private var batteryColor: Color {
        if statsMonitor.batteryTemperature >= 40 { return .red }
        if statsMonitor.batteryTemperature >= 35 { return .yellow }
        return .primary
    }

    var body: some View {
        HStack(spacing: 4) {
            if cpuActive {
                Image(systemName: "cpu")
                if showBothCpu {
                    Text("\(String(format: "%.0f", statsMonitor.cpuUsage))% \(statsMonitor.cpuTemperature)°C")
                        .foregroundColor(cpuCombinedColor)
                } else if activeModes.contains(.cpuUsage) {
                    Text("\(String(format: "%.0f", statsMonitor.cpuUsage))%")
                        .foregroundColor(cpuUsageColor)
                } else {
                    Text("\(statsMonitor.cpuTemperature)°C")
                        .foregroundColor(cpuTempColor)
                }
            }

            if ramActive {
                if cpuActive { divider }
                Image(systemName: "memorychip")
                Text("\(String(format: "%.0f", statsMonitor.ramUsage))%")
                    .foregroundColor(ramColor)
            }

            if gpuActive {
                if cpuActive || ramActive { divider }
                Image(systemName: "square.grid.3x3.topleft.filled")
                Text("\(String(format: "%.0f", statsMonitor.gpuUsage))%")
                    .foregroundColor(gpuColor)
            }

            if batteryActive {
                if cpuActive || ramActive || gpuActive { divider }
                Image(systemName: "battery.100")
                Text("\(String(format: "%.1f", statsMonitor.batteryTemperature))°C")
                    .foregroundColor(batteryColor)
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var divider: some View {
        Text("|").foregroundColor(.secondary).padding(.horizontal, 1)
    }
}


// MARK: - Stats Panel (Popover Content)

struct StatsPanel: View {
    let statsMonitor: SystemStatsMonitor
    let activeModes:  Set<DisplayMode>
    let onToggle: (DisplayMode) -> Void
    let onQuit:   () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardware Monitor")
                .font(.headline)
            Divider()

            Group {
                statRow("CPU Usage",   value: "\(String(format: "%.1f", statsMonitor.cpuUsage))%")
                statRow("CPU Temp",    value: "\(statsMonitor.cpuTemperature)°C")
                statRow("RAM Usage",   value: "\(String(format: "%.1f", statsMonitor.ramUsage))%")
                statRow("GPU Usage",   value: "\(String(format: "%.1f", statsMonitor.gpuUsage))%")
                statRow("Battery Temp",value: "\(String(format: "%.1f", statsMonitor.batteryTemperature))°C")
            }

            Divider()
            Text("Show in menu bar:")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(DisplayMode.allCases) { mode in
                Button(action: { onToggle(mode) }) {
                    HStack {
                        Image(systemName: activeModes.contains(mode) ? "checkmark.square.fill" : "square")
                        Text(mode.rawValue)
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()
            Button("Quit", action: onQuit)
        }
        .padding()
        .frame(width: 240)
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}
