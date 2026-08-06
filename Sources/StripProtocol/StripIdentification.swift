import Foundation

/// What a device looks like from the outside, before anything is written to it.
///
/// Two of these fields come from an advertisement and can be had from a scan
/// alone; ``characteristicUUIDs`` needs a connection and a service discovery.
/// Identification works with whatever is present, and says so — the ranking is
/// much sharper once characteristics are known, which is exactly why
/// `strip report` exists as its own command.
public struct StripDeviceProfile: Sendable, Equatable {
    public let name: String?
    public let advertisedServiceUUIDs: [StripUUID]
    public let serviceUUIDs: [StripUUID]
    public let characteristicUUIDs: [StripUUID]

    public init(name: String?,
                advertisedServiceUUIDs: [StripUUID] = [],
                serviceUUIDs: [StripUUID] = [],
                characteristicUUIDs: [StripUUID] = []) {
        self.name = name
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
        self.serviceUUIDs = serviceUUIDs
        self.characteristicUUIDs = characteristicUUIDs
    }

    /// Whether a connection has happened — i.e. whether the strong evidence is
    /// available at all.
    public var isPostDiscovery: Bool { !characteristicUUIDs.isEmpty }
}

/// One ranked guess at what a device is.
public struct StripCandidate: Sendable, Equatable {
    public let family: StripFamily
    public let score: Int
    /// Why, in the order the evidence was weighed. Printed by `strip scan`, so
    /// each entry is a phrase that reads in a list.
    public let reasons: [String]

    /// How much to trust this, given both the score and whether the strong
    /// evidence was even available.
    public enum Confidence: String, Sendable {
        /// A write characteristic unique to one family was found.
        case confirmed
        /// Several signals agree, or one strong one without corroboration.
        case likely
        /// A name prefix and nothing else, or a characteristic several families
        /// share.
        case possible
        /// Nothing matched; this family is listed only because `try-all` will
        /// reach it anyway.
        case guess
    }

    public var confidence: Confidence {
        switch score {
        case 100...: return .confirmed
        case 50..<100: return .likely
        case 10..<50: return .possible
        default: return .guess
        }
    }
}

/// Ranks controller families against what was observed of a device.
///
/// ## Why characteristics outrank names
///
/// Advertised names are the obvious signal and the unreliable one. `LEDBLE-`
/// devices exist in both the ELK and the Triones ecosystems with incompatible
/// wire formats; `QHM-` is a Triones device that looks like nothing; the ELK
/// controllers advertise the HID service `0x1812`, which they do not implement,
/// and do not advertise `FFF0`, which they do. Meanwhile a `D44BC439-…`
/// characteristic means iDeal LED and can mean nothing else, and `FF01`+`FF02`
/// under service `FFFF` means LEDnetWF and can mean nothing else.
///
/// So the weights are: a write characteristic that only one family uses is
/// decisive; one shared by several is worth something to each; a name prefix
/// breaks the resulting tie; an advertised service barely counts.
public enum StripIdentifier {

    /// Scores, chosen so that the confidence bands in ``StripCandidate`` fall
    /// where they read correctly.
    enum Weight {
        /// A write characteristic no other family claims.
        static let uniqueWriteCharacteristic = 100
        /// A write characteristic several families claim.
        static let sharedWriteCharacteristic = 35
        /// A notify characteristic match.
        static let notifyCharacteristic = 15
        /// The advertised name starts with one of the family's prefixes.
        static let namePrefix = 40
        /// A discovered (not merely advertised) service.
        static let service = 20
        /// An advertised service. Weak: the ELK controllers advertise a service
        /// they do not implement and omit the one they do.
        static let advertisedService = 8
    }

    /// Ranks every family, best first.
    ///
    /// Families that scored nothing are included at the end, so that a caller
    /// showing "the candidates" and a caller running `try-all` are working from
    /// the same list. Ties break toward ``StripFamily/tryAllOrder``, which puts
    /// the commonest hardware first.
    public static func identify(_ profile: StripDeviceProfile) -> [StripCandidate] {
        let characteristics = Set(profile.characteristicUUIDs)
        let services = Set(profile.serviceUUIDs)
        let advertised = Set(profile.advertisedServiceUUIDs)
        let name = (profile.name ?? "").uppercased()

        // How many families claim each write characteristic, so that FFE1 —
        // claimed by LEDBLE, JACKYLED and SP alike — cannot masquerade as proof.
        var claimants: [StripUUID: Int] = [:]
        for family in StripFamily.allCases {
            for uuid in Set(family.gatt.writeCharacteristics) {
                claimants[uuid, default: 0] += 1
            }
        }

        var candidates: [StripCandidate] = StripFamily.allCases.map { family in
            var score = 0
            var reasons: [String] = []
            let gatt = family.gatt

            for uuid in gatt.writeCharacteristics where characteristics.contains(uuid) {
                let isUnique = claimants[uuid] == 1
                score += isUnique ? Weight.uniqueWriteCharacteristic
                                  : Weight.sharedWriteCharacteristic
                reasons.append(isUnique
                    ? "write characteristic \(uuid) is used by no other family"
                    : "write characteristic \(uuid) matches (shared with "
                      + "\((claimants[uuid] ?? 1) - 1) other famil"
                      + ((claimants[uuid] ?? 1) - 1 == 1 ? "y)" : "ies)"))
            }
            for uuid in gatt.notifyCharacteristics where characteristics.contains(uuid) {
                score += Weight.notifyCharacteristic
                reasons.append("notify characteristic \(uuid) matches")
            }
            for uuid in gatt.services where services.contains(uuid) {
                score += Weight.service
                reasons.append("service \(uuid) present")
            }
            for uuid in gatt.services where advertised.contains(uuid) && !services.contains(uuid) {
                score += Weight.advertisedService
                reasons.append("service \(uuid) advertised")
            }
            if let prefix = family.namePrefixes.first(where: { name.hasPrefix($0) }) {
                score += Weight.namePrefix
                reasons.append("name starts with \"\(prefix)\"")
            }
            return StripCandidate(family: family, score: score, reasons: reasons)
        }

        let order = Dictionary(uniqueKeysWithValues:
            StripFamily.allCases.enumerated().map { ($0.element, rank(of: $0.element)) })
        candidates.sort {
            $0.score != $1.score ? $0.score > $1.score
                                 : (order[$0.family] ?? 99) < (order[$1.family] ?? 99)
        }
        return candidates
    }

    /// The best guess, or `nil` when nothing scored at all.
    public static func bestGuess(_ profile: StripDeviceProfile) -> StripCandidate? {
        identify(profile).first { $0.score > 0 }
    }

    private static func rank(of family: StripFamily) -> Int {
        StripFamily.tryAllOrder.firstIndex(of: family) ?? StripFamily.tryAllOrder.count
    }
}
