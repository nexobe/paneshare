import Foundation

/// A property-list value, written as deterministic XML (sorted keys, fixed layout), so a generated
/// bundle's Info.plist and resource seal hash the same every time they are rebuilt.
public indirect enum PlistValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case data(Data)
    case array([PlistValue])
    case dict([String: PlistValue])

    public var xmlDocument: Data {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        write(into: &out, depth: 0)
        out += "</plist>\n"
        return Data(out.utf8)
    }

    private func write(into out: inout String, depth: Int) {
        let pad = String(repeating: "\t", count: depth)
        switch self {
        case .string(let s): out += "\(pad)<string>\(Self.escape(s))</string>\n"
        case .bool(let b): out += "\(pad)<\(b ? "true" : "false")/>\n"
        case .integer(let i): out += "\(pad)<integer>\(i)</integer>\n"
        case .real(let r):
            let text = r.rounded() == r && abs(r) < 1e15 ? String(Int64(r)) : String(r)
            out += "\(pad)<real>\(text)</real>\n"
        case .data(let d): out += "\(pad)<data>\(d.base64EncodedString())</data>\n"
        case .array(let items):
            out += "\(pad)<array>\n"
            for item in items { item.write(into: &out, depth: depth + 1) }
            out += "\(pad)</array>\n"
        case .dict(let entries):
            out += "\(pad)<dict>\n"
            for key in entries.keys.sorted() {
                out += "\(pad)\t<key>\(Self.escape(key))</key>\n"
                entries[key]!.write(into: &out, depth: depth + 1)
            }
            out += "\(pad)</dict>\n"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
