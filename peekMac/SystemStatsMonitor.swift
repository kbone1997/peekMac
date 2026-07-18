import Foundation
import MachO
import IOKit
import Combine

class SystemStatsMonitor: ObservableObject {
    @Published var cpuUsage: Double?
    @Published var cpuTemperature: Int?
    @Published var ramUsage: Double?
    @Published var gpuUsage: Double?
    @Published var batteryTemperature: Double?
    
    private var timer: Timer?
    private var prevCpuInfo: processor_info_array_t?
    private var prevCpuInfoCount: mach_msg_type_number_t
    
    init() {
        // Phase 1: Provide concrete primitive values to all stored properties first
        self.cpuUsage = nil
        self.cpuTemperature = nil
        self.ramUsage = nil
        self.gpuUsage = nil
        self.batteryTemperature = nil
        
        self.prevCpuInfo = nil
        self.prevCpuInfoCount = 0
        self.timer = nil // Initialized as nil to satisfy Phase 1 rules
        
        // Phase 2: Now that initialization is complete, calling self methods is 100% legal!
        updateStats()
        
        // Set up the scheduled timer safely using a weak reference to self
        self.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }
    
    private func updateStats() {
        self.cpuUsage = getCPUUsage()
        self.cpuTemperature = getCPUTemperature()
        self.ramUsage = getRAMUsage()
        self.gpuUsage = getGPUUsage()
        self.batteryTemperature = getBatteryTemperature()
    }
    
    // 1. CPU Usage Calculation
    private func getCPUUsage() -> Double? {
        var processorInfo: processor_info_array_t?
        var processorMsgCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &processorInfo, &processorMsgCount)
        guard result == KERN_SUCCESS, let cpuInfo = processorInfo else { return nil }
        
