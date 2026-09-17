// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import Foundation

/**
 A JSON value. Styles, the legend and pack metadata are edited as plain values, so a copy of a
 layer is independent of the original without any explicit deep copy.
 */
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])
}

// MARK: - Parsing and serialising

public extension JSON {
    init(parsing data: Data) throws {
        self = JSON(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    init(contentsOf url: URL) throws {
        try self.init(parsing: Data(contentsOf: url))
    }

    /// Converts a value as produced by `JSONSerialization` (or a MapLibre feature attribute).
    init(foundation value: Any?) {
        guard let value else {
            self = .null
            return
        }
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map { JSON(foundation: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSON(foundation: $0) })
        default:
            self = .string(String(describing: value))
        }
    }

    /**
     Compact JSON text with sorted keys, so equal values always serialise identically. Numbers use
     their shortest exact form (`JSONSerialization` would write 3.3 as 3.2999999999999998).
     */
    func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .number(let value):
            if !value.isFinite {
                out += "null"
            } else if value.rounded() == value && abs(value) < 1e15 {
                out += String(Int64(value))
            } else {
                out += String(value)
            }
        case .string(let value):
            Self.writeString(value, into: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 {
                    out += ","
                }
                value.write(into: &out)
            }
            out += "]"
        case .object(let values):
            out += "{"
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 {
                    out += ","
                }
                Self.writeString(key, into: &out)
                out += ":"
                values[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Access

public extension JSON {
    subscript(key: String) -> JSON? {
        get {
            if case .object(let values) = self {
                return values[key]
            }
            return nil
        }
        set {
            guard case .object(var values) = self else {
                return
            }
            self = .null // release our reference so the dictionary is mutated in place
            values[key] = newValue
            self = .object(values)
        }
    }

    subscript(index: Int) -> JSON? {
        if case .array(let values) = self, values.indices.contains(index) {
            return values[index]
        }
        return nil
    }

    var string: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var double: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var array: [JSON]? {
        if case .array(let values) = self {
            return values
        }
        return nil
    }

    var object: [String: JSON]? {
        if case .object(let values) = self {
            return values
        }
        return nil
    }

    var isNull: Bool {
        self == .null
    }

    func has(_ key: String) -> Bool {
        self[key] != nil
    }

    /// Removes a key from an object; does nothing for other values.
    mutating func remove(_ key: String) {
        self[key] = nil
    }
}

// MARK: - Literals

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(arrayLiteral elements: JSON...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSON: CustomStringConvertible {
    public var description: String {
        serialized()
    }
}
