import Foundation
import CoreBluetooth
import StripProtocol

/// What a scan saw of one device, before any connection.
public struct StripScanResult: Sendable {
    /// CoreBluetooth's per-host identifier. Stable on this Mac, meaningless on
    /// another — these controllers do not expose their MAC address.
    public let identifier: UUID
    public let name: String?
    /// The name from the advertisement, which is sometimes present when the
    /// peripheral's own name is not.
    public let advertisedName: String?
    public let rssi: Int
    public let advertisedServiceUUIDs: [StripUUID]
    public let isConnectable: Bool

    /// The name to show and to match command-line arguments against.
    public var displayName: String { name ?? advertisedName ?? "(unnamed)" }

    public var profile: StripDeviceProfile {
        StripDeviceProfile(name: name ?? advertisedName,
                           advertisedServiceUUIDs: advertisedServiceUUIDs)
    }

    public var candidates: [StripCandidate] { StripIdentifier.identify(profile) }
}

/// One characteristic, as discovered.
public struct StripCharacteristicReport: Sendable {
    public let uuid: StripUUID
    public let properties: CBCharacteristicProperties

    /// The properties spelled out, in the order CoreBluetooth defines them.
    public var propertyNames: [String] {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("write-without-response") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("signed-writes") }
        if properties.contains(.extendedProperties) { names.append("extended") }
        return names
    }

    public var isWritable: Bool {
        properties.contains(.write) || properties.contains(.writeWithoutResponse)
    }

    public var isNotifying: Bool {
        properties.contains(.notify) || properties.contains(.indicate)
    }

    /// Which write CoreBluetooth should use.
    ///
    /// Without-response is preferred wherever the characteristic allows it,
    /// because that is what every one of these protocols uses in practice
    /// (`elkbledom` writes `response=False` unconditionally; `led-ble` and
    /// `lednetwf_ble` do the same) and because a with-response write on a
    /// controller that never answers stalls until it times out.
    public var writeType: CBCharacteristicWriteType? {
        if properties.contains(.writeWithoutResponse) { return .withoutResponse }
        if properties.contains(.write) { return .withResponse }
        return nil
    }
}

/// One service and its characteristics.
public struct StripServiceReport: Sendable {
    public let uuid: StripUUID
    public let isPrimary: Bool
    public let characteristics: [StripCharacteristicReport]
}

/// The full GATT dump — tomorrow's identification evidence.
///
/// This is the artefact the whole bring-up hangs on: the advertised name is
/// ambiguous across families, but the characteristic set is not. It is a value
/// type with no CoreBluetooth objects in it so that it can be printed, kept
/// after disconnecting, and fed to ``StripIdentifier`` unchanged.
public struct StripDeviceReport: Sendable {
    public let identifier: UUID
    public let name: String?
    public let advertisedName: String?
    public let rssi: Int?
    public let advertisedServiceUUIDs: [StripUUID]
    public let services: [StripServiceReport]

    public var displayName: String { name ?? advertisedName ?? "(unnamed)" }

    public var allCharacteristicUUIDs: [StripUUID] {
        services.flatMap { $0.characteristics.map(\.uuid) }
    }

    public var profile: StripDeviceProfile {
        StripDeviceProfile(name: name ?? advertisedName,
                           advertisedServiceUUIDs: advertisedServiceUUIDs,
                           serviceUUIDs: services.map(\.uuid),
                           characteristicUUIDs: allCharacteristicUUIDs)
    }

    public var candidates: [StripCandidate] { StripIdentifier.identify(profile) }

    /// Finds a characteristic by UUID, wherever in the tree it sits.
    public func characteristic(_ uuid: StripUUID) -> StripCharacteristicReport? {
        services.lazy.compactMap { $0.characteristics.first { $0.uuid == uuid } }.first
    }

    /// The first of a family's candidate write characteristics that this device
    /// actually exposes and can actually be written to.
    public func writeCharacteristic(for family: StripFamily) -> StripCharacteristicReport? {
        for uuid in family.gatt.writeCharacteristics {
            if let found = characteristic(uuid), found.isWritable { return found }
        }
        return nil
    }

    public func notifyCharacteristic(for family: StripFamily) -> StripCharacteristicReport? {
        for uuid in family.gatt.notifyCharacteristics {
            if let found = characteristic(uuid), found.isNotifying { return found }
        }
        return nil
    }

    /// A human-readable dump, for `strip report`.
    public func formatted() -> String {
        var lines: [String] = []
        lines.append("device")
        lines.append("  name:         \(displayName)")
        if let advertisedName, advertisedName != name {
            lines.append("  adv name:     \(advertisedName)")
        }
        lines.append("  identifier:   \(identifier.uuidString)")
        if let rssi { lines.append("  rssi:         \(rssi) dBm") }
        lines.append("  advertised:   "
            + (advertisedServiceUUIDs.isEmpty
                ? "(no service UUIDs)"
                : advertisedServiceUUIDs.map(\.shortDescription).joined(separator: ", ")))

        lines.append("")
        lines.append("gatt")
        if services.isEmpty {
            lines.append("  (no services discovered)")
        }
        for service in services {
            lines.append("  service \(service.uuid.shortDescription)"
                + (service.isPrimary ? "" : "  (secondary)"))
            if service.characteristics.isEmpty {
                lines.append("    (no characteristics)")
            }
            for characteristic in service.characteristics {
                // Padded to the width of a 16-bit UUID, never truncated — the
                // vendor UUIDs are 36 characters and are the interesting ones.
                let uuid = characteristic.uuid.shortDescription
                let padded = uuid.count >= 4 ? uuid
                    : uuid + String(repeating: " ", count: 4 - uuid.count)
                lines.append("    char \(padded)  ["
                    + characteristic.propertyNames.joined(separator: ", ") + "]")
            }
        }

        lines.append("")
        lines.append("identification")
        let ranked = candidates.filter { $0.score > 0 }
        if ranked.isEmpty {
            lines.append("  no family matched. The full dump above is the evidence — compare")
            lines.append("  it against the service and characteristic tables in")
            lines.append("  StripFamily.gatt before writing anything.")
        }
        for candidate in ranked {
            let label = candidate.confidence.rawValue
            let padded = label + String(repeating: " ", count: max(0, 9 - label.count))
            lines.append("  \(padded) \(candidate.family.displayName)")
            for reason in candidate.reasons {
                lines.append("            - \(reason)")
            }
            if !candidate.family.framesAvailable {
                lines.append("            ! identification only; this project does not "
                             + "write to this family")
            }
        }
        return lines.joined(separator: "\n")
    }
}
