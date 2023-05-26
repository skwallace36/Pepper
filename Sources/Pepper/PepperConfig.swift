//
//  File.swift
//  
//
//  Created by stuart on 5/26/23.
//

import Foundation
import SwiftUI

public class PepperConfig<CellView: View, T: ObservableObject, NavigationDestination: View>: ObservableObject {
    @Published var axes: ScrollAxes
    @Published var showsIndicators: Bool
    @Published var rows: Int
    @Published var cols: Int
    @Published var itemSpacing: CGFloat
    @Published var gridSpacing: CGFloat
    @Published var fullSizeItems: Bool
    @Published var itemCornerRadius: CGFloat
    @Published var itemShadow: Bool
    @Published var itemBackground: Color
    @Published var horizontalPadding: CGFloat
    @Published var verticalPadding: CGFloat
    @Published var cellItems: [T]
    let cellView: (_ t: T) -> CellView
    let onTap: ((_ t: T) -> ())?
    let navigationDestination: ((_ t: T) -> NavigationDestination)?

    public init(
        axes: ScrollAxes,
        showsIndicators: Bool,
        rows: Int = 1,
        cols: Int = 1,
        itemSpacing: CGFloat,
        gridSpacing: CGFloat,
        fullSizeItems: Bool,
        itemCornerRadius: CGFloat,
        itemShadow: Bool,
        itemBackground: Color,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        cellItems: [T],
        @ViewBuilder cellView: @escaping(_ t: T) -> CellView,
        onTap: ((_ t: T) -> ())?,
        navigationDestination:  ((_ t: T) -> NavigationDestination)?
    ) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.rows = rows
        self.cols = cols
        self.itemSpacing = itemSpacing
        self.gridSpacing = gridSpacing
        self.fullSizeItems = fullSizeItems
        self.itemShadow = itemShadow
        self.itemCornerRadius = itemCornerRadius
        self.itemBackground = itemBackground
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.cellItems = cellItems
        self.cellView = cellView
        self.onTap = onTap
        self.navigationDestination = navigationDestination
    }
}
