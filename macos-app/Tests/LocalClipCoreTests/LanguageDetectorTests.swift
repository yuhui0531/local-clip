// 文本／代码判定语料：真实误判样本、各语言正例、歧义退路、截断与鲁棒性；纯计算，无桌面副作用，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct LanguageDetectorTests {
    private func language(_ text: String) -> String? { LanguageDetector.detect(text).language }

    /// 用户原文与已复现样本：此前分别被highlight.js判为CSS/Shell/Java/TypeScript/SQL/C#/CSS/YAML。
    static let reproducedProse = [
        "Do we need a review agent to double confirm your changes? if yes, please generate a review prompt to let other coding agent to review your changes.",
        "Please help me find the source and test the export function.",
        "if you can then do this for me and return when done",
        "Please return true if the type is new and the function is public.",
        "Please begin the transaction and commit the changes, then return the result.",
        "Please select a name from the list where the status is active and order by date.",
        "We need a plan to go from here to there and to finish the review.",
        "Name: Alice\nStatus: Ready\nOwner: Bob"]
    @Test(arguments: reproducedProse) func reproducedProseStaysText(text: String) {
        let guess = LanguageDetector.detect(text)
        #expect(guess.language == nil, "\(text)")
        #expect(guess.complete)
        #expect(guess.verifiedLanguage == nil)
    }
    @Test func userSampleLengthIsVerbatim() {
        #expect(Self.reproducedProse[0].count == 147)
    }

    static let ordinaryText = [
        "会议纪要：\n1. 周五前完成导出功能评审\n2. 张三负责回归测试\n3. 下周一发布候选版本",
        "Hi team,\n\nThe release notes are attached. Please review them before Friday and let me know if anything is missing.\n\nThanks,\nAlex",
        "Customer: ACME Corp\nContract: 2026-10\nAmount: 12000\nOwner: Bob",
        "I think we should refactor the export function first; then we can update the tests and return to the UI work.",
        "C:\\Users\\alice\\Documents\\report.docx",
        "/Users/ronny/VscodeProjects/rea/macos-app/docs/reviews/LocalClip_Comprehensive_Review_2026-10-14.md",
        "https://example.com/a?b=1\nhttps://example.com/c/d\nhttps://example.org/e#f",
        "2026-10-19 10:00:01 INFO Started server on port 8080\n2026-10-19 10:00:02 WARN Cache miss for key users\n2026-10-19 10:00:03 ERROR Connection refused",
        "请运行一下导出功能，然后把 export 的结果发给我，return 之前记得检查。",
        "请根据review comments **/Users/ronny/a/b/c.md 进行修复。**  注意，切记功能",
        "今天下午三点开会，记得带电脑。",
        "export", "return", "SELECT", "color", "a to a to from to",
        "Use the -v flag to see more output when the command fails on your machine.",
        "Agenda:\n- review the plan\n- assign owners\n- set the date"]
    @Test(arguments: ordinaryText) func ordinaryTextIsNotCode(text: String) {
        #expect(language(text) == nil, "\(text)")
    }

    /// 普通文本中的高频词重复、大小写与空白变形不会因次数增加而成为代码。
    @Test func repeatedKeywordsDoNotAccumulate() {
        for word in ["a", "to", "from", "if", "return", "select", "export", "function", "public", "class"] {
            for count in [1, 3, 10, 60] {
                let lower = Array(repeating: word, count: count).joined(separator: " ")
                for text in [lower, lower.uppercased(), lower.replacingOccurrences(of: " ", with: "\n"), lower.replacingOccurrences(of: " ", with: "  \t ")] {
                    #expect(language("Please \(text) the item and send it back.") == nil, "\(word)×\(count)")
                    #expect(language(text) == nil, "\(word)×\(count)")
                }
            }
        }
    }

    static let code: [(String, String)] = [
        ("java", "public class Example { public static void main(String[] args) { System.out.println(\"Hi\"); } }"),
        ("java", "package com.example.demo;\n\nimport java.util.List;\n\npublic class Service {\n    private final String name;\n}\n"),
        ("python", "def greet(name):\n    # comment\n    return f'Hello {name}'\n"),
        ("python", "import os\n\nfor path in os.listdir('.'):\n    print(path)\n"),
        ("javascript", "function greet(name) { const n = 42; return `Hi ${name}`; }"),
        ("javascript", "// 获取用户列表\nfunction getUsers() { return api.get('/users'); }"),
        ("javascript", "const add = (a, b) => a + b;\nconsole.log(add(1, 2));"),
        ("typescript", "interface User { name: string; }\nconst user: User = { name: 'Hi' };"),
        ("typescript", "export type Id = string;\nexport function find(id: Id): Promise<User> { return api.get(id); }"),
        ("yaml", "name: localclip\nitems:\n  - enabled: true\n"),
        ("yaml", "services:\n  web:\n    image: nginx\n    ports:\n      - \"80:80\"\n"),
        ("xml", "<?xml version=\"1.0\"?><root id=\"1\">中文</root>"),
        ("xml", "<!DOCTYPE html><html><body><h1 class=\"title\">Hello</h1></body></html>"),
        ("xml", "<p>Please review the <code>export</code> function and send the report.</p>"),
        ("css", ".card { color: #fff; margin: 10px; }"),
        ("css", "@keyframes spin {\n  from { transform: rotate(0deg); }\n  to { transform: rotate(360deg); }\n}"),
        ("css", "@media (max-width: 600px) {\n  .nav a:hover { display: none; }\n}"),
        ("css", ":root {\n  --brand: #0a84ff; /* 主色 */\n}\n.button { background-color: var(--brand); }"),
        ("css", "color: red;"),
        ("bash", "#!/bin/bash\nfor f in *.json; do echo \"$f\"; done\n"),
        ("bash", "npm install --save react"),
        ("bash", "git commit -m \"fix export\" && git push origin main"),
        ("bash", "export PATH=\"$HOME/bin:$PATH\"\necho $PATH | grep bin"),
        ("swift", "import Foundation\nstruct Point { let x: Int; let y: Int }\nfunc distance(_ a: Point, _ b: Point) -> Double {\n    let dx = Double(a.x - b.x), dy = Double(a.y - b.y)\n    return (dx * dx + dy * dy).squareRoot()\n}\n"),
        ("swift", "guard let value = optional else { return }\nprint(value)"),
        ("sql", "SELECT id, name FROM users WHERE status = 'active' ORDER BY created_at;"),
        ("sql", "select * from orders o join users u on o.user_id = u.id where u.id = 1"),
        ("sql", "INSERT INTO users (id, name) VALUES (1, 'Alice');"),
        ("sql", "CREATE TABLE users (\n  id INTEGER PRIMARY KEY,\n  name VARCHAR(64) NOT NULL\n);"),
        ("cpp", "#include <iostream>\nint main() {\n    std::cout << \"hi\" << std::endl;\n    return 0;\n}\n"),
        ("csharp", "using System;\nclass Program { static void Main(string[] args) { Console.WriteLine(\"Hi\"); } }"),
        ("csharp", "public class User\n{\n    public string Name { get; set; }\n    public int Age { get; set; }\n}"),
        ("go", "package main\n\nimport \"fmt\"\n\nfunc main() {\n    fmt.Println(\"hi\")\n}\n"),
        ("go", "func (s *Server) Start(addr string) error {\n    ln, err := net.Listen(\"tcp\", addr)\n    if err != nil {\n        return err\n    }\n    return s.serve(ln)\n}"),
        ("rust", "fn main() {\n    let mut v = Vec::new();\n    v.push(1);\n    println!(\"{:?}\", v);\n}\n"),
        ("ruby", "require 'json'\n\nclass Greeter\n  def greet(name)\n    puts \"Hello #{name}\"\n  end\nend\n"),
        ("php", "<?php\n$name = 'World';\necho \"Hello $name\";\n"),
        ("ini", "[server]\nhost = localhost\nport = 8080\n\n[log]\nlevel = debug\n"),
        ("json", "{\"name\": \"中文\", \"count\": 42, \"ok\": true}"),
        ("json", "[\n  {\"id\": 1},\n  {\"id\": 2}\n]"),
        ("markdown", "# 发布说明\n\n- 新增拖出为文件\n- 修复若干问题\n\n详见 [PRD](https://example.com/prd)\n"),
        ("markdown", "Here is the fix:\n\n```swift\nlet a = 1\n```\n\nIt removes the crash."),
        ("python", "class Store:\n    \"\"\"Keeps the records.\n\n    This docstring is long English prose that explains what the store does in detail.\n    \"\"\"\n    def load(self, key):\n        return self.items.get(key)\n")]
    @Test func distinguishableCodeGetsTheRightLanguage() {
        for (expected, text) in Self.code {
            let guess = LanguageDetector.detect(text)
            #expect(guess.language == expected, "\(expected): \(text)")
            #expect(guess.verifiedLanguage == expected, "\(expected)")
        }
    }

    /// 证据不足或JS/TS共用的短片段返回未确定，不按注册顺序硬选。
    @Test func ambiguousFragmentsStayUndetermined() {
        for text in ["const value = 1;", "let a = 1", "x = 1", "print('x')", "foo(bar)", "{a}", "true", "42", "\"hello\"",
                     "Name: Alice", "key=value\nother=thing", "items:\n  - a\n  - b", "<name> and <email>"] {
            #expect(language(text) == nil, "\(text)")
        }
    }

    /// 说明夹代码、首段代码后跟长篇说明、混合语言：整体不是某一种代码。
    @Test func mixedContentIsNotOneLanguage() {
        let code = "function greet(name) {\n  return `Hi ${name}`;\n}\n"
        let prose = String(repeating: "This paragraph explains why the export flow needs another review before the release.\n", count: 6)
        #expect(language(code + "\n" + prose) == nil)
        #expect(language(prose + "\n" + code) == nil)
        #expect(language(".card { color: red; }\nfunction greet(name) { return name; }") == nil)
        // 字符串和注释中的伪代码不构成证据。
        #expect(language("def run(self):\n    query = \"SELECT * FROM users WHERE id = 1\"\n    return self.db.execute(query)\n") == "python")
        #expect(language("// SELECT * FROM users;\n// npm install --save react\nconst value = compute(); console.log(value);") == "javascript")
    }

    /// 中文正文不成为代码，中文注释和字符串的代码仍可识别；中文占比不是绝对否决。
    @Test func chineseProseAndChineseCommentedCode() {
        #expect(language("这是一个关于导出功能的说明。\n我们需要在周五前完成评审。") == nil)
        let commented = "# 读取配置文件\n# 如果文件不存在则使用默认值\n# 这里的注释全部是中文说明\ndef load_config(path):\n    # 打开文件\n    with open(path) as f:\n        return json.load(f)\n"
        #expect(language(commented) == "python")
        #expect(language("guard let 标题 = 可选标题 else { return }\nprint(\"中文标题中文标题中文标题\")") == "swift")
    }

    /// 截断样本只能展示：完整性为false，verifiedLanguage为nil；JSON截断前缀不当成完整合法JSON。
    @Test func truncatedSamplesAreNotComplete() {
        let json = "{\"name\": \"LocalClip\", \"tags\": [\"a\", \"b\"], \"count\": 4"
        let truncated = LanguageDetector.detect(json, truncated: true)
        #expect(truncated.language == "json")
        #expect(!truncated.complete)
        #expect(truncated.verifiedLanguage == nil)
        let full = LanguageDetector.detect(".card { color: #fff; }\n", truncated: false)
        #expect(full.verifiedLanguage == "css")
        // 超出预算：只分析前缀，结论不完整。
        let long = String(repeating: "def f(x):\n    return x\n", count: LanguageDetector.completeLimit / 10)
        let guess = LanguageDetector.detect(long)
        #expect(long.utf16.count > LanguageDetector.completeLimit)
        #expect(guess.language == "python")
        #expect(!guess.complete)
        // 预算边界（UTF-16码元）：恰好在预算内为完整结论，超出1个码元即只供展示。
        let unit = "    total += values[index] * 2;\n"
        var code = "function sum(values) {\n"
        while code.utf16.count + unit.utf16.count + 2 <= LanguageDetector.completeLimit { code += unit }
        code += String(repeating: " ", count: LanguageDetector.completeLimit - 2 - code.utf16.count) + "}\n"
        #expect(code.utf16.count == LanguageDetector.completeLimit)
        #expect(LanguageDetector.detect(code) == LanguageGuess(language: "javascript", complete: true))
        #expect(LanguageDetector.detect(code + " ") == LanguageGuess(language: "javascript", complete: false))
        // 大JSON仍由解析器完整验证。
        let line = "  {\"id\": 1, \"name\": \"x\"},\n"
        let big = "[\n" + String(repeating: line, count: LanguageDetector.completeLimit / line.utf16.count + 10) + "  {}\n]"
        #expect(LanguageDetector.detect(big) == LanguageGuess(language: "json", complete: true))
        // 截断JSON前缀即使恰好闭合也不能宣称完整。
        #expect(LanguageDetector.detect("{\"a\": 1}", truncated: true).verifiedLanguage == nil)
    }

    /// 相同前缀不同后缀：结论跟随完整内容，不被前缀代表。
    @Test func samePrefixDifferentSuffix() {
        let prefix = "SELECT id, name FROM users WHERE status = 'active';\n"
        #expect(language(prefix) == "sql")
        #expect(language(prefix + String(repeating: "Please review the query above and confirm the result with the team today.\n", count: 3)) == nil)
    }

    /// 180/512/2048/8192 附近（UTF-16码元）的代码与正文结论稳定。
    @Test func lengthBoundaries() {
        let codeLine = "    total += values[index] * 2;\n"
        let proseLine = "We should review the export function before the release next week.\n"
        for limit in [180, 512, 2048, 8192] {
            for delta in [-1, 0, 1] {
                let target = limit + delta
                var code = "function sum(values) {\n"
                while code.utf16.count + codeLine.utf16.count + 2 < target { code += codeLine }
                code += "}\n"
                #expect(language(code) == "javascript", "code \(target)")
                var prose = ""
                while prose.utf16.count < target { prose += proseLine }
                #expect(language(String(prose.utf16.prefix(target))!) == nil, "prose \(target)")
            }
        }
    }

    /// CRLF、代理对、组合字符、未闭合结构不崩溃，结论与LF一致。
    @Test func unicodeAndUnclosedInput() {
        let lf = "def greet(name):\n    return '中文😀'\n"
        #expect(language(lf.replacingOccurrences(of: "\n", with: "\r\n")) == "python")
        #expect(language("def f():\n    return 'a" + String(repeating: "\u{301}", count: 5_000) + "'\n") == "python")
        for text in ["<div><span>", "/* 未闭合注释 function f() {", "\"未闭合字符串 SELECT * FROM t", "((((((((", "{{{{{{", "😀👍🏽中文", "\u{0}\u{1B}[0m"] {
            _ = LanguageDetector.detect(text)
        }
        #expect(language("<div><span>") == nil)
    }

    /// 恶意长输入：单行超长标识符、大量未闭合括号与花括号，判定保持有界耗时。
    @Test func adversarialInputStaysBounded() {
        let inputs = [String(repeating: "a", count: 200_000), String(repeating: "foo(", count: 30_000), String(repeating: "a{", count: 40_000),
                      String(repeating: "for a a a a a a a a ", count: 4_000), String(repeating: "x: string ", count: 8_000),
                      String(repeating: "func a(b: c d e f g h ", count: 3_000), String(repeating: "\"'`", count: 30_000)]
        for input in inputs {
            let start = ContinuousClock.now
            _ = LanguageDetector.detect(input)
            #expect(ContinuousClock.now - start < .seconds(2), "\(input.prefix(20))")
        }
    }

    // MARK: 审查复现 R3/R4/R6–R10：完整（未截断）与可输出（verifiedLanguage）分开验证，LF与CRLF一致。

    static let reviewNegatives = [
        "{\"name\": \"Alice\"}\nPlease review the report and send it back tomorrow.",
        "{\"enabled\": True, \"value\": None}", "[{\"enabled\": True}]",
        "<?php is the opening tag used by PHP. This paragraph explains the syntax.",
        "<?php echo \"hi\"; ?>\nfunction greet(name) { return name; }",
        "let query = `\nSELECT id FROM users;\n`;", "let message = `\nSystem.out.println(\"hi\");\n`;",
        "2026-10-19 INFO SELECT id FROM users;", "PLEASE DELETE FROM THE ACCOUNT WHEN THE CUSTOMER REQUESTS IT.",
        "SELECT ALL FROM THE LIST AND SEND IT TO ME.",
        "func greet() {\n    print(\"hi\")\n}",
        "fun main() {\n    System.out.println(\"Hello\")\n}",
        "object Main {\n  def main(args: Array[String]): Unit = {\n    System.out.println(\"Hello\")\n  }\n}"]
    @Test(arguments: reviewNegatives) func reviewNegativesHaveNoLanguage(text: String) {
        for sample in [text, text.replacingOccurrences(of: "\n", with: "\r\n")] {
            let guess = LanguageDetector.detect(sample)
            #expect(guess.language == nil, "\(sample)")
            #expect(guess.complete)
            #expect(guess.verifiedLanguage == nil)
        }
    }

    static let reviewPositives: [(String, String)] = [
        ("json", "{\"name\": \"Alice\"}"),
        ("python", "def choose(x, y):\n    return x if x is not None else y\n"),
        ("yaml", "metadata:\n  description: |\n    This is a long description of the service.\n    It should stay inside the configured value.\n  name: demo\n"),
        ("yaml", "name: Build and test\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: swift test\n"),
        ("go", "func greet(name string) {\n    print(name)\n}"),
        ("go", "func add(a int, b int) int {\n    return a + b\n}"),
        ("go", "func greet() {\n    name := \"hi\"\n    print(name)\n}"),
        ("csharp", "using System;\nclass Example {\n    public int calculate(int value) { return value; }\n    String name = \"test\";\n}"),
        ("cpp", "# include <stdio.h>\nint main() { return 0; }"),
        ("xml", "<!--\n<?php\n-->\n<div>Hello</div>"),
        ("javascript", "const message = `\nSELECT * FROM users;\n`;\nconsole.log(message);"),
        ("sql", "SELECT id FROM users WHERE active = 1"), ("sql", "SELECT name FROM list"),
        ("sql", "WITH recent AS (SELECT id FROM orders)\nSELECT id FROM recent;"),
        ("sql", "DELETE FROM sessions WHERE expires_at < now();"),
        ("php", "<?php\nfunction greet($name) {\n    return \"Hi $name\";\n}\n")]
    @Test func reviewPositivesGetTheRightLanguage() {
        for (expected, text) in Self.reviewPositives {
            for sample in [text, text.replacingOccurrences(of: "\n", with: "\r\n")] {
                let guess = LanguageDetector.detect(sample)
                #expect(guess.language == expected, "\(expected): \(sample)")
                #expect(guess.verifiedLanguage == expected, "\(expected)")
            }
        }
    }

    /// 非法JSON保留为诊断候选：可展示与诊断，但不能决定扩展名或围栏；标准JSON照常输出。
    @Test func invalidJSONIsADiagnosticCandidateOnly() {
        for text in ["{\"name\": \"Alice\" \"tags\": [1, 2]}", "[\n  {\"id\": 1}\n  {\"id\": 2}\n]"] {
            let guess = LanguageDetector.detect(text)
            #expect(guess.language == "json", "\(text)")
            #expect(guess.complete)
            #expect(guess.diagnosticOnly)
            #expect(guess.verifiedLanguage == nil)
            // 详情按完整结论诊断：仍提示“合法：否”。
            #expect(ContentInspector.inspectFull(text, language: guess.complete ? guess.language : nil)?.rows.first?.value.hasPrefix("否") == true)
        }
        let valid = LanguageDetector.detect("{\"name\": \"Alice\"}")
        #expect(!valid.diagnosticOnly && valid.verifiedLanguage == "json")
    }

    /// 分析副本：跨行模板字符串、HTML注释到 `-->`、预处理指令不是 `#` 注释；行数与换行不变。
    @Test func maskFollowsStringAndCommentBoundaries() {
        let template = LanguageDetector.mask("let q = `\nSELECT id\n`;\nrun()")
        #expect(!template.contains("SELECT") && template.contains("run()"))
        #expect(template.components(separatedBy: "\n").count == 4)
        let comment = LanguageDetector.mask("<!--\n<?php\n-->\n<div>Hi</div>")
        #expect(!comment.contains("php") && comment.contains("<div>"))
        #expect(LanguageDetector.mask("# include <stdio.h>").contains("include"))
        #expect(!LanguageDetector.mask("# include this file later").contains("include"))
        #expect(LanguageDetector.mask("x = \"a\nSELECT id FROM t").contains("SELECT"))
        #expect(LanguageDetector.mask("a\r\nb") == "a\r\nb")
    }

    /// 未闭合 `[`、`](` 等Markdown链接最坏输入：16K内有界，结论与匹配语义不变。
    @Test func unclosedMarkdownLinksStayBounded() {
        var worst: [Int: Duration] = [:]
        for count in [2_000, 4_000, 8_000, 16_000] {
            for input in [String(repeating: "[", count: count), String(repeating: "[a](", count: count / 4), String(repeating: "](", count: count / 2), "# T\n" + String(repeating: "[", count: count)] {
                let start = ContinuousClock.now
                #expect(LanguageDetector.detect(input).language == nil)
                _ = ContentInspector.looksLikeMarkdown(input)
                worst[count] = max(worst[count] ?? .zero, ContinuousClock.now - start)
            }
        }
        #expect(worst[16_000]! < .milliseconds(200), "\(worst.sorted { $0.key < $1.key })")
        #expect(ContentInspector.looksLikeMarkdown("# Title\n\nSee [docs](https://example.com) and [[x](y)."))
        #expect(ContentInspector.looksLikeMarkdown("# Title\n[a](b[c d](e)"))
        #expect(!ContentInspector.looksLikeMarkdown("# Title\n[a]() and [b] (c)"))
    }
}
