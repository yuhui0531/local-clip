// 详情正文、高亮、识别结果与原图一次备好；面板详情与历史管理窗口共用，by AI.Coding。
import AppKit
import LocalClipCore

struct ClipDetailContent {
    var detail: ClipDetail
    /// 文件列表与纯图片不显示正文预览。
    var richPreview: NSAttributedString?
    var highlight: SyntaxHighlight?
    var inspection: ContentInspector.Inspection?
    /// 仅图片与混合内容读取原图；超过解码上限时为nil。
    var image: NSImage?
    var editable: Bool

    /// 附件检查与富文本解析在后台进行；取消时在正文解析后尽早退出，调用方仍需核对请求世代。
    /// 不显示“识别结果”的调用方传inspect=false，跳过整份内容的语言判定，by AI.Coding。
    @MainActor static func load(_ detail: ClipDetail, inspect: Bool = true) async throws -> ClipDetailContent {
        async let editable = Task.detached { detail.payload.editableText != nil }.value
        let rich = await Task.detached { () -> AttributedString in
            let result = NSMutableAttributedString(string: "")
            for (index, item) in detail.payload.items.enumerated() { if index > 0 { result.append(NSAttributedString(string: "\n")) }; result.append(RichContent.attributed(item)) }
            return AttributedString(result)
        }.value
        try Task.checkCancellation()
        let kind = detail.summary.kind
        let preview = NSAttributedString(rich)
        let showsText = kind != .image && (kind != .file || (detail.payload.fileURLs ?? []).isEmpty) && preview.length > 0
        let previewString = showsText ? preview.string : ""
        async let highlight = previewString.isEmpty ? nil : SyntaxHighlighter.detail.highlight(previewString)
        var inspection: ContentInspector.Inspection?
        if inspect, let text = detail.payload.plainText, !detail.payload.hasFileReferences {
            // “识别结果”描述整份内容，只采用完整（未截断）的结论；非法JSON候选在此给出诊断，超出判定预算时显示为文本。
            let guess = await SyntaxHighlighter.detail.guess(of: text)
            let language = guess.complete ? guess.language : nil
            inspection = await Task.detached { ContentInspector.inspectFull(text, language: language) }.value
        }
        let bytes = kind == .image || kind == .mixed ? await Task.detached { RichContent.fullImage(detail.payload) }.value : nil
        return ClipDetailContent(detail: detail, richPreview: showsText ? preview : nil, highlight: await highlight, inspection: inspection,
                                 image: bytes.flatMap(NSImage.init(data:)), editable: await editable)
    }
}
