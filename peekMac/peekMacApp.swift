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

        // Refresh the label every 4 s to match the stats update interval
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
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
        guard let usage = statsMonitor.cpuUsage else { return .secondary }
        if usage >= 90 { return .red }
        if usage >= 50 { return .yellow }
        return .primary
    }
    private var cpuTempColor: Color {
        guard let temp = statsMonitor.cpuTemperature else { return .secondary }
        if temp >= 90 { return .red }
        if temp >= 50 { return .yellow }
        return .primary
    }
    private var ramColor: Color {
        guard let usage = statsMonitor.ramUsage else { return .secondary }
        if usage >= 90 { return .red }
        if usage >= 50 { return .yellow }
        return .primary
    }
    private var gpuColor: Color {
        guard let usage = statsMonitor.gpuUsage else { return .secondary }
        if usage >= 90 { return .red }
        if usage >= 50 { return .yellow }
        return .primary
    }
    private var batteryColor: Color {
        guard let temp = statsMonitor.batteryTemperature else { return .secondary }
        if temp >= 40 { return .red }
        if temp >= 35 { return .yellow }
        return .primary
    }

    var body: some View {
        HStack(spacing: 4) {
            if cpuActive {
                Image(systemName: "cpu")
                if showBothCpu {
                    let usageStr = statsMonitor.cpuUsage != nil ? "\(String(format: "%.0f", statsMonitor.cpuUsage!))%" : "N/A"
                    let tempStr = statsMonitor.cpuTemperature != nil ? "\(statsMonitor.cpuTemperature!)°C" : "N/A"
                    Text(usageStr)
                        .foregroundColor(cpuUsageColor)
                        .frame(width: 30, alignment: .leading)
                    Text(tempStr)
                        .foregroundColor(cpuTempColor)
                        .frame(width: 34, alignment: .leading)
                } else if activeModes.contains(.cpuUsage) {
                    let usageStr = statsMonitor.cpuUsage != nil ? "\(String(format: "%.0f", statsMonitor.cpuUsage!))%" : "N/A"
                    Text(usageStr)
                        .foregroundColor(cpuUsageColor)
                        .frame(width: 30, alignment: .leading)
                } else {
                    let tempStr = statsMonitor.cpuTemperature != nil ? "\(statsMonitor.cpuTemperature!)°C" : "N/A"
                    Text(tempStr)
                        .foregroundColor(cpuTempColor)
                        .frame(width: 34, alignment: .leading)
                }
            }

            if ramActive {
                if cpuActive { divider }
                Image(systemName: "memorychip")
                let ramStr = statsMonitor.ramUsage != nil ? "\(String(format: "%.0f", statsMonitor.ramUsage!))%" : "N/A"
                Text(ramStr)
                    .foregroundColor(ramColor)
                    .frame(width: 30, alignment: .leading)
            }

            if gpuActive {
                if cpuActive || ramActive { divider }
                Image(systemName: "square.grid.3x3.topleft.filled")
                let gpuStr = statsMonitor.gpuUsage != nil ? "\(String(format: "%.0f", statsMonitor.gpuUsage!))%" : "N/A"
                Text(gpuStr)
                    .foregroundColor(gpuColor)
                    .frame(width: 30, alignment: .leading)
            }

            if batteryActive {
                if cpuActive || ramActive || gpuActive { divider }
                Image(systemName: "battery.100")
                let battStr = statsMonitor.batteryTemperature != nil ? "\(String(format: "%.1f", statsMonitor.batteryTemperature!))°C" : "N/A"
                Text(battStr)
                    .foregroundColor(batteryColor)
                    .frame(width: 44, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
    }

    private var divider: some View {
        Text("|").foregroundColor(.secondary).padding(.horizontal, 1)
    }
}


// MARK: - Stats Panel (Popover Content)

struct StatsPanel: View {
    @ObservedObject var statsMonitor: SystemStatsMonitor
    let activeModes:  Set<DisplayMode>
    let onToggle: (DisplayMode) -> Void
    let onQuit:   () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardware Monitor")
                .font(.headline)
            Divider()

            Group {
                statRow("CPU Usage",   value: statsMonitor.cpuUsage != nil ? "\(String(format: "%.1f", statsMonitor.cpuUsage!))%" : "Failed to fetch")
                statRow("CPU Temp",    value: statsMonitor.cpuTemperature != nil ? "\(statsMonitor.cpuTemperature!)°C" : "Failed to fetch")
                statRow("RAM Usage",   value: statsMonitor.ramUsage != nil ? "\(String(format: "%.1f", statsMonitor.ramUsage!))%" : "Failed to fetch")
                statRow("GPU Usage",   value: statsMonitor.gpuUsage != nil ? "\(String(format: "%.1f", statsMonitor.gpuUsage!))%" : "Failed to fetch")
                statRow("Battery Temp",value: statsMonitor.batteryTemperature != nil ? "\(String(format: "%.1f", statsMonitor.batteryTemperature!))°C" : "Failed to fetch")
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
