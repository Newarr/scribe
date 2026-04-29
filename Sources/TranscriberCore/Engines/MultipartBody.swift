import Foundation

public struct MultipartBody {
    public let boundary: String
    private var data = Data()

    public init(boundary: String = UUID().uuidString) { self.boundary = boundary }

    public mutating func appendField(name: String, value: String) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
    }

    public mutating func appendFile(name: String, filename: String, contentType: String, data fileData: Data) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n".data(using: .utf8)!)
    }

    public func finalize() -> Data {
        var out = data
        out.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return out
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
}
