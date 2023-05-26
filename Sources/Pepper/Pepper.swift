import SwiftUI
import Foundation

@available(iOS 16, *)
public struct Pepper<CellView: View, T: ObservableObject, NavigationDestination: View>: View where T: Identifiable, T: Hashable {

    @StateObject var sizeInfo = SizeInfo()
    var config: PepperConfig<CellView, T, NavigationDestination>

    public init(
        axes: ScrollAxes,
        showsIndicators: Bool = true,
        rows: Int = 1,
        cols: Int = 1,
        itemSpacing: CGFloat = 0.0,
        gridSpacing: CGFloat = 0.0,
        fullSizeItems: Bool = false,
        itemCornerRadius: CGFloat = 0.0,
        itemShadow: Bool = false,
        itemBackground: Color = .clear,
        horizontalPadding: CGFloat = 0.0,
        verticalPadding: CGFloat = 0.0,
        cellItems: [T],
        @ViewBuilder cellView: @escaping(_ t: T) -> CellView,
        onTap: ((_ t: T) -> ())? = nil,
        navigationDestination: ((_ t: T) -> NavigationDestination)? = nil
    ) {
        self.config = PepperConfig(
            axes: axes,
            showsIndicators: showsIndicators,
            rows: rows,
            cols: cols,
            itemSpacing: itemSpacing,
            gridSpacing: gridSpacing,
            fullSizeItems: fullSizeItems,
            itemCornerRadius: itemCornerRadius,
            itemShadow: itemShadow,
            itemBackground: itemBackground,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            cellItems: cellItems,
            cellView: cellView,
            onTap: onTap,
            navigationDestination: navigationDestination
        )
    }


    public var body: some View {
        SizeInfoView(sizeInfo: sizeInfo) {
            PepperGrid<CellView, T, NavigationDestination>()
                .environmentObject(sizeInfo)
                .environmentObject(config)
                .if(config.navigationDestination != nil) { view in
                    view.navigationDestination(for: T.self) { t in
                        config.navigationDestination?(t)
                    }
                }

        }
    }
}
