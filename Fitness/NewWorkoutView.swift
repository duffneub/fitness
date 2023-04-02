//
//  NewWorkoutView.swift
//  Fitness
//
//  Created by Duff Neubauer on 3/9/23.
//

import CoreBluetooth
import SwiftUI

struct Sample: Equatable, Codable, Hashable {
    let date: Date
    let metric: Workout.Metric
    let value: Int
    
    init(metric: Workout.Metric, value: Int) {
        self.date = Date()
        self.metric = metric
        self.value = value
    }
}

class WorkoutBuilder: ObservableObject {
    
    enum Status {
        case ready
        case inProgress
        case paused
        case complete
    }
    
    let activity: Activity
    
    @Published var samples: [Sample] = []
    @Published private(set) var duration: Duration = .milliseconds(0)
    @Published private(set) var status: Status = .ready
    
    private var start: Date?
    private var accumulatedTime: Duration =  .milliseconds(0)
    private var timer: Timer?
    
    init(activity: Activity) {
        self.activity = activity
    }
    
    func startWorkout() {
        guard start == nil else { return }
        let now = Date()
        start = now
        
        timer = .scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let seconds = Date().timeIntervalSince(now)
            self.duration = self.accumulatedTime + .seconds(seconds)
        }
        status = .inProgress
    }
    
    func pause() {
        timer?.invalidate()
        accumulatedTime = duration
        status = .paused
    }
    
    func resume() {
        let now = Date()
        
        timer = .scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let seconds = Date().timeIntervalSince(now)
            self.duration = self.accumulatedTime + .seconds(seconds)
        }
        status = .inProgress
    }
    
    func stopWorkout() -> Workout {
        status = .complete
        return Workout(activity: activity, start: start!, end: Date(), activeDuration: duration, samples: samples)
    }
    
}

struct NewWorkoutView: View {
    
    @Environment(\.addWorkout) var addWorkout
    
    @Environment(\.isPresented) var isPresented
    @Environment(\.dismiss) var dismiss
    
    @ObservedObject private var builder: WorkoutBuilder
    let bluetoothStore: BluetoothStore
    
    @State private var selectedPeripherals: [CBUUID: CBPeripheral] = [:]
    
    init(activity: Activity, bluetoothStore: BluetoothStore) {
        builder = .init(activity: activity)
        self.bluetoothStore = bluetoothStore
    }
    
