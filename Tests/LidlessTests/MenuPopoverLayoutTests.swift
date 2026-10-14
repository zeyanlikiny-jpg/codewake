import AppKit
import SwiftUI
import XCTest

@MainActor
final class MenuPopoverLayoutTests: XCTestCase {
    private let measuredFooterHeight: CGFloat = 51
    private let measuredFullContentHeight: CGFloat = 940

    private struct ZeroProposalProbe: View {
        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    Color.clear.frame(height: 1_200)
                }
                .lidlessMenuScrollViewport()

                Text("Footer").frame(height: 50)
            }
            .frame(width: MenuPopoverLayout.width)
        }
    }

    func testMenuWidthAndSafeInitialBodyHeightRemainStable() {
        XCTAssertEqual(MenuPopoverLayout.width, 360)
        XCTAssertEqual(MenuPopoverLayout.legacyBodyHeight, 520)
        XCTAssertEqual(MenuPopoverLayout.safeInitialBodyHeight, 520)
    }

    func testThirtyPercentModeScalesTheWholeLegacyPanelExactly() {
        let resolved = MenuPopoverLayout.resolvedBodyHeight(
            mode: .thirtyPercentTaller,
            contentHeight: measuredFullContentHeight,
            footerHeight: measuredFooterHeight,
            screenVisibleHeight: 1_410
        )

        XCTAssertEqual(resolved, 691.3, accuracy: 0.000_1)
        XCTAssertEqual(resolved + measuredFooterHeight, 742.3, accuracy: 0.000_1)
    }

    func testThirtyPercentModeUsesSafeInitialHeightUntilFooterIsMeasured() {
        let resolved = MenuPopoverLayout.resolvedBodyHeight(
            mode: .thirtyPercentTaller,
            contentHeight: 0,
            footerHeight: 0,
            screenVisibleHeight: nil
        )

        XCTAssertEqual(resolved, MenuPopoverLayout.safeInitialBodyHeight)
    }

    func testShowAllUsesTheMeasuredNaturalContentHeight() {
        let resolved = MenuPopoverLayout.resolvedBodyHeight(
            mode: .showAll,
            contentHeight: measuredFullContentHeight,
            footerHeight: measuredFooterHeight,
            screenVisibleHeight: 1_410
        )

        XCTAssertEqual(resolved, measuredFullContentHeight)
    }

    func testCurrentScreenHeightsCanShowTheMeasuredContentInFull() {
        for screenHeight: CGFloat in [1_410, 1_050] {
            let resolved = MenuPopoverLayout.resolvedBodyHeight(
                mode: .showAll,
                contentHeight: measuredFullContentHeight,
                footerHeight: measuredFooterHeight,
                screenVisibleHeight: screenHeight
            )

            XCTAssertEqual(resolved, measuredFullContentHeight)
        }
    }

    func testSmallScreenCapsTheBodyBelowItsNaturalContentHeight() {
        let resolved = MenuPopoverLayout.resolvedBodyHeight(
            mode: .showAll,
            contentHeight: measuredFullContentHeight,
            footerHeight: measuredFooterHeight,
            screenVisibleHeight: 900
        )

        XCTAssertEqual(
            resolved,
            900 - measuredFooterHeight - MenuPopoverLayout.screenSafeMargin
        )
    }

    func testThirtyPercentModeUsesTheSameScreenCap() {
        let screenHeight: CGFloat = 700
        let resolved = MenuPopoverLayout.resolvedBodyHeight(
            mode: .thirtyPercentTaller,
            contentHeight: measuredFullContentHeight,
            footerHeight: measuredFooterHeight,
            screenVisibleHeight: screenHeight
        )

        XCTAssertEqual(
            resolved,
            screenHeight - measuredFooterHeight - MenuPopoverLayout.screenSafeMargin
        )
    }

    func testValidScreenBudgetBelowLegacyHeightStillWins() {
        let footerHeight: CGFloat = 50
        let resolved = MenuPopoverLayout.resolvedBodyHeight(
            mode: .showAll,
            contentHeight: 0,
            footerHeight: footerHeight,
            screenVisibleHeight: 500
        )

        XCTAssertEqual(resolved, 434)
        XCTAssertLessThan(resolved, MenuPopoverLayout.safeInitialBodyHeight)
    }

    func testZeroContentProposalFallsBackToLegacyBodyHeight() {
        let resolved = MenuPopoverLayout.resolvedBodyHeight(
            mode: .showAll,
            contentHeight: 0,
            footerHeight: measuredFooterHeight,
            screenVisibleHeight: 1_050
        )

        XCTAssertEqual(resolved, MenuPopoverLayout.safeInitialBodyHeight)
    }

    func testUnknownScreenDoesNotPrematurelyCapTheSafeInitialHeight() {
        let resolved = MenuPopoverLayout.resolvedBodyHeight(
            mode: .showAll,
            contentHeight: 0,
            footerHeight: measuredFooterHeight,
            screenVisibleHeight: nil
        )

        XCTAssertEqual(resolved, MenuPopoverLayout.safeInitialBodyHeight)
    }

    func testProductionViewportSurvivesAZeroHeightProposal() {
        let controller = NSHostingController(rootView: ZeroProposalProbe())

        let measured = controller.sizeThatFits(
            in: CGSize(width: MenuPopoverLayout.width, height: 0)
        )

        XCTAssertGreaterThanOrEqual(
            measured.height,
            MenuPopoverLayout.safeInitialBodyHeight + 50,
            "MenuBarExtra's initial zero-height proposal must not collapse the ScrollView."
        )
    }

    func testScreenHeightPublicationDeduplicatesSubPointNoise() {
        XCTAssertTrue(
            MenuPopoverLayout.shouldPublishScreenVisibleHeight(
                1_050,
                after: nil
            )
        )
        XCTAssertFalse(
            MenuPopoverLayout.shouldPublishScreenVisibleHeight(
                1_050.5,
                after: 1_050
            )
        )
        XCTAssertTrue(
            MenuPopoverLayout.shouldPublishScreenVisibleHeight(
                1_050.51,
                after: 1_050
            )
        )
        XCTAssertFalse(
            MenuPopoverLayout.shouldPublishScreenVisibleHeight(
                .infinity,
                after: 1_050
            )
        )
    }
}
