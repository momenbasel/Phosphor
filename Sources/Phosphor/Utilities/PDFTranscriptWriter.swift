import AppKit
import CoreText
import Foundation
import ImageIO

/// Writes paginated, iMessage-inspired transcript PDFs without loading a WebView
/// or holding a giant rendered document in memory. The output favors a natural
/// Messages-style conversation: metadata is tucked into the bubble as reply
/// previews, media/link cards, or tapback badges instead of being rendered as a
/// list of transcript pills after each message.
enum PDFTranscriptWriter {
    struct Attachment {
        let summary: String
        /// A resolved backup file path for image attachments. The writer creates
        /// a bounded thumbnail; non-images and unreadable files remain text cards.
        var imagePath: String? = nil
    }

    struct Entry {
        let title: String
        let subtitle: String
        var timestamp: Date = .distantPast
        let body: String
        let isFromMe: Bool
        var reactions: [String] = []
        var inlineReply: String? = nil
        var attachments: [Attachment] = []
        var linkURL: String? = nil
        var status: String? = nil
    }

    static func write(
        title: String,
        subtitle: String,
        entries: [Entry],
        to path: String,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws {
        let outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: outputURL)

        guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
            throw NSError(domain: "Phosphor", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF output file"])
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, 72 DPI
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "Phosphor", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF context"])
        }

        let margin: CGFloat = 42
        let contentWidth = mediaBox.width - (margin * 2)
        let pageHeight = mediaBox.height
        let pageBottom = pageHeight - margin
        let bubbleMaxWidth = contentWidth * 0.72
        let bubblePaddingX: CGFloat = 13
        let bubblePaddingY: CGFloat = 9
        let bubbleRadius: CGFloat = 17
        let componentGap: CGFloat = 6
        var y: CGFloat = margin
        var pageNumber = 0
        let showIncomingSenderLabels = Set(entries.filter { !$0.isFromMe && !$0.title.isEmpty }.map { $0.title }).count > 1
        let calendar = Calendar.current
        var previousMessageTimestamp: Date?

        struct BubbleCard {
            let text: NSAttributedString
            let fill: CGColor
            let accent: CGColor?
            let url: URL?
            let image: CGImage?
            let imageHeight: CGFloat
            let height: CGFloat
        }

        func beginPage() {
            context.beginPDFPage(nil)
            pageNumber += 1
            y = margin
            context.setFillColor(pageBackgroundColor)
            context.fill(mediaBox)
        }

        func endPage() {
            let footer = attributed("Page \(pageNumber)", font: .systemFont(ofSize: 9), color: secondaryTextColor, alignment: .center)
            draw(footer, in: CGRect(x: margin, y: pageHeight - margin + 18, width: contentWidth, height: 14), context: context, pageHeight: pageHeight)
            context.endPDFPage()
        }

        func ensureSpace(_ height: CGFloat) {
            if y + height > pageBottom {
                endPage()
                beginPage()
            }
        }

        func drawHeader() {
            let titleText = attributed(title, font: .systemFont(ofSize: 21, weight: .semibold), color: primaryTextColor, alignment: .center)
            let titleHeight = measuredHeight(titleText, width: contentWidth)
            draw(titleText, in: CGRect(x: margin, y: y, width: contentWidth, height: titleHeight), context: context, pageHeight: pageHeight)
            y += titleHeight + 4

            let metaText = attributed(subtitle, font: .systemFont(ofSize: 10), color: secondaryTextColor, alignment: .center)
            let metaHeight = measuredHeight(metaText, width: contentWidth)
            draw(metaText, in: CGRect(x: margin, y: y, width: contentWidth, height: metaHeight), context: context, pageHeight: pageHeight)
            y += metaHeight + 18
        }

        func drawTimestampIfNeeded(for entry: Entry) {
            defer { previousMessageTimestamp = entry.timestamp }
            guard !entry.subtitle.isEmpty else { return }
            let shouldDraw: Bool
            if let previousMessageTimestamp {
                shouldDraw = !calendar.isDate(entry.timestamp, inSameDayAs: previousMessageTimestamp)
                    || entry.timestamp.timeIntervalSince(previousMessageTimestamp) >= timestampSeparatorGap
            } else {
                shouldDraw = true
            }
            guard shouldDraw else { return }
            let meta = attributed(entry.subtitle, font: .systemFont(ofSize: 8.5), color: secondaryTextColor, alignment: .center)
            let metaHeight = measuredHeight(meta, width: contentWidth)
            ensureSpace(metaHeight + 18)
            draw(meta, in: CGRect(x: margin, y: y, width: contentWidth, height: metaHeight), context: context, pageHeight: pageHeight)
            y += metaHeight + 7
        }

        func drawRoundedRect(x: CGFloat, topY: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, fill: CGColor) {
            let rect = CGRect(x: x, y: pageHeight - topY - height, width: width, height: height)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }

        func makeCard(_ raw: String, width: CGFloat, isFromMe: Bool, accent: CGColor? = nil, url: URL? = nil) -> BubbleCard {
            let text = attributed(raw, font: .systemFont(ofSize: 9.5), color: isFromMe ? outgoingTextColor : primaryTextColor)
            let height = measuredHeight(text, width: width - 18) + 9
            return BubbleCard(
                text: text,
                fill: isFromMe ? outgoingInlineCardColor : incomingInlineCardColor,
                accent: accent,
                url: url,
                image: nil,
                imageHeight: 0,
                height: height
            )
        }

        func makeAttachmentCard(_ attachment: Attachment, width: CGFloat, isFromMe: Bool) -> BubbleCard {
            let text = attributed("📎 \(attachment.summary)", font: .systemFont(ofSize: 9.5), color: isFromMe ? outgoingTextColor : primaryTextColor)
            let captionHeight = measuredHeight(text, width: width - 18) + 9
            guard let path = attachment.imagePath,
                  let image = thumbnailImage(at: path, maxPixelSize: 1200) else {
                return BubbleCard(
                    text: text,
                    fill: isFromMe ? outgoingInlineCardColor : incomingInlineCardColor,
                    accent: nil,
                    url: nil,
                    image: nil,
                    imageHeight: 0,
                    height: captionHeight
                )
            }

            let imageWidth = max(width - 8, 1)
            let aspectHeight = imageWidth * CGFloat(image.height) / CGFloat(max(image.width, 1))
            let imageHeight = min(180, max(72, aspectHeight))
            return BubbleCard(
                text: text,
                fill: isFromMe ? outgoingInlineCardColor : incomingInlineCardColor,
                accent: nil,
                url: nil,
                image: image,
                imageHeight: imageHeight,
                height: imageHeight + captionHeight + 4
            )
        }

        func cards(for entry: Entry, width: CGFloat) -> [BubbleCard] {
            var out: [BubbleCard] = []
            if let inlineReply = entry.inlineReply, !inlineReply.isEmpty {
                out.append(makeCard("↩︎ Inline reply: \(inlineReply)", width: width, isFromMe: entry.isFromMe, accent: entry.isFromMe ? outgoingTextColor.cgColor : replyAccentColor))
            }
            if let link = entry.linkURL, let url = validHTTPURL(link) {
                out.append(makeCard("🔗 \(link)", width: width, isFromMe: entry.isFromMe, url: url))
            }
            out.append(contentsOf: entry.attachments.map { makeAttachmentCard($0, width: width, isFromMe: entry.isFromMe) })
            return out
        }

        func drawCard(_ card: BubbleCard, x: CGFloat, topY: CGFloat, width: CGFloat) {
            drawRoundedRect(x: x, topY: topY, width: width, height: card.height, radius: 11, fill: card.fill)
            if let url = card.url {
                // CGContext uses PDF page coordinates (bottom-left origin), while
                // rendering below accepts top-left coordinates.
                let annotationRect = CGRect(x: x, y: pageHeight - topY - card.height, width: width, height: card.height)
                context.setURL(url as CFURL, for: annotationRect)
            }
            if let accent = card.accent {
                context.setFillColor(accent)
                context.fill(CGRect(x: x + 7, y: pageHeight - topY - card.height + 6, width: 2, height: max(4, card.height - 12)))
            }
            var textTopY = topY + 4
            if let image = card.image {
                let availableWidth = width - 8
                let sourceWidth = CGFloat(max(image.width, 1))
                let sourceHeight = CGFloat(max(image.height, 1))
                let scale = min(availableWidth / sourceWidth, card.imageHeight / sourceHeight)
                let drawWidth = sourceWidth * scale
                let drawHeight = sourceHeight * scale
                let imageRect = CGRect(
                    x: x + 4 + ((availableWidth - drawWidth) / 2),
                    y: pageHeight - topY - 4 - ((card.imageHeight + drawHeight) / 2),
                    width: drawWidth,
                    height: drawHeight
                )
                context.saveGState()
                context.interpolationQuality = .high
                context.draw(image, in: imageRect)
                context.restoreGState()
                textTopY += card.imageHeight + 4
            }
            draw(card.text, in: CGRect(x: x + 12, y: textTopY, width: width - 20, height: card.height - (textTopY - topY) - 4), context: context, pageHeight: pageHeight)
        }

        func drawReactionBadge(_ entry: Entry, bubbleX: CGFloat, bubbleTopY: CGFloat, bubbleWidth: CGFloat) {
            guard !entry.reactions.isEmpty else { return }
            // A tapback is visual state on a bubble in Messages, not a separate
            // transcript row. Show the compact badge only, with the sender/type
            // text preserved inside it when available.
            let badgeText = attributed(entry.reactions.joined(separator: "  "), font: .systemFont(ofSize: 10, weight: .medium), color: primaryTextColor)
            let badgeTextWidth = min(180, max(24, measuredSize(badgeText, width: 180).width))
            let badgeWidth = badgeTextWidth + 14
            let badgeHeight: CGFloat = 20
            let badgeX = entry.isFromMe ? max(margin, bubbleX - badgeWidth + 12) : min(margin + contentWidth - badgeWidth, bubbleX + bubbleWidth - 12)
            let badgeY = max(margin + 2, bubbleTopY - 10)
            drawRoundedRect(x: badgeX, topY: badgeY, width: badgeWidth, height: badgeHeight, radius: 10, fill: reactionBadgeColor)
            context.setStrokeColor(reactionBadgeBorderColor)
            context.setLineWidth(0.5)
            let rect = CGRect(x: badgeX, y: pageHeight - badgeY - badgeHeight, width: badgeWidth, height: badgeHeight)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.strokePath()
            draw(badgeText, in: CGRect(x: badgeX + 7, y: badgeY + 3, width: badgeTextWidth, height: badgeHeight - 6), context: context, pageHeight: pageHeight)
        }

        func drawStatus(_ status: String?, bubbleX: CGFloat, bubbleWidth: CGFloat, isFromMe: Bool) {
            guard let status, !status.isEmpty else { return }
            let statusText = attributed(status, font: .systemFont(ofSize: 8.5), color: secondaryTextColor, alignment: isFromMe ? .right : .left)
            let width = min(bubbleWidth, max(60, measuredSize(statusText, width: bubbleWidth).width))
            let height = measuredHeight(statusText, width: width)
            let x = isFromMe ? bubbleX + bubbleWidth - width : bubbleX
            ensureSpace(height + 3)
            draw(statusText, in: CGRect(x: x, y: y, width: width, height: height), context: context, pageHeight: pageHeight)
            y += height + 3
        }

        func drawBubbleSegment(entry: Entry,
                               bubbleX: CGFloat,
                               bubbleWidth: CGFloat,
                               textWidth: CGFloat,
                               cards: [BubbleCard],
                               bodyText: NSAttributedString,
                               bodyHeight: CGFloat,
                               bodyOffset: Int,
                               includeCards: Bool) -> Int {
            let cardHeight = includeCards ? cards.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(cards.count - 1, 0)) * componentGap : 0
            let contentGap = includeCards && !cards.isEmpty && bodyText.length > 0 ? componentGap : 0
            let bubbleHeight = bubblePaddingY + cardHeight + contentGap + bodyHeight + bubblePaddingY
            let bubbleTopY = y
            drawRoundedRect(x: bubbleX, topY: bubbleTopY, width: bubbleWidth, height: bubbleHeight, radius: bubbleRadius, fill: entry.isFromMe ? outgoingBubbleColor : incomingBubbleColor)

            var innerY = bubbleTopY + bubblePaddingY
            if includeCards {
                for card in cards {
                    drawCard(card, x: bubbleX + bubblePaddingX, topY: innerY, width: textWidth)
                    innerY += card.height + componentGap
                }
                if !cards.isEmpty { innerY -= componentGap }
                if !cards.isEmpty && bodyText.length > 0 { innerY += contentGap }
            }

            let visible = draw(
                bodyText,
                in: CGRect(x: bubbleX + bubblePaddingX, y: innerY, width: textWidth, height: bodyHeight),
                context: context,
                pageHeight: pageHeight
            )

            if bodyOffset == 0 {
                drawReactionBadge(entry, bubbleX: bubbleX, bubbleTopY: bubbleTopY, bubbleWidth: bubbleWidth)
            }
            y += bubbleHeight + 3
            return visible
        }

