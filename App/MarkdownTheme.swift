import MarkdownUI
import SwiftUI

extension Theme {
    /// Markdown in the brief's ink: no coloured links, code on the card surface.
    @MainActor static let glass = Theme()
        .text {
            ForegroundColor(Ink.primary)
            FontSize(14)
        }
        .link {
            ForegroundColor(Ink.primary)
            UnderlineStyle(.single)
        }
        .strong {
            FontWeight(.semibold)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Surface.card)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 16, bottom: 8)
                .markdownTextStyle { FontWeight(.semibold); FontSize(18) }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle { FontWeight(.semibold); FontSize(16) }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle { FontWeight(.semibold); FontSize(14) }
        }
        .paragraph { configuration in
            configuration.label
                .lineSpacing(3)
                .markdownMargin(top: 0, bottom: 10)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 3)
        }
        .blockquote { configuration in
            configuration.label
                .markdownTextStyle { ForegroundColor(Ink.secondary) }
                .padding(.leading, 12)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12.5)
                        ForegroundColor(Ink.primary)
                    }
                    .padding(14)
            }
            .scrollIndicators(.never)
            .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
            .markdownMargin(top: 4, bottom: 12)
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(.init(color: .clear))
                .markdownTableBackgroundStyle(.alternatingRows(Surface.card, .clear))
                .markdownMargin(top: 4, bottom: 12)
        }
        .thematicBreak {
            Rectangle()
                .fill(Surface.card)
                .frame(height: 1)
                .markdownMargin(top: 10, bottom: 10)
        }
}
