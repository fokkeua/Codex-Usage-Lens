import Testing

@testable import CodexUsageMenuBar

@Test("Тонкий сегмент графика получает минимальную hover-зону")
func chartHoverExpandsThinSegments() {
    let targets = [
        ChartHoverTarget(id: "large", minimumY: 100, maximumY: 240),
        ChartHoverTarget(id: "thin", minimumY: 96, maximumY: 98),
    ]

    #expect(
        ChartHoverHitTesting.segmentID(atY: 93, targets: targets) == "thin"
    )
    #expect(
        ChartHoverHitTesting.segmentID(atY: 160, targets: targets) == "large"
    )
    // Ниже нижней границы столбца подсказки уже нет.
    #expect(
        ChartHoverHitTesting.segmentID(atY: 242, targets: targets) == nil
    )
}

@Test("Пустая часть столбца не показывает подсказку")
func chartHoverIgnoresEmptyColumnSpace() {
    let targets = [
        ChartHoverTarget(id: "top", minimumY: 100, maximumY: 160),
        ChartHoverTarget(id: "bottom", minimumY: 160, maximumY: 280),
    ]

    // Курсор высоко над коротким столбиком.
    #expect(
        ChartHoverHitTesting.segmentID(atY: 12, targets: targets) == nil
    )
    // Курсор ниже столбца.
    #expect(
        ChartHoverHitTesting.segmentID(atY: 295, targets: targets) == nil
    )
    // Внутри сегментов подсказка остаётся.
    #expect(
        ChartHoverHitTesting.segmentID(atY: 120, targets: targets) == "top"
    )
    #expect(
        ChartHoverHitTesting.segmentID(atY: 200, targets: targets) == "bottom"
    )
    #expect(
        ChartHoverHitTesting.segmentID(atY: 120, targets: []) == nil
    )
}

@Test("Граница сегментов отдаёт более тонкий сегмент")
func chartHoverPrefersThinnerSegmentOnBoundary() {
    let targets = [
        ChartHoverTarget(id: "tall", minimumY: 40, maximumY: 280),
        ChartHoverTarget(id: "short", minimumY: 20, maximumY: 40),
    ]

    #expect(
        ChartHoverHitTesting.segmentID(atY: 40, targets: targets) == "short"
    )
}

@Test("Подсказка встаёт справа от столбца, когда есть место")
func chartTooltipPrefersRightSide() {
    let placement = ChartTooltipLayout.placement(
        tooltipWidth: 278,
        overlayWidth: 900,
        bandMinimumX: 200,
        bandMaximumX: 300,
        columnTopY: 20,
        plotHeight: 300
    )

    #expect(placement.x == 312)
    #expect(placement.verticalEdge == .top)
}

@Test("Без места справа подсказка переезжает влево от столбца")
func chartTooltipFlipsToLeftSide() {
    let placement = ChartTooltipLayout.placement(
        tooltipWidth: 278,
        overlayWidth: 700,
        bandMinimumX: 420,
        bandMaximumX: 560,
        columnTopY: 20,
        plotHeight: 300
    )

    #expect(placement.x == 130)
    #expect(placement.verticalEdge == .top)
}

@Test("Высокий столбец в узком графике уводит подсказку вниз")
func chartTooltipMovesBelowTallColumn() {
    // Средний столбец на графике из трёх дней: места нет ни справа, ни слева.
    let placement = ChartTooltipLayout.placement(
        tooltipWidth: 278,
        overlayWidth: 700,
        bandMinimumX: 233,
        bandMaximumX: 466,
        columnTopY: 30,
        plotHeight: 300
    )

    #expect(placement.x == 414)
    #expect(placement.verticalEdge == .bottom)
}

@Test("Низкий столбец оставляет подсказку сверху")
func chartTooltipStaysAboveShortColumn() {
    let placement = ChartTooltipLayout.placement(
        tooltipWidth: 278,
        overlayWidth: 700,
        bandMinimumX: 233,
        bandMaximumX: 466,
        columnTopY: 260,
        plotHeight: 300
    )

    #expect(placement.verticalEdge == .top)
}
