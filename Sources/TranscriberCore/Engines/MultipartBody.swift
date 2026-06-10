import Foundation

struct MultipartBody {
    let boundary: String
    private var data = Data()

    init(boundary: String = UUID().uuidString) { self.boundary = boundary }

    mutating func appendField(name: String, value: String) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFile(name: String, filename: String, contentType: String, data fileData: Data) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n".data(using: .utf8)!)
    }

    func finalize() -> Data {
        var out = data
        out.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return out
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
}