        func drawMessage(_ entry: Entry) throws {
            drawTimestampIfNeeded(for: entry)

            if !entry.isFromMe, showIncomingSenderLabels, !entry.title.isEmpty {
                let sender = attributed(entry.title, font: .systemFont(ofSize: 9, weight: .medium), color: secondaryTextColor)
                let senderHeight = measuredHeight(sender, width: bubbleMaxWidth)
                ensureSpace(senderHeight + 16)
                draw(sender, in: CGRect(x: margin + 6, y: y, width: bubbleMaxWidth, height: senderHeight), context: context, pageHeight: pageHeight)
                y += senderHeight + 2
            }

            let maxTextWidth = bubbleMaxWidth - (bubblePaddingX * 2)
            let cardWidthProbe = maxTextWidth
            let bubbleCards = cards(for: entry, width: cardWidthProbe)
            let textColor = entry.isFromMe ? outgoingTextColor : primaryTextColor
            let visibleBody = entry.body.isEmpty && bubbleCards.isEmpty ? "[Empty message]" : entry.body
            let text = attributed(visibleBody,
                                  font: .systemFont(ofSize: 11.5),
                                  color: textColor)
            let preferredBodyWidth = measuredSize(text, width: maxTextWidth).width
            let preferredCardWidth = bubbleCards.reduce(CGFloat(0)) { max($0, measuredSize($1.text, width: maxTextWidth).width + 20) }
            let textWidth = min(maxTextWidth, max(86, ceil(max(preferredBodyWidth, preferredCardWidth))))
            let bubbleWidth = textWidth + (bubblePaddingX * 2)
            let bubbleX = entry.isFromMe ? margin + contentWidth - bubbleWidth : margin

            var offset = 0
            var includeCards = true
            repeat {
                try cancellationCheck?()
                let remaining = text.attributedSubstring(from: NSRange(location: offset, length: text.length - offset))
                let cardHeight = includeCards ? bubbleCards.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(bubbleCards.count - 1, 0)) * componentGap : 0
                let cardsAndPadding = bubblePaddingY + cardHeight + (includeCards && !bubbleCards.isEmpty && remaining.length > 0 ? componentGap : 0) + bubblePaddingY

                var availableBodyHeight = pageBottom - y - cardsAndPadding
                if availableBodyHeight < 24 {
                    endPage()
                    beginPage()
                    availableBodyHeight = pageBottom - y - cardsAndPadding
                }

                let remainingHeight = measuredHeight(remaining, width: textWidth)
                let segmentBodyHeight = min(remainingHeight, availableBodyHeight)
                ensureSpace(cardsAndPadding + segmentBodyHeight)
                let visible = drawBubbleSegment(
                    entry: entry,
                    bubbleX: bubbleX,
                    bubbleWidth: bubbleWidth,
                    textWidth: textWidth,
                    cards: bubbleCards,
                    bodyText: remaining,
                    bodyHeight: segmentBodyHeight,
                    bodyOffset: offset,
                    includeCards: includeCards
                )
                if visible <= 0 { break }
                offset += visible
                includeCards = false
                if offset < text.length {
                    endPage()
                    beginPage()
                }
            } while offset < text.length

