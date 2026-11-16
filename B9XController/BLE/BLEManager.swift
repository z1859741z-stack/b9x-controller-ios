import CoreBluetooth
import Foundation

/// 扫描到的设备。
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

enum BLEConnectionState: String {
    case idle = "未连接"
    case scanning = "扫描中"
    case connecting = "连接中"
    case connected = "已连接"
    case disconnecting = "断开中"
}

/// 底层 BLE：扫描、连接、GATT 发现、FFE1 写、FFE4 通知。
///
/// 对应 Flutter 项目的 Kotlin/WinRT 两端实现 + `ble_bridge.dart` 的通道语义，
/// 用 CoreBluetooth 重写。所有回调都在主队列。
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var connection: BLEConnectionState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published var error: String?
    /// 蓝牙状态中文描述（数据与高级 → 诊断）。
    @Published private(set) var bluetoothState: String = "未知"

    /// 收到 FFE4 通知的原始字节，由上层解析。
    var onData: ((Data) -> Void)?

    /// 中央管理器就绪（蓝牙已开启）时回调。
    var onReady: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private let serviceUUID = CBUUID(string: B9XProtocol.serviceUUID)
    private let writeUUID = CBUUID(string: B9XProtocol.writeCharUUID)
    private let notifyUUID = CBUUID(string: B9XProtocol.notifyCharUUID)

    /// 是否允许断线自动重连（用户主动断开时为 false）。
    var autoReconnectEnabled = true
    private var userDisconnected = false
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?

    private static let lastDeviceKey = "b9x.lastDeviceIdentifier"

    // ------------------------------------------------------------ 下行队列
    // 同类命令（同一 key）合并，只发最新值；每条之间留 45ms 给固件处理。

    private let writeQueue = DispatchQueue(label: "com.b9x.controller.bleWrite")
    private var pending: [(data: Data, key: String?)] = []
    private var pumping = false
    private static let commandGap: TimeInterval = 0.045

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.b9x.controller.central",
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
    }

    // ------------------------------------------------------------ 扫描与连接

    func ensureReady() -> Bool {
        central.state == .poweredOn
    }

    func startScan() {
        error = nil
        devices = []
        guard central.state == .poweredOn else {
            error = "蓝牙未开启"
            return
        }
        connection = .scanning
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() {
        central.stopScan()
        if connection == .scanning {
            connection = .idle
        }
    }

    func connect(_ device: DiscoveredDevice) {
        error = nil
        userDisconnected = false
        reconnectAttempts = 0
        reconnectWorkItem?.cancel()
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            error = "找不到该设备"
            return
        }
        connection = .connecting
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        userDisconnected = true
        reconnectWorkItem?.cancel()
        writeQueue.sync { pending.removeAll() }
        connection = .disconnecting
        if let peripheral = peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            connection = .idle
        }
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)
    }

    /// 启动时自动连上次的设备（iOS 替代“游戏检测自动联动”的一部分：
    /// 打开 App 即恢复上次连接与模式）。
    func autoConnectLastDevice() {
        guard let idString = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let id = UUID(uuidString: idString),
              central.state == .poweredOn else { return }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        userDisconnected = false
        connection = .connecting
        self.peripheral = peripheral
        central.connect(peripheral, options: nil)
    }

    func hasLastDevice() -> Bool {
        UserDefaults.standard.string(forKey: Self.lastDeviceKey) != nil
    }

    // ------------------------------------------------------------ 下行

    func enqueue(_ data: Data, key: String? = nil) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            if let key = key, let index = self.pending.firstIndex(where: { $0.key == key }) {
                self.pending[index] = (data, key)
                return
            }
            self.pending.append((data, key))
            self.pumpLocked()
        }
    }

    func enqueueMany(_ packets: [Data]) {
        for packet in packets {
            enqueue(packet)
        }
    }

    private func pumpLocked() {
        // 只在 writeQueue 上调用。
        guard !pumping, let item = pending.first else { return }
        pumping = true
        pending.removeFirst()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let peripheral = self.peripheral,
               let writeChar = self.writeChar,
               self.connection == .connected {
                peripheral.writeValue(item.data, for: writeChar, type: .withoutResponse)
            }
            self.writeQueue.asyncAfter(deadline: .now() + Self.commandGap) {
                self.pumping = false
                self.pumpLocked()
            }
        }
    }

    // ------------------------------------------------------------ 重连

    private func scheduleReconnect() {
        guard autoReconnectEnabled, !userDisconnected,
              let peripheral = peripheral else { return }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempts, 4))), 30.0)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.userDisconnected,
                  self.connection != .connected else { return }
            self.connection = .connecting
            self.central.connect(peripheral, options: nil)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "已开启"
            onReady?()
        case .poweredOff:
            bluetoothState = "已关闭"
            error = "蓝牙已关闭"
            if connection != .idle { connection = .idle }
        case .unauthorized:
            bluetoothState = "未授权"
            error = "没有蓝牙权限，请在设置里允许"
        case .unsupported:
            bluetoothState = "不支持"
            error = "此设备不支持蓝牙低功耗"
        case .resetting:
            bluetoothState = "重置中"
        case .unknown:
            bluetoothState = "未知"
        @unknown default:
            bluetoothState = "未知"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            self.peripheral = peripheral
            peripheral.delegate = self
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        // 按 B9X 系列名过滤（与 Flutter 端 supportedNames 一致，另放行 Flydigi 前缀）。
        let matched = B9XProtocol.supportedNames.contains(name)
            || name.hasPrefix("Flydigi ")
        guard matched else { return }
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.error = "连接失败：\(error?.localizedDescription ?? "未知错误")"
        connection = .idle
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        writeChar = nil
        notifyChar = nil
        connection = .idle
        if let error = error {
            self.error = "连接已断开：\(error.localizedDescription)"
        }
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            self.error = "发现服务失败：\(error.localizedDescription)"
            connection = .idle
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            self.error = "未找到 FFE0 服务"
            connection = .idle
            return
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            self.error = "发现特征失败：\(error.localizedDescription)"
            connection = .idle
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID {
                writeChar = characteristic
            } else if characteristic.uuid == notifyUUID {
                notifyChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        guard writeChar != nil, notifyChar != nil else {
            self.error = "未找到 FFE1/FFE4 特征"
            connection = .idle
            return
        }
        reconnectAttempts = 0
        connection = .connected
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.uuid == notifyUUID,
              let data = characteristic.value else { return }
        onData?(data)
    }
}