        var totalUsage: Double = 0.0
        var hasHistory = false
        if let prevInfo = prevCpuInfo {
            for i in 0..<Int(processorCount) {
                let base = i * Int(CPU_STATE_MAX)
                let user = cpuInfo[base + Int(CPU_STATE_USER)] - prevInfo[base + Int(CPU_STATE_USER)]
                let system = cpuInfo[base + Int(CPU_STATE_SYSTEM)] - prevInfo[base + Int(CPU_STATE_SYSTEM)]
                let idle = cpuInfo[base + Int(CPU_STATE_IDLE)] - prevInfo[base + Int(CPU_STATE_IDLE)]
                let nice = cpuInfo[base + Int(CPU_STATE_NICE)] - prevInfo[base + Int(CPU_STATE_NICE)]
                
                let active = Double(user + system + nice)
                let total = active + Double(idle)
                if total > 0 { totalUsage += (active / total) * 100.0 }
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevInfo), vm_size_t(prevCpuInfoCount))
            hasHistory = true
        }
        
        prevCpuInfo = cpuInfo
        prevCpuInfoCount = processorMsgCount
        return hasHistory ? (totalUsage / Double(processorCount)) : nil
    }
    
    // 2. CPU Temperature SMC Reader
    private func getCPUTemperature() -> Int? {
        if let connection = openSMC() {
            defer { closeSMC(connection) }
            
            // Candidate keys for Apple Silicon Macs
            let keys = ["TCMz", "Tp09", "Tp0T"]
            
            for keyStr in keys {
                let key = getSMCKey(keyStr)
                if let keyInfo = getSMCKeyInfo(connection: connection, key: key) {
                    if let bytes = readSMCValue(connection: connection, key: key, keyInfo: keyInfo) {
                        if let temp = parseTemperature(bytes: bytes, type: keyInfo.dataType) {
                            if temp > 10.0 && temp < 120.0 {
                                return Int(round(temp))
                            }
                        }
                    }
                }
            }
        }
        return nil
    }
    
    // MARK: - SMC Private Helpers & Structures
    
    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    
    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    
    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }
    
    private func getSMCKey(_ keyString: String) -> UInt32 {
        guard keyString.count == 4 else { return 0 }
        var value: UInt32 = 0
        for char in keyString.utf8 {
            value = (value << 8) + UInt32(char)
        }
        return value
    }
    
    private func openSMC() -> io_connect_t? {
        let matchingService = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(0, matchingService)
        guard service != 0 else { return nil }
        
        var connection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        
        guard result == kIOReturnSuccess else { return nil }
        return connection
    }
    
    private func closeSMC(_ connection: io_connect_t) {
        IOServiceClose(connection)
    }
    
    private func getSMCKeyInfo(connection: io_connect_t, key: UInt32) -> SMCKeyInfoData? {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = 9 // kSMCGetKeyInfo
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        
        let result = IOConnectCallStructMethod(
            connection,
            2, // selector: kSMCHandleYPCEvent
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        
        if result == kIOReturnSuccess && output.result == 0 {
            return output.keyInfo
        }
        return nil
    }
    
    private func readSMCValue(connection: io_connect_t, key: UInt32, keyInfo: SMCKeyInfoData) -> [UInt8]? {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo = keyInfo
        input.data8 = 5 // kSMCReadKey
        
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        
        let result = IOConnectCallStructMethod(
            connection,
            2, // selector: kSMCHandleYPCEvent
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        
        if result == kIOReturnSuccess && output.result == 0 {
            let size = Int(keyInfo.dataSize)
            return withUnsafePointer(to: output.bytes) { ptr -> [UInt8] in
                ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { bytePtr in
                    Array(UnsafeBufferPointer(start: bytePtr, count: size))
                }
            }
        }
        return nil
    }
    
    private func parseTemperature(bytes: [UInt8], type: UInt32) -> Double? {
        if type == 0x73703738 && bytes.count >= 2 { // sp78
            let sign = (bytes[0] & 0x80) != 0
            var value = Int(bytes[0] & 0x7F) << 8 | Int(bytes[1])
            if sign {
                value = -value
            }
            return Double(value) / 256.0
        } else if type == 0x666c7420 && bytes.count >= 4 { // flt 
            var floatVal: Float = 0.0
            let data = Data(bytes)
            floatVal = data.withUnsafeBytes { $0.load(as: Float.self) }
            return Double(floatVal)
        } else if type == 0x66706532 && bytes.count >= 2 { // fpe2
            let value = Int(bytes[0]) << 8 | Int(bytes[1])
            return Double(value) / 4.0
        } else if type == 0x75693136 && bytes.count >= 2 { // ui16
            let value = Int(bytes[0]) << 8 | Int(bytes[1])
            return Double(value)
        } else if type == 0x75693820 && bytes.count >= 1 { // ui8
            return Double(bytes[0])
        }
        return nil
    }

    
    // 3. RAM Usage Calculation
    private func getRAMUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        
        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let wire = UInt64(stats.wire_count) * pageSize
        
        let usedMemory = Double(active + compressed + wire)
        let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
        return (usedMemory / totalMemory) * 100.0
    }
    
    // 4. GPU Engine Usage Calculation via IOKit PerformanceStatistics
    private func getGPUUsage() -> Double? {
        let matchingDict = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(0, matchingDict, &iterator)
        guard result == kIOReturnSuccess, iterator != 0 else { return nil }
        defer { IOObjectRelease(iterator) }
        
        var service = IOIteratorNext(iterator)
        var usage: Double = 0.0
        var found = false
        
        while service != 0 {
            if !found {
                if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                    if let devUtil = stats["Device Utilization %"] as? NSNumber {
                        usage = devUtil.doubleValue
                        found = true
                    } else if let renderUtil = stats["Renderer Utilization %"] as? NSNumber {
                        usage = renderUtil.doubleValue
                        found = true
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        
        if found {
            return min(max(usage, 0.0), 100.0)
        }
        return nil
    }
    
    // 5. Battery Temperature via Native IOKit
    private func getBatteryTemperature() -> Double? {
        // 0 represents the primary Mach platform IO root port mapping
        let matchingService = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(0, matchingService)
        
        if service != 0 {
            if let properties = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0) {
                let rawTemp = properties.takeRetainedValue() as? Double ?? 0.0
                IOObjectRelease(service)
                // AppleSmartBattery stores temperature scaled up by 100 (e.g., 2850 = 28.5°C)
                if rawTemp > 0 { return rawTemp / 100.0 }
            }
            IOObjectRelease(service)
        }
        return nil
    }
    
}

