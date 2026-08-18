import AfterRayRecall
import SwiftUI

/// The title is the only custom view in the native toolbar. Give its text an
/// explicit inset while AppKit continues to size and highlight the controls.
struct ChatToolbarTitleView: View {
    @ObservedObject var model: AfterRayChatModel

    var body: some View {
        Text(model.selectedTitle)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(minWidth: 180, idealWidth: 360, maxWidth: 460)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
            .preferredColorScheme(.dark)
    }
}
