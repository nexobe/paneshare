import Crypto
import Foundation

/// Ad-hoc code signing of a thin 64-bit Mach-O executable, in process, so generating a Dock
/// helper never runs `codesign`. Written from Apple's published format (xnu
/// `osfmk/kern/cs_blobs.h`, `EXTERNAL_HEADERS/mach-o/loader.h`): one SuperBlob holding a version
/// 0x20400 CodeDirectory (SHA-256, 4 KiB pages), an empty requirement set and an empty CMS slot,
/// which is what an ad-hoc signature is. The executable must already reserve a code-signature
/// load command (the linker's own ad-hoc signature, or `-adhoc_codesign`); fat files are refused.
public enum AdHocSigner {
    public enum Failure: Error, Equatable, Sendable {
        case notMachO
        case fatBinary
        case noSignatureCommand
        case malformed(String)
    }

    public struct Signed: Sendable {
        public let executable: Data
        /// The first 20 bytes of the CodeDirectory's SHA-256: what `cdhash H"…"` requirements match.
        public let cdhash: [UInt8]
        public var cdhashHex: String { cdhash.map { String(format: "%02x", $0) }.joined() }
    }

    static let pageShift: UInt8 = 12
    static let pageSize = 1 << 12
    static let linkeditAlignment: UInt64 = 0x4000

    static let superBlobMagic: UInt32 = 0xFADE_0CC0
    static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
    static let requirementsMagic: UInt32 = 0xFADE_0C01
    static let blobWrapperMagic: UInt32 = 0xFADE_0B01
    static let codeDirectoryVersion: UInt32 = 0x20400
    static let adhocFlag: UInt32 = 0x0002
    static let mainBinaryExecSegFlag: UInt64 = 0x1
    static let codeDirectoryHeaderSize = 88

    enum Slot {
        static let codeDirectory: UInt32 = 0
        static let infoPlist = 1
        static let requirements: UInt32 = 2
        static let resources = 3
        static let cms: UInt32 = 0x10000
    }

    /// - Parameters:
    ///   - identifier: the signing identifier; use the bundle identifier.
    ///   - infoPlist: the exact bytes of `Contents/Info.plist`, bound in special slot 1.
    ///   - codeResources: the exact bytes of `Contents/_CodeSignature/CodeResources`, slot 3.
    public static func sign(executable: Data, identifier: String, infoPlist: Data?, codeResources: Data?) throws -> Signed {
        var image = MachOImage(bytes: [UInt8](executable))
        try image.parse()
        guard let signature = image.signatureCommand, let linkedit = image.linkedit, let text = image.text else {
            throw Failure.noSignatureCommand
        }
        let codeLimit = Int(image.u32(signature + 8))
        guard codeLimit % 16 == 0, codeLimit <= image.bytes.count,
              UInt64(codeLimit) >= image.u64(linkedit + 40) else { throw Failure.malformed("signature offset") }

        let requirements = blob(requirementsMagic, payload: be32(0))
        let cms = blob(blobWrapperMagic, payload: [])
        let ident = Array(identifier.utf8) + [0]
        let specialSlots = 3
        let codeSlots = (codeLimit + pageSize - 1) / pageSize
        let cdLength = codeDirectoryHeaderSize + ident.count + 32 * (specialSlots + codeSlots)
        let indexCount = 3
        let superLength = 12 + 8 * indexCount + cdLength + requirements.count + cms.count
        let reserved = (superLength + 15) & ~15

        // Patch the load commands before hashing: page 0 holds them.
        var bytes = Array(image.bytes[0..<codeLimit])
        image.bytes = bytes
        image.put32(UInt32(reserved), at: signature + 12)
        let linkeditFileoff = image.u64(linkedit + 40)
        let linkeditSize = UInt64(codeLimit + reserved) - linkeditFileoff
        image.put64(linkeditSize, at: linkedit + 48)
        image.put64((linkeditSize + linkeditAlignment - 1) & ~(linkeditAlignment - 1), at: linkedit + 32)
        bytes = image.bytes

        var special = [[UInt8]](repeating: [UInt8](repeating: 0, count: 32), count: specialSlots)
        if let infoPlist { special[Slot.infoPlist - 1] = Array(SHA256.hash(data: infoPlist)) }
        special[Int(Slot.requirements) - 1] = Array(SHA256.hash(data: requirements))
        if let codeResources { special[Slot.resources - 1] = Array(SHA256.hash(data: codeResources)) }

        var cd: [UInt8] = []
        cd += be32(codeDirectoryMagic)
        cd += be32(UInt32(cdLength))
        cd += be32(codeDirectoryVersion)
        cd += be32(adhocFlag)
        cd += be32(UInt32(codeDirectoryHeaderSize + ident.count + 32 * specialSlots)) // hashOffset
        cd += be32(UInt32(codeDirectoryHeaderSize)) // identOffset
        cd += be32(UInt32(specialSlots))
        cd += be32(UInt32(codeSlots))
        cd += be32(UInt32(codeLimit))
        cd += [32, 2, 0, pageShift] // hashSize, hashType SHA-256, platform, pageSize
        cd += be32(0) // spare2
        cd += be32(0) // scatterOffset
        cd += be32(0) // teamOffset
        cd += be32(0) // spare3
        cd += be64(0) // codeLimit64
        cd += be64(image.u64(text + 40)) // execSegBase = __TEXT fileoff
        cd += be64(image.u64(text + 48)) // execSegLimit = __TEXT filesize
        cd += be64(mainBinaryExecSegFlag)
        precondition(cd.count == codeDirectoryHeaderSize)
        cd += ident
        for slot in stride(from: specialSlots, through: 1, by: -1) { cd += special[slot - 1] }
        var page = 0
        while page < codeLimit {
            cd += Array(SHA256.hash(data: bytes[page..<min(page + pageSize, codeLimit)]))
            page += pageSize
        }
        precondition(cd.count == cdLength)

        var superBlob: [UInt8] = []
        superBlob += be32(superBlobMagic)
        superBlob += be32(UInt32(superLength))
        superBlob += be32(UInt32(indexCount))
        var offset = 12 + 8 * indexCount
        for (type, part) in [(Slot.codeDirectory, cd), (Slot.requirements, requirements), (Slot.cms, cms)] {
            superBlob += be32(type) + be32(UInt32(offset))
            offset += part.count
        }
        superBlob += cd + requirements + cms
        superBlob += [UInt8](repeating: 0, count: reserved - superBlob.count)

        return Signed(executable: Data(bytes + superBlob), cdhash: Array(SHA256.hash(data: cd).prefix(20)))
    }

