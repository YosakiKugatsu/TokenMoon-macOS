// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TokenMoonCore

struct JSONMemberSlicesTests {
    @Test func indexesEscapedKeysAndStreamsNestedValuesFromSlicedData() throws {
        let json = #" {"sh\u0061rds": {"🌓": [ {"text": "a\"b]}", "code": "\uD83C\uDF13"}, -2.5e+2, false, null ]}, "v": 1} "#
        let padded = Data(("guard" + json + "tail").utf8)
        let data = padded[5..<(padded.count - 4)]
        let top = try JSONMemberSlices.members(in: data)
        let shard = try #require(top["shards"])
        let inner = try JSONMemberSlices.members(in: data, range: shard)
        let array = try #require(inner["🌓"])
        var values: [String] = []
        try JSONMemberSlices.forEachElement(in: data, range: array) { range in
            let value = try JSONMemberSlices.slice(in: data, range: range)
            values.append(String(decoding: value, as: UTF8.self))
        }
        #expect(values == [#"{"text": "a\"b]}", "code": "\uD83C\uDF13"}"#, "-2.5e+2", "false", "null"])
        #expect(try JSONDecoder().decode(Int.self, from: JSONMemberSlices.slice(in: data, range: #require(top["v"]))) == 1)
        let nestedView = try JSONMemberSlices.slice(in: data, range: shard)
        let nested = try JSONMemberSlices.members(in: nestedView)
        let shifted = try #require(nested["🌓"])
        #expect(shifted.lowerBound + shard.lowerBound == array.lowerBound)
    }

    @Test func rejectsCorruptionWithoutReturningAnIndex() {
        let invalid = [
            #"{"key": [1,]}"#, #"{"key": trueX}"#, #"{"key": -01}"#, #"{"key": 1.e4}"#,
            #"{"key": "\q"}"#, #"{"key": "\uD800"}"#, #"{"key": null, "k\u0065y": []}"#,
            #"{"key": false} {}"#, #"{"key": [1,2}"#, #"{"key" 1}"#,
            #"{"key": "# + String(repeating: "[", count: 513) + "0" + String(repeating: "]", count: 513) + "}",
        ]
        for json in invalid {
            #expect(throws: DecodingError.self, "Expected rejection: \(json.prefix(80))") {
                try JSONMemberSlices.members(in: Data(json.utf8))
            }
        }
        let invalidUTF8 = Data(#"{"key": ""#.utf8) + Data([0xc0, 0xaf]) + Data(#""}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONMemberSlices.members(in: invalidUTF8) }
        #expect(throws: DecodingError.self) { try JSONMemberSlices.members(in: Data("{}".utf8), range: -1..<1) }
        #expect(throws: DecodingError.self) { try JSONMemberSlices.slice(in: Data(), range: 0..<1) }
        #expect(throws: DecodingError.self) {
            try JSONMemberSlices.forEachElement(in: Data("[1,2] 3".utf8)) { _ in }
        }
    }
}
