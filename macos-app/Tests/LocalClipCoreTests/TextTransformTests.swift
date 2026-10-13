// F16各转换的规则、边界与PRD验收用例；纯函数，不访问剪贴板或存储，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct TextTransformTests {
    /// AC1/AC2：语言标识、正文逐字不变、围栏比最长反引号多一个，by AI.Coding。
    @Test func markdownCodeBlock() throws {
        let swift = "let a = 1\nprint(a)"
        let block = try TextTransform.markdownCodeBlock.apply(swift, language: "swift")
        #expect(block == "```swift\nlet a = 1\nprint(a)\n```")
        #expect(try TextTransform.markdownCodeBlock.apply("x\n", language: nil) == "```\nx\n```")
        #expect(try TextTransform.markdownCodeBlock.apply("see ```code```", language: nil).hasPrefix("````\n"))
        #expect(try TextTransform.markdownCodeBlock.apply("a\r\nb", language: "bash") == "```bash\r\na\r\nb\r\n```")
        #expect(try TextTransform.markdownCodeBlock.apply("<!DOCTYPE html><html></html>", language: "xml").hasPrefix("```html\n"))
    }

    /// AC3：键顺序、数字原文、字符串转义与空容器都保持不变，by AI.Coding。
    @Test func formatAndMinifyJSONAreLexical() throws {
        let input = #"{"b":1,"a":1.10,"n":12345678901234567890,"s":"x, \"y\": {z}","e":{},"l":[ ],"u":"tab\tnew\nline é😀"}"#
        let pretty = try TextTransform.formatJSON.apply(input)
        #expect(pretty == """
        {
          "b": 1,
          "a": 1.10,
          "n": 12345678901234567890,
          "s": "x, \\"y\\": {z}",
          "e": {},
          "l": [],
          "u": "tab\\tnew\\nline é😀"
        }
        """)
        #expect(try TextTransform.minifyJSON.apply(pretty) == #"{"b":1,"a":1.10,"n":12345678901234567890,"s":"x, \"y\": {z}","e":{},"l":[],"u":"tab\tnew\nline é😀"}"#)
        #expect(try TextTransform.formatJSON.apply("[1,[2,3]]") == "[\n  1,\n  [\n    2,\n    3\n  ]\n]")
        #expect(try TextTransform.formatJSON.apply("\"just a string\"") == "\"just a string\"")
    }

    /// AC4：无效JSON给出行列；判定与执行一致，by AI.Coding。
    @Test func invalidJSONReportsPosition() {
        let input = "{\n  \"a\": 1,\n  \"b\": oops\n}"
        #expect(!TextTransform.formatJSON.isApplicable(input))
        do { _ = try TextTransform.formatJSON.apply(input); Issue.record("Invalid JSON accepted") }
        catch let error as TransformError { #expect(error.message.hasPrefix("不是有效 JSON"), "\(error.message)"); #expect(error.message.contains("行"), "\(error.message)") }
        catch { Issue.record("Unexpected \(error)") }
    }

    /// AC5与代码清理：提示符、行号、公共缩进与空白，保留其余字符与原换行符，by AI.Coding。
    @Test func codeCleanup() throws {
        #expect(try TextTransform.stripPrompt.apply("$ cd app\n$ swift build\n% echo done") == "cd app\nswift build\necho done")
        #expect(try TextTransform.stripPrompt.apply("  $ ls\noutput $ here") == "  ls\noutput $ here")
        #expect(!TextTransform.stripPrompt.isApplicable("echo $HOME"))
        #expect(try TextTransform.stripLineNumbers.apply("1 import Foundation\n2 \n3     let a = 1\n4 | b\n10: c") == "import Foundation\n\n    let a = 1\nb\nc")
        #expect(!TextTransform.stripLineNumbers.isApplicable("2 apples\n1 pear"))
        #expect(!TextTransform.stripLineNumbers.isApplicable("1 only one\nplain\nplain\nplain"))
        #expect(!TextTransform.stripLineNumbers.isApplicable("12.5 is a value\n13.5 also"))
        #expect(try TextTransform.dedent.apply("    a\n      b\n\n    c\r\n") == "a\n  b\n\nc\r\n")
        #expect(try TextTransform.dedent.apply("\t\tx\n\t y") == "\tx\n y")
        #expect(!TextTransform.dedent.isApplicable("a\n  b"))
        #expect(try TextTransform.trimWhitespace.apply("\n  \nfoo  \r\n  bar\t\n\n") == "foo\r\n  bar")
    }

    @Test func stringLiteralsRoundTrip() throws {
        let original = "Line 1\n\t\"quoted\" \\ path\u{01} 中文 😀"
        let quoted = try TextTransform.quoteString.apply(original)
        #expect(quoted == "\"Line 1\\n\\t\\\"quoted\\\" \\\\ path\\u0001 中文 😀\"")
        #expect(try TextTransform.unquoteString.apply(quoted) == original)
        #expect(try TextTransform.unquoteString.apply("  \"a\\u00e9\"\n") == "aé")
        #expect(!TextTransform.unquoteString.isApplicable("no quotes"))
        #expect(!TextTransform.unquoteString.isApplicable("\"bad \\x escape\""))
    }

    @Test func base64AndURL() throws {
        #expect(try TextTransform.base64Encode.apply("hello 世界") == "aGVsbG8g5LiW55WM")
        #expect(try TextTransform.base64Decode.apply("aGVsbG8g5LiW55WM") == "hello 世界")
        // base64url且缺少补位、含换行。
        #expect(try TextTransform.base64Decode.apply("eyJhIjoiPz4_In0\n") == "{\"a\":\"?>?\"}")
        #expect(try TextTransform.base64Decode.apply("PDw_Pz8-Pg") == "<<???>>")
        #expect(!TextTransform.base64Decode.isApplicable("hello world"))
        #expect(!TextTransform.base64Decode.isApplicable("AAAA"))
        #expect(!TextTransform.base64Decode.isApplicable("abc"))
        #expect(try TextTransform.urlEncode.apply("a b&c=d/é?") == "a%20b%26c%3Dd%2F%C3%A9%3F")
        #expect(try TextTransform.urlDecode.apply("a%20b+c%26%E4%B8%AD") == "a b c&中")
        #expect(!TextTransform.urlDecode.isApplicable("plain text"))
        #expect(!TextTransform.urlDecode.isApplicable("100%zz"))
    }

    @Test func caseStylesPerLine() throws {
        #expect(try TextTransform.camelCase.apply("user_id\nHTTPServer name\n  max-retry-count") == "userId\nhttpServerName\n  maxRetryCount")
        #expect(try TextTransform.snakeCase.apply("userID\nparseJSONValue2Text") == "user_id\nparse_json_value2_text")
        #expect(try TextTransform.kebabCase.apply("Max Retry_Count") == "max-retry-count")
        #expect(try TextTransform.uppercase.apply("abc 中") == "ABC 中")
        #expect(try TextTransform.lowercase.apply("ABC") == "abc")
        #expect(try TextTransform.snakeCase.apply("\n") == "\n")
    }

    @Test func sortAndUniqueLines() throws {
        #expect(try TextTransform.sortLines.apply("b10\nb2\na\n") == "a\nb2\nb10\n")
        #expect(try TextTransform.uniqueLines.apply("x\r\ny\r\nx\r\nz") == "x\r\ny\r\nz")
        #expect(!TextTransform.sortLines.isApplicable("single\n"))
    }

    /// 可选即可执行：任何判定为适用的转换都不得抛错；超限内容一律不可用，by AI.Coding。
    @Test func applicabilityMatchesApply() {
        let samples = ["", "plain", "  $ ls -la\n  $ pwd", "1 a\n2 b\n3 c", "{\"a\": [1, 2]}", "\"quoted\\n\"", "aGVsbG8=",
                       "a%20b", "camelCaseValue\nsnake_case_value", "b\na\nb", "    indented\n    block", "😀\r\n中文", String(repeating: "x", count: 10)]
        for sample in samples {
            for transform in TextTransform.allCases where transform.isApplicable(sample) {
                #expect((try? transform.apply(sample)) != nil, "\(transform) on \(sample.debugDescription)")
            }
        }
        let huge = String(repeating: "a", count: TextTransform.byteLimit + 1)
        #expect(TextTransform.allCases.allSatisfy { !$0.isApplicable(huge) })
        #expect((try? TextTransform.uppercase.apply(huge)) == nil)
    }

    /// PRD 5.5与AC9：1 MiB JSON格式化/压缩（含校验）耗时；可选执行，样本写入输出文件，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_TRANSFORM_PERF"] == "1"))
    func oneMiBJSONTiming() throws {
        let line = "{\"id\":123456,\"name\":\"LocalClip transform benchmark\",\"tags\":[\"a\",\"b\"],\"value\":1.10},"
        let json = "[" + String(repeating: line, count: (1 << 20) / line.utf8.count) + "{}]"
        func measure(_ transform: TextTransform) throws -> [Double] {
            try (0..<20).map { _ in
                let begin = ContinuousClock.now; _ = try transform.apply(json); let value = ContinuousClock.now - begin
                return Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15
            }
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int((Double(values.count) * 0.95).rounded(.up)) - 1] }
        let format = try measure(.formatJSON), minify = try measure(.minifyJSON), others = try measure(.markdownCodeBlock)
        let report: [String: Any] = ["bytes": json.utf8.count, "formatMs": format, "minifyMs": minify, "markdownMs": others,
                                     "formatP95": p95(format), "minifyP95": p95(minify), "markdownP95": p95(others)]
        if let output = ProcessInfo.processInfo.environment["LOCALCLIP_TRANSFORM_PERF_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        #expect(p95(format) < 200)
        #expect(p95(others) < 50)
    }
}