    var body: some View {
        VStack {
            List {
                HStack {
                    Text("Duration")
                        .font(.headline)
                    Spacer()
                    Text(builder.duration.formatted())
                }
                
                WorkoutMetricView(bluetoothStore: bluetoothStore, samples: $builder.samples, selectedPeripherals: $selectedPeripherals, metric: .heartRate)
                
                WorkoutMetricView(bluetoothStore: bluetoothStore, samples: $builder.samples, selectedPeripherals: $selectedPeripherals, metric: .power)
            }
            
            Spacer()
            
            Group {
                switch builder.status {
                case .ready:
                    Button("Start") {
                        builder.startWorkout()
                    }
                case .inProgress:
                    Button("Pause") {
                        builder.pause()
                    }
                case .paused:
                    HStack {
                        Button("Resume") {
                            builder.resume()
                        }
                        .buttonStyle(BorderedButtonStyle())
                        
                        Button("Stop") {
                            let workout = builder.stopWorkout()
                            addWorkout(workout)
                            
                            if isPresented {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(0.3))
                                    dismiss()
                                }
                            }
                        }
                    }
                case .complete:
                    EmptyView()
                }
            }
            .buttonStyle(BorderedProminentButtonStyle())
            .controlSize(.large)
        }
        .navigationTitle(builder.activity.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Dismiss") {
                    selectedPeripherals.values.forEach { peripheral in
                        Task {
                            if selectedPeripherals[CBUUID.Service.heartRate] != nil,
                               let service = peripheral.services?.first(where: { $0.uuid == CBUUID.Service.heartRate }),
                               let char = service.characteristics?.first(where: { $0.uuid == CBUUID.Characteristic.heartRateMeasurement })
                            {
                                print("Stop observing \(char.description) of \(peripheral.name!)")
                                peripheral.setNotifyValue(false, for: char)
                            }
                            if selectedPeripherals[CBUUID.Service.cyclingPower] != nil,
                               let service = peripheral.services?.first(where: { $0.uuid == CBUUID.Service.cyclingPower }),
                               let char = service.characteristics?.first(where: { $0.uuid == CBUUID.Characteristic.cyclingPowerMeasurement })
                            {
                                print("Stop observing \(char.description) of \(peripheral.name!)")
                                peripheral.setNotifyValue(false, for: char)
                            }
                            try? await bluetoothStore.cancelPeripheralConnection(peripheral)
                            
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct WorkoutMetricView: View {
    
    let bluetoothStore: BluetoothStore
    @Binding var samples: [Sample]
    @Binding var selectedPeripherals: [CBUUID: CBPeripheral]
    let metric: Workout.Metric
    
    var body: some View {
        NavigationLink {
            FindDevicesView(services: [metric.serviceID], selection: $selectedPeripherals, bluetoothStore: bluetoothStore)
        } label: {
            if let peripheral = selectedPeripherals[metric.serviceID] {
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(metric.title)")
                            .font(.headline)
                        Text(peripheral.name!)
                            .font(.caption)
                    }
                    Spacer()
                    
                    CharacteristicView(
                        peripheral: .init(peripheral),
                        service: metric.serviceID,
                        characteristic: metric.characteristicID,
                        bluetoothStore: bluetoothStore
                    ) { value in
                        if let v = metric.format(value) {
                            samples.append(.init(metric: metric, value: v))
                        }

                        return metric.description(value)
                    }
                }
            } else {
                HStack {
                    Text("\(metric.title)")
                        .font(.headline)
                    Spacer()
                    
                    Text("Search")
                }
            }
        }
    }
    
}

extension Workout {
    
    enum Metric: Equatable, Codable, Hashable {
        case heartRate
        case power
    }
    
}

extension Workout.Metric {
    
    var title: String {
        switch self {
        case .heartRate:
            return "Heart Rate"
        case .power:
            return "Power"
        }
    }
    
}

extension Workout.Metric {
    
    var serviceID: CBUUID {
        switch self {
        case .heartRate:
            return CBUUID.Service.heartRate
        case .power:
            return CBUUID.Service.cyclingPower
        }
    }
    
    var characteristicID: CBUUID {
        switch self {
        case .heartRate:
            return CBUUID.Characteristic.heartRateMeasurement
        case .power:
            return CBUUID.Characteristic.cyclingPowerMeasurement
        }
    }
    
    func format(_ value: Data?) -> Int? {
        switch self {
        case .heartRate:
            guard let value = value, let flags = value.first else { return nil }

            let is16Bit = (flags & 0b10000000) != 0
            let bpm = is16Bit
                ? Int(value[1...2].withUnsafeBytes { $0.load(as: UInt16.self) })
                : Int(value[1])
            
            print("value: \(value)")
            print("flags: \(flags)")
            print("is16Bit: \(is16Bit)")
            
            print("\(title):")
            for duff in value.enumerated() {
                print("value[\(duff.offset)] = \(duff.element)")
            }
            print("")
            
            return bpm
        case .power:
            guard let value = value else { return nil }
            
            let power = Int(value[2...3].withUnsafeBytes { $0.load(as: UInt16.self) })
            
            print("\(title):")
            for duff in value.enumerated() {
                print("value[\(duff.offset)] = \(duff.element)")
            }
            print("")
            
            return power
        }
    }
    
    func description(_ value: Data?) -> String {
        switch self {
        case .heartRate:
            return format(value).map { "\($0) bpm" } ?? "--"
        case .power:
            return format(value).map { "\($0) watts" } ?? "--"
        }
    }
    
}

struct CharacteristicView: View {
    
    let peripheral: Peripheral
    let service: CBUUID
    let characteristic: CBUUID
    let bluetoothStore: BluetoothStore
    let formatter: (Data?) -> String
    
    @State private var value: String = "--"
    
    var body: some View {
        Text(value)
            .task {
                do {
                    let service = try await peripheral.discoverServices([service])
                        .first(where: { $0.uuid == self.service })!
                    let characteristic = try await peripheral.discoverCharacteristics([characteristic], for: service)
                        .first(where: { $0.uuid == self.characteristic })!
                    for try await value in peripheral.value(for: characteristic) {
                        self.value = formatter(value)
                    }
                } catch {
                    print("Failed -- \(error)")
                }
            }
    }
    
}

struct FindDevicesView: View {
    
    let services: [CBUUID]
    @Binding var selection: [CBUUID: CBPeripheral]
    let bluetoothStore: BluetoothStore
    
    @State private var peripheralMap: [UUID: CBPeripheral] = [:]
    
    var peripherals: [CBPeripheral] {
        Array(peripheralMap.values)
    }
    
    var body: some View {
        List(peripherals, id: \.identifier) { peripheral in
            Button {
                Task {
                    
                    if peripheral.state == .disconnected {
                        do {
                            try await bluetoothStore.connect(peripheral)
                            selection[services.first!] = peripheral
                        } catch {
                            print("Failed to connect to '\(peripheral.name!)' -- \(error)")
                        }
                    } else {
                        do {
                            try await bluetoothStore.cancelPeripheralConnection(peripheral)
                            selection[services.first!] = nil
                        } catch {
                            print("Failed to connect to '\(peripheral.name!)' -- \(error)")
                        }
                    }
                }
            } label: {
                HStack {
                    Text(peripheral.name!)
                    Spacer()
                    
                    switch peripheral.state {
                    case .disconnected:
                        EmptyView()
                    case .connecting:
                        ProgressView()
                    case .connected:
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    case .disconnecting:
                        EmptyView()
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            .foregroundColor(.primary)
                
        }
        .navigationTitle("Devices…")
        .task {
            for await peripheral in bluetoothStore.peripherals(withServices: services) {
                peripheralMap[peripheral.identifier] = peripheral
            }
        }
    }
    
}

struct Sensor: Identifiable {
    
    enum Service {
        case heartRate
    }
    
    enum State {
        case disconnected
        case connecting
        case connected
        case disconnecting
    }
    
    let id: UUID
    let name: String
    let services: [Service]
    
    var state: State = .disconnected
    
}

extension Sensor: Equatable {}
extension Sensor.Service: Equatable {}

// MARK: - Preview

//struct NewWorkoutView_Previews: PreviewProvider {
//    static var previews: some View {
//        NavigationStack {
//            NewWorkoutView(activity: .indoorRide)
//        }
//        .onAddWorkout { _ in }
//        .sensorStore(.preview)
//    }
//}
//
//struct PreviewSensorStore: SensorStore {
//
//    let sensors: [Sensor] = [
//        Sensor(id: UUID(), name: "Wahoo Tickr", services: [.heartRate]),
//        Sensor(id: UUID(), name: "Polar H9", services: [.heartRate]),
//        Sensor(id: UUID(), name: "Scosche Rhythm24", services: [.heartRate]),
//    ]
//
//    func sensors(withServices services: ([Sensor.Service])) -> AsyncStream<Sensor> {
//        var iterator = sensors.makeIterator()
//
//        return AsyncStream {
//            try? await Task.sleep(for: .seconds(1))
//            return iterator.next()
//        }
//    }
//
//    func connect(to sensor: Sensor) async throws {
//        try await Task.sleep(for: .seconds(1))
//    }
//
//    func disconnect(from sensor: Sensor) async throws {
//        try await Task.sleep(for: .seconds(1))
//    }
//
//}
//
//extension SensorStore where Self == PreviewSensorStore {
//
//    static var preview: Self { Self() }
//
//}
