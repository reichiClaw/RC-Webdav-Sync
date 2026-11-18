import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Namespacefähiger Parser für `207 Multi-Status`-Antworten (RFC 4918) inklusive
/// `sync-token` (RFC 6578).
///
/// Es werden nur Eigenschaften übernommen, deren `propstat/status` 2xx ist.
public final class MultiStatusParser: NSObject, XMLParserDelegate {
    private static let dav = "DAV:"

    private var resources: [DAVResource] = []
    private var syncToken: String?
    private var issues: [String] = []

    private var currentResource: DAVResource?
    private var currentHref: String?
    private var currentResponseStatus: Int?
    private var currentPropstatStatus: Int?
    private var currentProps: [String: String] = [:]
    private var currentIsCollection = false
    private var currentSupportsSync = false
    private var currentSuccessfulProperties: Set<String> = []
    private var currentFailedProperties: Set<String> = []
    private var currentPropstatStatuses: [Int] = []
    private var currentPropstatProps: [String: String] = [:]
    private var currentPropstatPropertyNames: Set<String> = []
    private var propstatIsCollection = false
    private var propstatSupportsSync = false

    private var elementStack: [(namespace: String, name: String)] = []
    private var text = ""
    private var inPropstat = false
    private var inProp = false
    private var inResourceType = false
    private var inSupportedReportSet = false
    private var parseError: Error?
    private var sawMultistatus = false

    public static func parse(_ data: Data) throws -> MultiStatusResponse {
        let parser = MultiStatusParser()
        return try parser.run(data)
    }

    private func run(_ data: Data) throws -> MultiStatusResponse {
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.shouldReportNamespacePrefixes = false
        xml.delegate = self
        let ok = xml.parse()
        guard ok, parseError == nil else {
            let desc = xml.parserError?.localizedDescription ?? parseError?.localizedDescription ?? "unbekannt"
            throw WebDAVError.invalidResponse("XML: \(desc)")
        }
        guard sawMultistatus else {
            throw WebDAVError.invalidResponse("Kein multistatus-Element in der Antwort")
        }
        return MultiStatusResponse(resources: resources, syncToken: syncToken, issues: issues)
    }

    // MARK: XMLParserDelegate

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let ns = namespaceURI ?? ""
        elementStack.append((ns, elementName))
        text = ""
        guard ns == Self.dav else {
            return
        }
        switch elementName {
        case "multistatus":
            sawMultistatus = true
        case "response":
            currentHref = nil
            currentResponseStatus = nil
            currentProps = [:]
            currentIsCollection = false
            currentSupportsSync = false
            currentSuccessfulProperties = []
            currentFailedProperties = []
            currentPropstatStatuses = []
        case "propstat":
            inPropstat = true
            currentPropstatStatus = nil
            currentPropstatProps = [:]
            currentPropstatPropertyNames = []
            propstatIsCollection = false
            propstatSupportsSync = false
        case "prop":
            inProp = true
        case "resourcetype":
            inResourceType = true
        case "collection":
            if inResourceType { propstatIsCollection = true }
        case "supported-report-set":
            inSupportedReportSet = true
        case "sync-collection":
            if inSupportedReportSet { propstatSupportsSync = true }
        default:
            break
        }
        if inProp, parentIs("prop"), elementName != "prop" {
            let key = ns == Self.dav ? elementName : "{\(ns)}\(elementName)"
            currentPropstatPropertyNames.insert(key)
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { if !elementStack.isEmpty { elementStack.removeLast() } }
        let ns = namespaceURI ?? ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ebenen: multistatus > response > (href | status | propstat > (prop > *, status))
        let parentIsResponse = parentIs("response")
        let parentIsMultistatus = parentIs("multistatus")
        let parentIsProp = parentIs("prop")

        if ns == Self.dav {
            switch elementName {
            case "href":
                if parentIsResponse, currentHref == nil {
                    currentHref = value
                }
            case "status":
                let code = Self.statusCode(from: value)
                if inPropstat {
                    currentPropstatStatus = code
                } else if parentIsResponse {
                    currentResponseStatus = code
                }
                if code == nil {
                    issues.append("Ungültige DAV-Statuszeile")
                }
            case "propstat":
                inPropstat = false
                guard let status = currentPropstatStatus else {
                    issues.append("DAV-propstat ohne Status")
                    break
                }
                currentPropstatStatuses.append(status)
                if (200..<300).contains(status) {
                    currentProps.merge(currentPropstatProps) { _, new in new }
                    currentSuccessfulProperties.formUnion(currentPropstatPropertyNames)
                    if propstatIsCollection { currentIsCollection = true }
                    if propstatSupportsSync { currentSupportsSync = true }
                } else {
                    currentFailedProperties.formUnion(currentPropstatPropertyNames)
                }
            case "prop":
                inProp = false
            case "resourcetype":
                inResourceType = false
            case "supported-report-set":
                inSupportedReportSet = false
            case "sync-token":
                if parentIsMultistatus {
                    syncToken = value
                } else if inProp && parentIsProp {
                    currentPropstatProps["sync-token"] = value
                }
            case "response":
                finishResponse()
            default:
                if inProp && !inResourceType && !inSupportedReportSet && parentIsProp {
                    currentPropstatProps[elementName] = value
                }
            }
        } else if inProp && parentIsProp {
            // Fremde Namespaces (z. B. oc:fileid) werden mit Namespace-Präfix aufgenommen.
            currentPropstatProps["{\(ns)}\(elementName)"] = value
        }
        text = ""
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = error
    }

