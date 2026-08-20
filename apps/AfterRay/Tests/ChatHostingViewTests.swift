import AppKit
import AfterRayRecall
import SwiftUI
import XCTest
@testable import AfterRayApp

@MainActor
final class ChatHostingViewTests: XCTestCase {
    func testFullSizeTitlebarDeliversMouseClickToSwiftUIButton() {
        var clickCount = 0
        let root = VStack(spacing: 0) {
            Button {
                clickCount += 1
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea(.container, edges: .top)

        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 320, height: 180),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false

        let hosting = ChatHostingView(rootView: root)
        XCTAssertFalse(hosting.mouseDownCanMoveWindow)
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        sendClick(
            at: NSPoint(x: window.frame.width / 2, y: window.frame.height - 16),
            to: window
        )

        XCTAssertEqual(clickCount, 1)
        window.orderOut(nil)
    }

    func testChatWindowUsesOneNativeToolbarRow() throws {
        let controller = ChatWindowController()
        let toolbar = controller.makeToolbar()
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 960, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.styleMask.insert(.fullSizeContentView)
        window.orderFrontRegardless()
        controller.updateResponsiveLayout(for: window)

        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(toolbar.centeredItemIdentifiers, [])
        XCTAssertEqual(
            controller.toolbarDefaultItemIdentifiers(toolbar),
            [
                .chatSidebarToggle,
                .space,
                .space,
                .flexibleSpace,
                .chatTitle,
                .flexibleSpace,
                .chatNewConversation,
                .chatMore,
            ]
        )
        XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier == .space }.count, 2)
        XCTAssertEqual(
            toolbar.items.filter { $0.view != nil }.map(\.itemIdentifier),
            [.chatTitle]
        )

        let titleView = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier == .chatTitle }?.view
        )
        titleView.superview?.layoutSubtreeIfNeeded()
        let titleFrame = titleView.convert(titleView.bounds, to: nil)
        XCTAssertGreaterThan(titleFrame.midX, window.frame.width / 2 + 20)

        let sidebar = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier == .chatSidebarToggle }
        )
        XCTAssertEqual(sidebar.action, #selector(ChatWindowController.toggleSidebar(_:)))
        XCTAssertTrue(sidebar.target === controller)
        XCTAssertFalse(controller.sidebarState.isCollapsed)
        XCTAssertTrue(NSApp.sendAction(sidebar.action!, to: sidebar.target, from: sidebar))
        controller.updateResponsiveLayout(for: window)
        XCTAssertTrue(controller.sidebarState.isCollapsed)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier == .space })
        XCTAssertEqual(sidebar.toolTip, "Show sidebar")
        XCTAssertTrue(NSApp.sendAction(sidebar.action!, to: sidebar.target, from: sidebar))
        controller.updateResponsiveLayout(for: window)
        XCTAssertFalse(controller.sidebarState.isCollapsed)
        XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier == .space }.count, 2)
        XCTAssertEqual(sidebar.toolTip, "Hide sidebar")

        let newConversation = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier == .chatNewConversation }
        )
        XCTAssertEqual(
            newConversation.action,
            #selector(ChatWindowController.startNewConversation(_:))
        )
        XCTAssertTrue(newConversation.target === controller)

        let more = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier == .chatMore } as? NSMenuToolbarItem
        )
        XCTAssertFalse(more.showsIndicator)
        XCTAssertEqual(
            more.menu.items.map(\.title),
            [AfterRayCopy.english.chat.copyEntire]
        )
        XCTAssertGreaterThanOrEqual(titleView.fittingSize.width, 180)
        XCTAssertGreaterThanOrEqual(titleView.fittingSize.height, 28)

        window.setContentSize(
            NSSize(width: ChatWindowController.sidebarAutoCollapseWidth - 1, height: 700)
        )
        controller.updateResponsiveLayout(for: window)
        XCTAssertTrue(controller.sidebarState.isCollapsed)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier == .space })

        window.setContentSize(
            NSSize(width: ChatWindowController.sidebarAutoCollapseWidth + 1, height: 700)
        )
        controller.updateResponsiveLayout(for: window)
        XCTAssertFalse(controller.sidebarState.isCollapsed)
        XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier == .space }.count, 2)

        window.orderOut(nil)
    }

    func testManualSidebarChoiceSurvivesCompactWidthRoundTrip() throws {
        let controller = ChatWindowController()
        let toolbar = controller.makeToolbar()
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 960, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.orderFrontRegardless()
        controller.updateResponsiveLayout(for: window)

        let sidebar = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier == .chatSidebarToggle }
        )
        XCTAssertTrue(NSApp.sendAction(sidebar.action!, to: sidebar.target, from: sidebar))
        XCTAssertTrue(controller.sidebarState.isCollapsed)

        window.setContentSize(
            NSSize(width: ChatWindowController.sidebarAutoCollapseWidth - 1, height: 700)
        )
        controller.updateResponsiveLayout(for: window)
        window.setContentSize(
            NSSize(width: ChatWindowController.sidebarAutoCollapseWidth + 1, height: 700)
        )
        controller.updateResponsiveLayout(for: window)

        XCTAssertTrue(controller.sidebarState.isCollapsed)
        XCTAssertEqual(sidebar.toolTip, "Show sidebar")
        window.orderOut(nil)
    }

    private func sendClick(at location: NSPoint, to window: NSWindow) {
        for (type, number) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 2)] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else {
                XCTFail("Could not create mouse event")
                return
            }
            window.sendEvent(event)
        }
    }

}
