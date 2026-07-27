import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage("dashboardSelectedDays") private var selectedDays = 14
    @State private var hoveredUsageID: String?
    @State private var showsChartDetails = false

    private var snapshot: DashboardSnapshot {
        store.dashboardSnapshot(days: selectedDays)
    }

    private var interval: DateInterval {
        snapshot.interval
    }

    private var periodSummary: UsageSummary {
        snapshot.summary
    }

    private var dailyRows: [DailyUsage] {
        snapshot.dailyRows
    }

    private var modelRows: [ModelUsage] {
        snapshot.modelRows
    }

    private var chartSegments: [DailyChartSegment] {
        snapshot.chartSegments
    }

    private var hoveredSegment: DailyChartSegment? {
        chartSegments.first { $0.id == hoveredUsageID }
    }

    private var periodRange: String {
        let lastMoment = interval.end.addingTimeInterval(-1)
        return "\(UsageFormatting.shortDate(interval.start)) — \(UsageFormatting.shortDate(lastMoment))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let message = store.persistenceReadOnlyMessage {
                    PersistenceReadOnlyBanner(message: message)
                }
                dashboardHeader
                sourceReconciliation
                summaryCards
                usageChart
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        modelBreakdown
                        tokenComposition
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        modelBreakdown
                        tokenComposition
                    }
                }
                dailyTable
                disclaimer
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 900, minHeight: 650)
        .navigationTitle("Codex Usage Lens")
        .onChange(of: selectedDays) {
            hoveredUsageID = nil
        }
    }

    private var dashboardHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 32) {
                headerCopy
                Spacer(minLength: 16)
                periodSelector
            }

            VStack(alignment: .leading, spacing: 18) {
                headerCopy
                periodSelector
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Использование Codex")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Токены, модели и ориентировочная стоимость по публичным API-ценам")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label(periodRange, systemImage: "calendar")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var periodSelector: some View {
        VStack(alignment: .trailing, spacing: 7) {
            Text("ПЕРИОД АНАЛИЗА")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker("", selection: $selectedDays) {
                Text("7 дней").tag(7)
                Text("14 дней").tag(14)
                Text("30 дней").tag(30)
                Text("90 дней").tag(90)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Период анализа")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sourceReconciliation: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Полнота данных")
                        .font(.title3.bold())
                    Text("Официальный итог показывает масштаб, локальные записи — разбивку по дням и моделям.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(store.sourceKind.title, systemImage: "externaldrive")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help(L10n.presentation(store.sourceSubtitle))
            }

            HStack(alignment: .top, spacing: 0) {
                let accountDisplayState = DataRefreshDisplayState.resolve(
                    isRefreshing: store.isSyncingAccount,
                    hasError: store.accountSyncHasError
                )
                if let account = store.accountUsage {
                    DataStatusMetric(
                        title: "Официально за всё время",
                        value: account.summary.lifetimeTokens.map(UsageFormatting.tokens) ?? "—",
                        unit: accountDisplayState == .current
                            ? "токенов"
                            : "токенов • сохранено",
                        detail: accountDisplayState.usesOperationStatus
                            ? store.accountSyncStatus
                            : L10n.format(
                                "dashboard.updated",
                                UsageFormatting.dateTime(account.fetchedAt)
                            ),
                        icon: accountDisplayState.accountIcon(hasValue: true),
                        tint: accountDisplayState.tint(default: .usageBlue)
                    )
                } else {
                    DataStatusMetric(
                        title: "Официально за всё время",
                        value: "—",
                        unit: "токенов",
                        detail: store.accountSyncStatus,
                        icon: accountDisplayState.accountIcon(hasValue: false),
                        tint: accountDisplayState.tint(default: .usageBlue)
                    )
                }

                Divider()
                    .padding(.vertical, 3)

                if let reconciliation = store.latestReconciliation {
                    let value = reconciliation.value
                    DataStatusMetric(
                        title: L10n.format(
                            "dashboard.coverage.date",
                            UsageFormatting.shortDate(reconciliation.date)
                        ),
                        value: UsageFormatting.percent(
                            value.coverage,
                            fractionLength: 1...1
                        ),
                        unit: "локально / официально",
                        detail: L10n.format(
                            "dashboard.coverage.detail",
                            UsageFormatting.tokens(value.detailedTokens),
                            UsageFormatting.tokens(value.officialTokens)
                        ),
                        icon: "arrow.triangle.2.circlepath",
                        tint: coverageTint(value.coverage)
                    )
                } else {
                    DataStatusMetric(
                        title: "Покрытие последнего дня",
                        value: "—",
                        unit: "локально / официально",
                        detail: "Сверка появится после получения дневного итога.",
                        icon: "arrow.triangle.2.circlepath",
                        tint: .usageTeal
                    )
                }

                Divider()
                    .padding(.vertical, 3)

                let localDisplayState = DataRefreshDisplayState.resolve(
                    isRefreshing: store.isScanningLocal,
                    hasError: store.localScanHasError
                )
                DataStatusMetric(
                    title: "Локально обработано",
                    value: UsageFormatting.fullTokens(recordsCount),
                    unit: UsageFormatting.responseUnit(
                        for: recordsCount
                    ),
                    detail: localDisplayState.usesOperationStatus
                        ? store.localScanStatus
                        : "Эти записи дают детализацию графиков.",
                    icon: localDisplayState.localIcon,
                    tint: localDisplayState.tint(default: .usagePurple)
                )
                .help(L10n.presentation(store.localScanStatus))
            }
        }
        .dashboardPanel()
    }

    private var recordsCount: Int {
        store.records.count
    }

    private var summaryCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("За выбранный период")
                    .font(.title3.bold())
                Text("\(periodRange) • \(UsageFormatting.responses(periodSummary.recordCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                ],
                spacing: 14
            ) {
                DashboardMetricCard(
                    title: "Всего токенов",
                    value: UsageFormatting.tokens(periodSummary.totalTokens),
                    detail: L10n.format(
                        "dashboard.metric.exact",
                        UsageFormatting.fullTokens(periodSummary.totalTokens)
                    ),
                    icon: "sum",
                    tint: .usageBlue
                )
                DashboardMetricCard(
                    title: "Входные токены",
                    value: UsageFormatting.tokens(periodSummary.inputTokens),
                    detail: L10n.format(
                        "dashboard.metric.cached",
                        UsageFormatting.tokens(periodSummary.cachedInputTokens)
                    ),
                    icon: "arrow.down.left",
                    tint: .usageTeal
                )
                DashboardMetricCard(
                    title: "Выходные токены",
                    value: UsageFormatting.tokens(periodSummary.outputTokens),
                    detail: "Ответы модели, включая reasoning",
                    icon: "arrow.up.right",
                    tint: .usagePurple
                )
                DashboardMetricCard(
                    title: "Оценка по API-ценам",
                    value: UsageFormatting.dollars(periodSummary.apiEquivalentCost),
                    detail: periodSummary.unpricedRecords == 0
                        ? "Ориентир, не фактическое списание"
                        : L10n.format(
                            "dashboard.metric.unpriced",
                            periodSummary.unpricedRecords
                        ),
                    icon: "dollarsign",
                    tint: .usageOrange
                )
            }
        }
    }

    private var usageChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Расход токенов по дням")
                    .font(.title3.bold())
                Text(
                    L10n.string("dashboard.chart.explanation")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if dailyRows.isEmpty {
                ContentUnavailableView(
                    "Нет данных за период",
                    systemImage: "chart.bar",
                    description: Text("Импортируйте usage-файл или включите демо-данные в настройках.")
                )
                .frame(height: 280)
            } else {
                Chart(chartSegments) { segment in
                    BarMark(
                        x: .value(
                            L10n.string("Дата"),
                            segment.date,
                            unit: .day
                        ),
                        yStart: .value(
                            L10n.string("Начало"),
                            segment.lowerBound
                        ),
                        yEnd: .value(
                            L10n.string("Токены"),
                            segment.upperBound
                        )
                    )
                    .foregroundStyle(
                        by: .value(
                            L10n.string("Модель"),
                            segment.displayModel
                        )
                    )
                    .opacity(
                        hoveredUsageID == nil || hoveredUsageID == segment.id
                            ? 1
                            : 0.38
                    )
                    .cornerRadius(2)
                    .accessibilityLabel(
                        "\(segment.displayModel), \(UsageFormatting.shortDate(segment.date))"
                    )
                    .accessibilityValue(segment.accessibilityValue)
                }
                .chartForegroundStyleScale(
                    mapping: { (model: String) in ModelPalette.color(for: model) }
                )
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.primary.opacity(0.10))
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) {
                                Text(UsageFormatting.tokens(tokens))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: xAxisStride)) {
                        AxisGridLine()
                            .foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.primary.opacity(0.018))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .chartOverlay { proxy in
                    chartHoverOverlay(proxy: proxy)
                }
                .frame(height: selectedDays > 30 ? 320 : 300)

                modelLegend
                chartDetailsDisclosure
            }
        }
        .dashboardPanel()
    }

    private var xAxisStride: Int {
        if selectedDays > 30 { return 7 }
        if selectedDays > 14 { return 4 }
        return 2
    }

    private var modelLegend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 165), spacing: 10)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(modelRows) { row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(ModelPalette.color(for: row.model))
                        .frame(width: 8, height: 8)
                    Text(UsageFormatting.modelDisplayName(row.model))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(UsageFormatting.tokens(row.summary.totalTokens))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .help(
                    L10n.format(
                        "dashboard.model.help",
                        UsageFormatting.modelDisplayName(row.model),
                        UsageFormatting.fullTokens(row.summary.totalTokens),
                        UsageFormatting.dollars(row.summary.apiEquivalentCost)
                    )
                )
            }
        }
    }

    private var chartDetailSegments: [DailyChartSegment] {
        chartSegments.sorted {
            if $0.date == $1.date {
                return $0.model < $1.model
            }
            return $0.date > $1.date
        }
    }

    private var chartDetailsDisclosure: some View {
        DisclosureGroup(isExpanded: $showsChartDetails) {
            ScrollView([.horizontal, .vertical]) {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 16,
                    verticalSpacing: 7
                ) {
                    GridRow {
                        chartDetailHeader("Дата")
                        chartDetailHeader("Модель")
                        chartDetailHeader("Вход")
                        chartDetailHeader("Кэш")
                        chartDetailHeader("Запись")
                        chartDetailHeader("Выход")
                        chartDetailHeader("Всего")
                        chartDetailHeader("Оценка, USD")
                    }
                    Divider().gridCellColumns(8)

                    ForEach(chartDetailSegments) { segment in
                        GridRow {
                            Text(UsageFormatting.date(segment.date))
                            Text(segment.displayModel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            chartDetailValue(segment.summary.inputTokens)
                            chartDetailValue(segment.summary.cachedInputTokens)
                            chartDetailValue(segment.summary.cacheWriteTokens)
                            chartDetailValue(segment.summary.outputTokens)
                            chartDetailValue(
                                segment.summary.totalTokens,
                                emphasized: true
                            )
                            Text(
                                UsageFormatting.dollars(
                                    segment.summary.apiEquivalentCost
                                )
                            )
                            .monospacedDigit()
                        }
                        .font(.caption)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(segment.displayModel), \(UsageFormatting.date(segment.date))"
                        )
                        .accessibilityValue(segment.accessibilityValue)
                    }
                }
                .frame(minWidth: 790, alignment: .topLeading)
                .padding(.top, 8)
            }
            .frame(maxHeight: 260)
        } label: {
            Label("Точные данные графика", systemImage: "tablecells")
                .font(.callout.weight(.semibold))
        }
        .accessibilityIdentifier("usage-chart-details-disclosure")
        .accessibilityHint(
            "Раскрывает доступную с клавиатуры таблицу по дням и моделям"
        )
    }

    private func chartDetailHeader(_ title: String) -> some View {
        Text(L10n.string(title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func chartDetailValue(
        _ value: Int,
        emphasized: Bool = false
    ) -> some View {
        Text(UsageFormatting.fullTokens(value))
            .fontWeight(emphasized ? .semibold : .regular)
            .monospacedDigit()
    }

    private func chartHoverOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateChartHover(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            setHoveredUsageID(nil)
                        }
                    }

                if
                    let segment = hoveredSegment,
                    let plotAnchor = proxy.plotFrame,
                    let band = dayBand(for: segment.date, proxy: proxy)
                {
                    let plotFrame = geometry[plotAnchor]

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: band.width, height: plotFrame.height)
                        .offset(
                            x: plotFrame.minX + band.minimumX,
                            y: plotFrame.minY
                        )
                        .allowsHitTesting(false)

                    let placement = ChartTooltipLayout.placement(
                        tooltipWidth: ChartTooltipLayout.tooltipWidth,
                        overlayWidth: geometry.size.width,
                        bandMinimumX: plotFrame.minX + band.minimumX,
                        bandMaximumX: plotFrame.minX + band.maximumX,
                        columnTopY: columnTopY(for: segment.date, proxy: proxy),
                        plotHeight: plotFrame.height
                    )

                    UsageChartTooltip(segment: segment)
                        .frame(width: ChartTooltipLayout.tooltipWidth)
                        .offset(x: placement.x)
                        .frame(
                            width: geometry.size.width,
                            height: max(
                                plotFrame.height - 2 * ChartTooltipLayout.edgeInset,
                                0
                            ),
                            alignment: placement.alignment
                        )
                        .offset(y: plotFrame.minY + ChartTooltipLayout.edgeInset)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func updateChartHover(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotAnchor = proxy.plotFrame else {
            setHoveredUsageID(nil)
            return
        }

        let plotFrame = geometry[plotAnchor]
        guard plotFrame.contains(location) else {
            setHoveredUsageID(nil)
            return
        }

        let plotLocation = CGPoint(
            x: location.x - plotFrame.minX,
            y: location.y - plotFrame.minY
        )

        // Спрашиваем у шкалы, какой день под курсором: position(forX:) для
        // дневных баров отдаёт левый край полосы, поэтому «ближайший центр»
        // промахивался на полстолбца.
        guard let hoveredDate = proxy.value(atX: plotLocation.x, as: Date.self) else {
            setHoveredUsageID(nil)
            return
        }

        let calendar = Calendar.current
        let candidates = chartSegments.filter {
            calendar.isDate($0.date, inSameDayAs: hoveredDate)
        }
        guard !candidates.isEmpty else {
            setHoveredUsageID(nil)
            return
        }
        let targets = candidates.compactMap { segment -> ChartHoverTarget? in
            guard
                let firstY = proxy.position(forY: segment.lowerBound),
                let secondY = proxy.position(forY: segment.upperBound)
            else {
                return nil
            }
            return ChartHoverTarget(
                id: segment.id,
                minimumY: min(firstY, secondY),
                maximumY: max(firstY, secondY)
            )
        }
        setHoveredUsageID(
            ChartHoverHitTesting.segmentID(
                atY: plotLocation.y,
                targets: targets
            )
        )
    }

    /// Верхняя точка всего дневного стека в координатах области графика.
    /// По ней решаем, не закроет ли подсказка «шапку» высокого столбца.
    private func columnTopY(for date: Date, proxy: ChartProxy) -> CGFloat {
        let calendar = Calendar.current
        let top = chartSegments
            .filter { calendar.isDate($0.date, inSameDayAs: date) }
            .map(\.upperBound)
            .max()
        guard let top, let y = proxy.position(forY: top) else {
            return .greatestFiniteMagnitude
        }
        return y
    }

    /// Горизонтальные границы дневной полосы в координатах области графика.
    /// Ширину берём как расстояние до следующего дня, а положение сверяем
    /// обратным преобразованием шкалы — так подсветка совпадает с зоной hover
    /// независимо от того, отдаёт `position(forX:)` край полосы или её центр.
    private func dayBand(
        for date: Date,
        proxy: ChartProxy
    ) -> (minimumX: CGFloat, maximumX: CGFloat, width: CGFloat)? {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        guard
            let startX = proxy.position(forX: day),
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
            let endX = proxy.position(forX: nextDay)
        else {
            return nil
        }

        let width = abs(endX - startX)
        let leadingCandidate = min(startX, endX)
        for minimumX in [leadingCandidate, leadingCandidate - width / 2] {
            guard
                let midpointDate = proxy.value(atX: minimumX + width / 2, as: Date.self),
                calendar.isDate(midpointDate, inSameDayAs: day)
            else {
                continue
            }
            return (minimumX, minimumX + width, width)
        }
        return (leadingCandidate, leadingCandidate + width, width)
    }

    private func setHoveredUsageID(_ id: String?) {
        guard hoveredUsageID != id else { return }
        hoveredUsageID = id
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Модели")
                    .font(.title3.bold())
                Text("Доля каждой модели в выбранном периоде")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if modelRows.isEmpty {
                Text("Нет данных")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(modelRows) { row in
                    modelBreakdownRow(row)
                    if row.id != modelRows.last?.id {
                        Divider()
                    }
                }
            }
        }
        .dashboardPanel()
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func modelBreakdownRow(_ row: ModelUsage) -> some View {
        let maximum = max(1, modelRows.first?.summary.totalTokens ?? 1)
        let share = periodSummary.totalTokens == 0
            ? 0
            : Double(row.summary.totalTokens) / Double(periodSummary.totalTokens)
        let color = ModelPalette.color(for: row.model)

        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(UsageFormatting.modelDisplayName(row.model))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(UsageFormatting.tokens(row.summary.totalTokens))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.gradient)
                            .frame(
                                width: proxy.size.width
                                    * CGFloat(row.summary.totalTokens)
                                    / CGFloat(maximum)
                            )
                    }
            }
            .frame(height: 7)

            HStack {
                Text(UsageFormatting.percent(share))
                Spacer()
                Text(
                    L10n.format(
                        "dashboard.model.estimate",
                        UsageFormatting.dollars(
                            row.summary.apiEquivalentCost
                        )
                    )
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var tokenComposition: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Из чего состоят токены")
                    .font(.title3.bold())
                Text("Вход, кэш и выход в общем объёме")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            compositionBar

            compositionRow(
                "Вход без кэша",
                value: periodSummary.uncachedInputTokens,
                total: periodSummary.totalTokens,
                color: .usageBlue
            )
            compositionRow(
                "Кэшированный вход",
                value: periodSummary.cachedInputTokens,
                total: periodSummary.totalTokens,
                color: .usageTeal
            )
            compositionRow(
                "Запись в кэш",
                value: periodSummary.cacheWriteTokens,
                total: periodSummary.totalTokens,
                color: .usageOrange
            )
            compositionRow(
                "Выход и reasoning",
                value: periodSummary.outputTokens,
                total: periodSummary.totalTokens,
                color: .usagePurple
            )
        }
        .dashboardPanel()
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var compositionBar: some View {
        GeometryReader { proxy in
            let total = max(1, periodSummary.totalTokens)
            HStack(spacing: 2) {
                compositionBarSegment(
                    value: periodSummary.uncachedInputTokens,
                    total: total,
                    width: proxy.size.width,
                    color: .usageBlue
                )
                compositionBarSegment(
                    value: periodSummary.cachedInputTokens,
                    total: total,
                    width: proxy.size.width,
                    color: .usageTeal
                )
                compositionBarSegment(
                    value: periodSummary.cacheWriteTokens,
                    total: total,
                    width: proxy.size.width,
                    color: .usageOrange
                )
                compositionBarSegment(
                    value: periodSummary.outputTokens,
                    total: total,
                    width: proxy.size.width,
                    color: .usagePurple
                )
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }

    private func compositionBarSegment(
        value: Int,
        total: Int,
        width: CGFloat,
        color: Color
    ) -> some View {
        color
            .frame(width: max(0, width * CGFloat(value) / CGFloat(total)))
    }

    private func compositionRow(
        _ title: String,
        value: Int,
        total: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(L10n.string(title))
            Spacer()
            Text(UsageFormatting.tokens(value))
                .monospacedDigit()
            Text(
                total == 0
                    ? "0%"
                    : UsageFormatting.percent(Double(value) / Double(total))
            )
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
        .help(
            L10n.format(
                "dashboard.tokens.count",
                UsageFormatting.fullTokens(value)
            )
        )
    }

    private var dailyTable: some View {
        let rows = snapshot.dailyTotals
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Дневная детализация")
                    .font(.title3.bold())
                Text("Точные значения по каждому дню; новые даты находятся сверху.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Text("За выбранный период записей нет.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 18,
                        verticalSpacing: 9
                    ) {
                        GridRow {
                            tableHeader("Дата")
                            tableHeader("Вход")
                            tableHeader("Кэш")
                            tableHeader("Запись")
                            tableHeader("Выход")
                            tableHeader("Всего")
                            tableHeader("Оценка, USD")
                        }
                        Divider().gridCellColumns(7)
                        ForEach(rows, id: \.date) { row in
                            GridRow {
                                Text(UsageFormatting.shortDate(row.date))
                                tokenCell(row.summary.inputTokens)
                                tokenCell(row.summary.cachedInputTokens)
                                tokenCell(row.summary.cacheWriteTokens)
                                tokenCell(row.summary.outputTokens)
                                tokenCell(row.summary.totalTokens, emphasized: true)
                                Text(UsageFormatting.dollars(row.summary.apiEquivalentCost))
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                    .frame(minWidth: 760, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .dashboardPanel()
    }

    private func tableHeader(_ title: String) -> some View {
        Text(L10n.string(title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func tokenCell(_ value: Int, emphasized: Bool = false) -> some View {
        Text(UsageFormatting.fullTokens(value))
            .fontWeight(emphasized ? .semibold : .regular)
            .monospacedDigit()
    }

    private var disclaimer: some View {
        Label {
            Text(
                L10n.string("dashboard.disclaimer")
            )
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.usageBlue)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func coverageTint(_ coverage: Double) -> Color {
        let delta = abs(coverage - 1)
        if delta <= 0.05 { return .usageTeal }
        if delta <= 0.20 { return .usageOrange }
        return .usageRed
    }
}

enum DataRefreshDisplayState: Equatable {
    case current
    case refreshing
    case failed

    static func resolve(
        isRefreshing: Bool,
        hasError: Bool
    ) -> DataRefreshDisplayState {
        if isRefreshing {
            return .refreshing
        }
        if hasError {
            return .failed
        }
        return .current
    }

    var usesOperationStatus: Bool {
        self != .current
    }

    func accountIcon(hasValue: Bool) -> String {
        switch self {
        case .current:
            hasValue ? "checkmark.seal.fill" : "checkmark.seal"
        case .refreshing:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var localIcon: String {
        switch self {
        case .current:
            "externaldrive.badge.checkmark"
        case .refreshing:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    func tint(default defaultTint: Color) -> Color {
        switch self {
        case .current:
            defaultTint
        case .refreshing:
            .usageOrange
        case .failed:
            .usageRed
        }
    }
}

struct DailyChartSegment: Identifiable {
    let row: DailyUsage
    let lowerBound: Int
    let upperBound: Int

    var id: String { row.id }
    var date: Date { row.date }
    var model: String { row.model }
    var displayModel: String {
        UsageFormatting.modelDisplayName(row.model)
    }
    var summary: UsageSummary { row.summary }

    var accessibilityValue: String {
        [
            L10n.format(
                "dashboard.tokens.count",
                UsageFormatting.fullTokens(summary.totalTokens)
            ),
            L10n.format(
                "dashboard.a11y.input",
                UsageFormatting.fullTokens(summary.inputTokens)
            ),
            L10n.format(
                "dashboard.a11y.cache",
                UsageFormatting.fullTokens(summary.cachedInputTokens)
            ),
            L10n.format(
                "dashboard.a11y.cacheWrite",
                UsageFormatting.fullTokens(summary.cacheWriteTokens)
            ),
            L10n.format(
                "dashboard.a11y.output",
                UsageFormatting.fullTokens(summary.outputTokens)
            ),
            UsageFormatting.dollars(summary.apiEquivalentCost),
        ].joined(separator: ", ")
    }
}

struct ChartHoverTarget: Equatable {
    let id: String
    let minimumY: CGFloat
    let maximumY: CGFloat
}

enum ChartHoverHitTesting {
    private static let minimumThinSegmentHeight: CGFloat = 12

    /// Подсказка показывается только для сегмента под курсором: пустая часть
    /// столбца ничего не подсвечивает. Единственное послабление — сегменты
    /// тоньше `minimumThinSegmentHeight`: в стеке на миллиарды токенов модель
    /// на несколько миллионов рисуется в 1–2 пикселя, и попасть в неё иначе
    /// невозможно.
    static func segmentID(
        atY y: CGFloat,
        targets: [ChartHoverTarget]
    ) -> String? {
        guard !targets.isEmpty else { return nil }

        let thinTarget = targets
            .filter { target in
                guard height(of: target) < minimumThinSegmentHeight else { return false }
                let expansion = (minimumThinSegmentHeight - height(of: target)) / 2
                return y >= target.minimumY - expansion
                    && y <= target.maximumY + expansion
            }
            .min { lhs, rhs in
                distanceFromCenter(y, target: lhs)
                    < distanceFromCenter(y, target: rhs)
            }
        if let thinTarget {
            return thinTarget.id
        }

        return targets
            .filter { y >= $0.minimumY && y <= $0.maximumY }
            .min { height(of: $0) < height(of: $1) }?
            .id
    }

    private static func height(of target: ChartHoverTarget) -> CGFloat {
        max(0, target.maximumY - target.minimumY)
    }

    private static func distanceFromCenter(
        _ y: CGFloat,
        target: ChartHoverTarget
    ) -> CGFloat {
        abs(y - (target.minimumY + target.maximumY) / 2)
    }
}

struct ChartTooltipPlacement: Equatable {
    enum VerticalEdge {
        case top
        case bottom
    }

    let x: CGFloat
    let verticalEdge: VerticalEdge

    var alignment: Alignment {
        verticalEdge == .top ? .topLeading : .bottomLeading
    }
}

enum ChartTooltipLayout {
    static let tooltipWidth: CGFloat = 278
    static let edgeInset: CGFloat = 8
    static let columnGap: CGFloat = 12

    /// Подсказку ставим сбоку от столбца: сначала справа, если не влезает —
    /// слева. Когда график узкий и подсказка всё равно перекрывает полосу,
    /// уводим её вниз для высоких столбцов — иначе она закрывает как раз
    /// вершину, ради которой на столбец и наводят.
    static func placement(
        tooltipWidth: CGFloat,
        overlayWidth: CGFloat,
        bandMinimumX: CGFloat,
        bandMaximumX: CGFloat,
        columnTopY: CGFloat,
        plotHeight: CGFloat
    ) -> ChartTooltipPlacement {
        let rightX = bandMaximumX + columnGap
        let leftX = bandMinimumX - columnGap - tooltipWidth
        let maximumX = max(edgeInset, overlayWidth - tooltipWidth - edgeInset)

        let x: CGFloat
        if rightX <= maximumX {
            x = rightX
        } else if leftX >= edgeInset {
            x = leftX
        } else {
            x = min(max(edgeInset, rightX), maximumX)
        }

        let overlapsColumn = x < bandMaximumX && x + tooltipWidth > bandMinimumX
        let columnIsTall = columnTopY < plotHeight / 2

        return ChartTooltipPlacement(
            x: x,
            verticalEdge: overlapsColumn && columnIsTall ? .bottom : .top
        )
    }
}

private struct UsageChartTooltip: View {
    let segment: DailyChartSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ModelPalette.color(for: segment.model))
                    .frame(width: 9, height: 9)
                Text(segment.displayModel)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(UsageFormatting.shortDate(segment.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(UsageFormatting.tokens(segment.summary.totalTokens))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(
                    L10n.format(
                        "dashboard.tooltip.total",
                        UsageFormatting.fullTokens(
                            segment.summary.totalTokens
                        )
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                tooltipMetric("Вход", value: UsageFormatting.tokens(segment.summary.inputTokens))
                Spacer()
                tooltipMetric("Выход", value: UsageFormatting.tokens(segment.summary.outputTokens))
                Spacer()
                tooltipMetric(
                    "API-оценка",
                    value: UsageFormatting.dollars(segment.summary.apiEquivalentCost)
                )
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    private func tooltipMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}

private struct DataStatusMetric: View {
    let title: String
    let value: String
    let unit: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.presentation(title), systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
                .symbolVariant(.fill)
                .tint(tint)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(value)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .monospacedDigit()
                Text(L10n.presentation(unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(L10n.presentation(detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(.horizontal, 16)
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Spacer(minLength: 8)
                Text(L10n.string(title))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .monospacedDigit()
            Text(L10n.string(detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.14))
        )
    }
}

private extension View {
    func dashboardPanel() -> some View {
        padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            )
    }
}