    private func parentIs(_ name: String) -> Bool {
        guard elementStack.count >= 2 else { return false }
        let parent = elementStack[elementStack.count - 2]
        return parent.namespace == Self.dav && parent.name == name
    }

    private func finishResponse() {
        guard let href = currentHref, !href.isEmpty else {
            issues.append("DAV-response ohne href")
            return
        }
        let decodedPath = Self.decodeHrefPath(href)
        var resource = DAVResource(hrefPath: decodedPath, rawHref: href, status: currentResponseStatus)
        resource.isCollection = currentIsCollection
        resource.supportsSyncCollection = currentSupportsSync
        resource.properties = currentProps
        resource.successfulProperties = currentSuccessfulProperties
        resource.failedProperties = currentFailedProperties
        resource.propstatStatuses = currentPropstatStatuses
        if let etag = currentProps["getetag"], !etag.isEmpty { resource.etag = etag }
        if let len = currentProps["getcontentlength"] {
            if let n = Int64(len.trimmingCharacters(in: .whitespaces)), n >= 0 {
                resource.contentLength = n
            } else if !len.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Ungültige getcontentlength für \(href)")
            }
        }
        if let lm = currentProps["getlastmodified"] {
            resource.lastModified = Self.parseHTTPDate(lm)
            if resource.lastModified == nil, !lm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Ungültiges getlastmodified für \(href)")
            }
        }
        if let ct = currentProps["getcontenttype"], !ct.isEmpty { resource.contentType = ct }
        if currentResponseStatus == nil, currentPropstatStatuses.isEmpty {
            issues.append("DAV-response ohne Status oder propstat für \(href)")
        }
        resources.append(resource)
    }

    // MARK: Helpers

    static func statusCode(from statusLine: String) -> Int? {
        // "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2 else { return Int(statusLine) }
        return Int(parts[1])
    }

    /// Wandelt ein `href` in einen dekodierten Pfad um. Absolute URLs werden auf den Pfad reduziert.
    public static func decodeHrefPath(_ href: String) -> String {
        var path = href
        if let url = URL(string: href), url.scheme != nil {
            path = url.path.isEmpty ? "/" : url.path
            // URL.path ist bereits dekodiert.
            return path
        }
        return path.removingPercentEncoding ?? path
    }

    private static let httpDateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        ]
        return formats.map { f in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = f
            return df
        }
    }()
    private static let httpDateLock = NSLock()

    public static func parseHTTPDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        httpDateLock.lock()
        defer { httpDateLock.unlock() }
        for df in httpDateFormatters {
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }
}
