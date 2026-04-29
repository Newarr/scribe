import XCTest
@testable import TranscriberCore

final class MultipartBodyTests: XCTestCase {
    func testSimpleFieldsAndFile() {
        var body = MultipartBody(boundary: "BOUNDARY")
        body.appendField(name: "model_id", value: "scribe_v2")
        body.appendField(name: "diarize", value: "true")
        body.appendFile(
            name: "file",
            filename: "audio.wav",
            contentType: "audio/wav",
            data: Data("FAKEAUDIO".utf8)
        )

        let s = String(data: body.finalize(), encoding: .utf8)!
        XCTAssertTrue(s.contains("--BOUNDARY\r\nContent-Disposition: form-data; name=\"model_id\""))
        XCTAssertTrue(s.contains("scribe_v2\r\n"))
        XCTAssertTrue(s.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(s.contains("Content-Type: audio/wav"))
        XCTAssertTrue(s.contains("FAKEAUDIO"))
        XCTAssertTrue(s.hasSuffix("--BOUNDARY--\r\n"))
    }

    func testRepeatedFieldsForArrayValues() {
        var body = MultipartBody(boundary: "B")
        body.appendField(name: "keyterms", value: "Faris")
        body.appendField(name: "keyterms", value: "Ramp Network")
        let s = String(data: body.finalize(), encoding: .utf8)!
        XCTAssertEqual(s.components(separatedBy: "name=\"keyterms\"").count, 3)
    }
}