    static func blob(_ magic: UInt32, payload: [UInt8]) -> [UInt8] {
        be32(magic) + be32(UInt32(8 + payload.count)) + payload
    }

    static func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    static func be64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
}

/// Just enough of a little-endian 64-bit Mach-O to find and patch what signing touches.
struct MachOImage {
    static let magic64: UInt32 = 0xFEED_FACF
    static let segment64: UInt32 = 0x19
    static let codeSignature: UInt32 = 0x1D

    var bytes: [UInt8]
    /// Offsets of the load commands of interest.
    private(set) var text: Int?
    private(set) var linkedit: Int?
    private(set) var signatureCommand: Int?

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse() throws {
        guard bytes.count >= 32 else { throw AdHocSigner.Failure.notMachO }
        let magic = u32(0)
        if magic == 0xBEBA_FECA || magic == 0xCAFE_BABE || magic == 0xBFBA_FECA || magic == 0xCAFE_BABF {
            throw AdHocSigner.Failure.fatBinary
        }
        guard magic == Self.magic64 else { throw AdHocSigner.Failure.notMachO }
        let count = Int(u32(16))
        let size = Int(u32(20))
        guard 32 + size <= bytes.count else { throw AdHocSigner.Failure.malformed("load commands") }
        var offset = 32
        for _ in 0..<count {
            guard offset + 8 <= 32 + size else { throw AdHocSigner.Failure.malformed("load command bounds") }
            let cmd = u32(offset), cmdSize = Int(u32(offset + 4))
            guard cmdSize >= 8, offset + cmdSize <= 32 + size else { throw AdHocSigner.Failure.malformed("load command size") }
            if cmd == Self.segment64, cmdSize >= 72 {
                switch segmentName(at: offset + 8) {
                case "__TEXT": text = offset
                case "__LINKEDIT": linkedit = offset
                default: break
                }
            } else if cmd == Self.codeSignature, cmdSize >= 16 {
                signatureCommand = offset
            }
            offset += cmdSize
        }
    }

    private func segmentName(at offset: Int) -> String {
        String(decoding: bytes[offset..<offset + 16].prefix { $0 != 0 }, as: UTF8.self)
    }

    func u32(_ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[o + $1]) << (8 * UInt32($1)) }
    }

    func u64(_ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[o + $1]) << (8 * UInt64($1)) }
    }

    mutating func put32(_ v: UInt32, at o: Int) {
        for i in 0..<4 { bytes[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }

    mutating func put64(_ v: UInt64, at o: Int) {
        for i in 0..<8 { bytes[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }
}
