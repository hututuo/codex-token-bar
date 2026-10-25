import Foundation

/// RFC 3339 / ISO 8601 timestamps to Unix milliseconds (METRICS 3.1).
enum Timestamp {
    /// Accepts `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM|±HHMM)`. Fractions beyond milliseconds are truncated.
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> Int64? {
        let count = bytes.count
        guard count >= 20, count <= 64 else { return nil }
        guard let year = digits(bytes, 0, 4), bytes[4] == UInt8(ascii: "-"),
              let month = digits(bytes, 5, 2), bytes[7] == UInt8(ascii: "-"),
              let day = digits(bytes, 8, 2)
        else { return nil }
        let separator = bytes[10]
        guard separator == UInt8(ascii: "T") || separator == UInt8(ascii: "t") || separator == UInt8(ascii: " "),
              let hour = digits(bytes, 11, 2), bytes[13] == UInt8(ascii: ":"),
              let minute = digits(bytes, 14, 2), bytes[16] == UInt8(ascii: ":"),
              let second = digits(bytes, 17, 2)
        else { return nil }
        guard (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        var index = 19
        var millis = 0
        if bytes[index] == UInt8(ascii: ".") {
            index += 1
            let fractionStart = index
            while index < count, isDigit(bytes[index]) {
                if index - fractionStart < 3 {
                    millis = millis * 10 + Int(bytes[index] - UInt8(ascii: "0"))
                }
                index += 1
            }
            let fractionDigits = index - fractionStart
            guard fractionDigits > 0 else { return nil }
            if fractionDigits == 1 { millis *= 100 } else if fractionDigits == 2 { millis *= 10 }
        }
        guard index < count else { return nil }

        var offsetSeconds = 0
        let zone = bytes[index]
        if zone == UInt8(ascii: "Z") || zone == UInt8(ascii: "z") {
            index += 1
        } else if zone == UInt8(ascii: "+") || zone == UInt8(ascii: "-") {
            index += 1
            guard let offsetHours = digits(bytes, index, 2) else { return nil }
            index += 2
            if index < count, bytes[index] == UInt8(ascii: ":") { index += 1 }
            guard let offsetMinutes = digits(bytes, index, 2) else { return nil }
            index += 2
            guard offsetHours <= 23, offsetMinutes <= 59 else { return nil }
            offsetSeconds = (offsetHours * 3600 + offsetMinutes * 60) * (zone == UInt8(ascii: "+") ? 1 : -1)
        } else {
            return nil
        }
        guard index == count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        return seconds * 1000 + Int64(millis)
    }

    static func parse(_ text: String) -> Int64? {
        var copy = text
        return copy.withUTF8 { parse($0) }
    }

    private static func digits(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ length: Int) -> Int? {
        guard start + length <= bytes.count else { return nil }
        var value = 0
        for index in start..<(start + length) {
            let byte = bytes[index]
            guard isDigit(byte) else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    @inline(__always)
    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
