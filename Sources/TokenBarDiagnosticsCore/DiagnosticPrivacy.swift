import Foundation
import CoreFoundation

enum DiagnosticPrivacy {
    static let containers: Set<String> = ["events","metrics","objects","reports","numericRecords","updaterReceipts"]
    static let numbers: Set<String> = DiagnosticEvent.metricKeys.union(["schema","at","source","rejected","omitted","osMajor","osMinor","osPatch","processorCount","processCount","freeBytes","object","modifiedAt","startedAt","bugType","retryCount"])
    static let booleans: Set<String> = ["present","regular","symlink","ownerMatches","expectedBundleIdentity","applicationPresent","quarantinePresent","updateKeyPresent","databaseQueriesPerformed","rawLogsIncluded","rawTextExcluded","stacksAndMemoryExcluded"]
    static func project(_ object: [String:Any], depth: Int = 0) -> [String:Any] {
        guard depth<5 else{return [:]}
        var out:[String:Any]=[:]
        for (key,value) in object {
            if containers.contains(key) {
                if let dict=value as? [String:Any]{out[key]=project(dict,depth:depth+1)}
                if let array=value as? [[String:Any]]{out[key]=array.prefix(6000).map{project($0,depth:depth+1)}}
            } else if let number=value as? NSNumber {
                if CFGetTypeID(number)==CFBooleanGetTypeID(){if booleans.contains(key){out[key]=number}}
                else if numbers.contains(key),number.doubleValue.isFinite{out[key]=number}
            } else if let text=value as? String {
                switch key {
                case "version","build","targetVersion","targetBuild","sourceVersion":out[key]=DiagnosticEvent.version(text)
                case "session","attempt":if let id=UUID(uuidString:text){out[key]=id.uuidString.lowercased()}
                case "area":if DiagnosticArea(rawValue:text) != nil{out[key]=text}
                case "phase":if DiagnosticPhase(rawValue:text) != nil || text=="failure"{out[key]=text}
                case "status","signatureCheck":out[key]=["ok","unavailable","timeout","failed","pending","launchFailed","confirmed"].contains(text) ? text:"unavailable"
                case "platform":if ["macos","windows","linux"].contains(text){out[key]=text}
                case "architecture":if ["arm64","aarch64","x86_64","x86"].contains(text){out[key]=text}
                case "exceptionType":if ["EXC_BAD_ACCESS","EXC_CRASH","EXC_RESOURCE","EXC_GUARD","EXC_BREAKPOINT","EXC_BAD_INSTRUCTION"].contains(text){out[key]=text}
                case "signal":if ["SIGABRT","SIGSEGV","SIGBUS","SIGILL","SIGTRAP","SIGKILL","SIGTERM"].contains(text){out[key]=text}
                case "stateSource":if text=="persisted_diagnostic_events"{out[key]=text}
                default:break
                }
            }
        }
        return out
    }
}