            drawStatus(entry.status, bubbleX: bubbleX, bubbleWidth: bubbleWidth, isFromMe: entry.isFromMe)
            y += 6
        }

        beginPage()
        drawHeader()

        for entry in entries {
            try cancellationCheck?()
            try drawMessage(entry)
        }

        endPage()
        context.closePDF()
    }

    private static let pageBackgroundColor = NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.976, alpha: 1).cgColor
    private static let primaryTextColor = NSColor(calibratedWhite: 0.08, alpha: 1)
    private static let secondaryTextColor = NSColor(calibratedWhite: 0.48, alpha: 1)
    private static let outgoingTextColor = NSColor.white
    private static let outgoingBubbleColor = NSColor(calibratedRed: 0.00, green: 0.478, blue: 1.00, alpha: 1).cgColor
    private static let incomingBubbleColor = NSColor(calibratedRed: 0.898, green: 0.898, blue: 0.918, alpha: 1).cgColor
    private static let outgoingInlineCardColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
    private static let incomingInlineCardColor = NSColor(calibratedWhite: 1, alpha: 0.62).cgColor
    private static let reactionBadgeColor = NSColor.white.cgColor
    private static let reactionBadgeBorderColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor
    private static let replyAccentColor = NSColor(calibratedWhite: 0.62, alpha: 1).cgColor
    private static let timestampSeparatorGap: TimeInterval = 30 * 60

    private static func validHTTPURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    /// Decode a bounded first-frame thumbnail instead of materializing a full-size
    /// backup-controlled image in memory. ImageIO also applies HEIC/JPEG orientation.
    private static func thumbnailImage(at path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    private static func attributed(_ raw: String,
                                   font: NSFont,
                                   color: NSColor,
                                   alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        paragraph.alignment = alignment
        return NSAttributedString(
            string: raw,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func measuredSize(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: text.length),
            nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height) + 2)
    }

    private static func measuredHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        max(measuredSize(text, width: width).height, 12)
    }

    @discardableResult
    private static func draw(_ text: NSAttributedString, in topLeftRect: CGRect, context: CGContext, pageHeight: CGFloat) -> Int {
        context.saveGState()
        let rect = CGRect(
            x: topLeftRect.origin.x,
            y: pageHeight - topLeftRect.origin.y - topLeftRect.height,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
        let path = CGPath(rect: rect, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
        CTFrameDraw(frame, context)
        let visible = CTFrameGetVisibleStringRange(frame).length
        context.restoreGState()
        return visible
    }
}
