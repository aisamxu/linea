//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

import STTextKitPlus

open class STTextContentStorage: NSTextContentStorage {

    /// 多 range 批量替换期间先跳过逐次去重，等整批结束后统一修复一次。
    private var selectionFixDeferralDepth = 0
    private var selectionFixPending = false

    package func beginDeferringSelectionFix() {
        selectionFixDeferralDepth += 1
    }

    package func endDeferringSelectionFix() {
        precondition(selectionFixDeferralDepth > 0, "unbalanced selection fix deferral")
        selectionFixDeferralDepth -= 1

        if selectionFixDeferralDepth == 0, selectionFixPending {
            selectionFixPending = false
            fix_fixSelectionAfterChangeInCharacterRange()
        }
    }

    override open func replaceContents(in range: NSTextRange, with textElements: [NSTextElement]?) {
        assert(hasEditingTransaction, "Not called inside performEditingTransaction")

        guard let textStorage,
              let attributedTextElements = textElements?.compactMap({ $0 as? STAttributedTextElement })
        else {
            // Non-functional (FB9925647)
            super.replaceContents(in: range, with: textElements)
            assertionFailure()
            return
        }

        // Replace text and (unexpectedly) reset textSelections in
        // -[NSTextLayoutManager _fixSelectionAfterChangeInCharacterRange:changeInLength:]
        // that breaks multi cursor setup
        // Workaround: Fix _fixSelectionAfterChangeInCharacterRange nad fix selection by myself

        let replacementString = NSMutableAttributedString()
        replacementString.beginEditing()
        for attributedTextElement in attributedTextElements {
            replacementString.append(attributedTextElement.attributedString)
        }
        replacementString.endEditing()

        // set needsLayout = true
        textStorage.replaceCharacters(
            in: NSRange(range, in: self),
            with: replacementString
        )

        // endEditing updates `NSTextLayoutManager.textSelections` value
        // that behavior may be undesired in certain scenarios where change suppose to keep the selection intact (at least adjusted)
        fix_fixSelectionAfterChangeInCharacterRange()
    }

    // Fix a result of the NSTextLayoutManager._fixSelectionAfterChangeInCharacterRange
    // specifically: duplicated (identical) ranges and selections
    private func fix_fixSelectionAfterChangeInCharacterRange() {
        // 批量替换尚未结束时只记一个标记，避免 k 个 range 各做一次 O(k) 去重。
        guard selectionFixDeferralDepth == 0 else {
            selectionFixPending = true
            return
        }

        // Remove duplicated selections that are result of _fixSelectionAfterChangeInCharacterRange
        for textLayoutManager in textLayoutManagers {
            let origSelections = textLayoutManager.textSelections
            var seenSelectionKeys = Set<[NSRange]>()
            seenSelectionKeys.reserveCapacity(origSelections.count)
            var finalSelections: [NSTextSelection] = []
            finalSelections.reserveCapacity(origSelections.count)

            for selection in origSelections {
                // 用 NSRange 作为可哈希键，避免逐个 NSTextRange 做昂贵的相等比较。
                let selectionKey = selection.textRanges.map { NSRange($0, in: self) }
                guard seenSelectionKeys.insert(selectionKey).inserted else { continue }

                var seenRangeKeys = Set<NSRange>()
                seenRangeKeys.reserveCapacity(selection.textRanges.count)
                var uniqueRanges: [NSTextRange] = []
                uniqueRanges.reserveCapacity(selection.textRanges.count)
                for textRange in selection.textRanges {
                    if seenRangeKeys.insert(NSRange(textRange, in: self)).inserted {
                        uniqueRanges.append(textRange)
                    }
                }

                let selectionCopy = NSTextSelection(uniqueRanges, affinity: selection.affinity, granularity: selection.granularity)
                selectionCopy.anchorPositionOffset = selection.anchorPositionOffset
                selectionCopy.isLogical = selection.isLogical
                selectionCopy.typingAttributes = selection.typingAttributes
                finalSelections.append(selectionCopy)
            }

            textLayoutManager.textSelections = finalSelections
        }
    }

    // override func enumerateTextElements(from textLocation: NSTextLocation?, options: NSTextContentManager.EnumerationOptions = [], using block: (NSTextElement) -> Bool) -> NSTextLocation? {
    //     super.enumerateTextElements(from: textLocation, options: options, using: block)
    // }
    //
    // override func recordEditAction(in originalTextRange: NSTextRange, newTextRange: NSTextRange) {
    //     super.recordEditAction(in: originalTextRange, newTextRange: newTextRange)
    // }
}
