import Foundation

/// Arithmetic modulo p = 2^255 − 19 on four little-endian 64-bit limbs, just enough for the
/// Elligator 2 map to Curve25519 (RFC 9380 §6.7.1). Not constant-time: its only input is a hash of
/// public-plus-code data that each side computes once per pairing attempt, and an attacker who can
/// time it learns at most which of two candidate points a guess maps to, not the code.
struct FieldElement: Equatable {
    var limbs: [UInt64]

    static let zero = FieldElement(limbs: [0, 0, 0, 0])
    static let one = FieldElement(limbs: [1, 0, 0, 0])
    static let p: [UInt64] = [0xFFFF_FFFF_FFFF_FFED, .max, .max, 0x7FFF_FFFF_FFFF_FFFF]
    static let pMinus2: [UInt64] = [0xFFFF_FFFF_FFFF_FFEB, .max, .max, 0x7FFF_FFFF_FFFF_FFFF]
    static let pMinus1Over2: [UInt64] = [0xFFFF_FFFF_FFFF_FFF6, .max, .max, 0x3FFF_FFFF_FFFF_FFFF]
    /// The Montgomery coefficient A of Curve25519.
    static let a = FieldElement(limbs: [486_662, 0, 0, 0])

    init(limbs: [UInt64]) {
        precondition(limbs.count == 4)
        self.limbs = Self.normalized(limbs)
    }

    /// 32 little-endian bytes; bit 255 is ignored, and values in [p, 2^255) are reduced.
    init(littleEndian bytes: [UInt8]) {
        precondition(bytes.count == 32)
        var l = [UInt64](repeating: 0, count: 4)
        for i in 0..<32 { l[i / 8] |= UInt64(bytes[i]) << (8 * UInt64(i % 8)) }
        l[3] &= 0x7FFF_FFFF_FFFF_FFFF
        self.init(limbs: l)
    }

    var littleEndianBytes: [UInt8] {
        (0..<32).map { UInt8(truncatingIfNeeded: limbs[$0 / 8] >> (8 * UInt64($0 % 8))) }
    }

    var isZero: Bool { limbs == [0, 0, 0, 0] }

    // MARK: Limb helpers

    private static func greaterOrEqual(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for i in stride(from: 3, through: 0, by: -1) where a[i] != b[i] { return a[i] > b[i] }
        return true
    }

    private static func subtractRaw(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var r = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            r[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return r
    }

    private static func addRaw(_ a: [UInt64], _ b: [UInt64]) -> (sum: [UInt64], carry: UInt64) {
        var r = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (r, carry)
    }

    private static func normalized(_ a: [UInt64]) -> [UInt64] {
        var x = a
        while greaterOrEqual(x, p) { x = subtractRaw(x, p) }
        return x
    }

    // MARK: Field operations

    static func + (a: FieldElement, b: FieldElement) -> FieldElement {
        // Both operands are below p, so the sum is below 2^256 and never carries out.
        FieldElement(limbs: addRaw(a.limbs, b.limbs).sum)
    }

    static func - (a: FieldElement, b: FieldElement) -> FieldElement {
        if greaterOrEqual(a.limbs, b.limbs) { return FieldElement(limbs: subtractRaw(a.limbs, b.limbs)) }
        return FieldElement(limbs: subtractRaw(addRaw(a.limbs, p).sum, b.limbs))
    }

    static prefix func - (a: FieldElement) -> FieldElement { zero - a }

    static func * (a: FieldElement, b: FieldElement) -> FieldElement {
        var t = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                // t[i+j] + a·b + carry < 2^128, so the high word plus both overflow bits fits.
                let (hi, lo) = a.limbs[i].multipliedFullWidth(by: b.limbs[j])
                let (s1, o1) = t[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                t[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            t[i + 4] = carry
        }
        return reduce(t)
    }

    /// Folds a 512-bit product using 2^256 ≡ 38 (mod p).
    private static func reduce(_ t: [UInt64]) -> FieldElement {
        var r = Array(t[0..<4])
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (hi, lo) = t[i + 4].multipliedFullWidth(by: 38)
            let (s1, o1) = r[i].addingReportingOverflow(lo)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        // `carry` is below 39: fold it once more; a final carry is at most 1 and leaves a tiny value.
        var extra = carry &* 38
        while extra != 0 {
            var c = extra
            for i in 0..<4 {
                let (s, o) = r[i].addingReportingOverflow(c)
                r[i] = s
                c = o ? 1 : 0
                if c == 0 { break }
            }
            extra = c &* 38
        }
        return FieldElement(limbs: r)
    }

    func power(_ exponent: [UInt64]) -> FieldElement {
        var result = FieldElement.one
        for bit in stride(from: 255, through: 0, by: -1) {
            result = result * result
            if (exponent[bit / 64] >> UInt64(bit % 64)) & 1 == 1 { result = result * self }
        }
        return result
    }

    /// 0 maps to 0 (RFC 9380's inv0).
    var inverse: FieldElement { power(Self.pMinus2) }

    /// True for squares, including 0.
    var isSquare: Bool {
        let legendre = power(Self.pMinus1Over2)
        return legendre == .one || legendre.isZero
    }
}

enum Elligator2 {
    /// The u-coordinate of the point Elligator 2 maps `r` to on Curve25519 (Z = 2), as in
    /// RFC 9380 §6.7.1 with J = A, K = 1. Only the u-coordinate is needed, because X25519 works on
    /// u alone.
    static func map(_ r: FieldElement) -> FieldElement {
        let two = FieldElement(limbs: [2, 0, 0, 0])
        let denominator = FieldElement.one + two * r * r
        var x1 = -(FieldElement.a * denominator.inverse)
        if x1.isZero { x1 = -FieldElement.a }
        let gx1 = x1 * (x1 * (x1 + FieldElement.a) + .one)
        return gx1.isSquare ? x1 : -x1 - FieldElement.a
    }
}
