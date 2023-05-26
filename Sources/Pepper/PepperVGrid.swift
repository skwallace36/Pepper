//
//  PepperVGrid.swift
//  
//
//  Created by stuart on 5/26/23.
//

import Foundation
import SwiftUI

@available(iOS 16, *)
public struct PepperVGrid<CellView: View, T: ObservableObject, NavigationDestination: View>: View where T: Identifiable, T: Hashable {
    @EnvironmentObject var config: PepperConfig<CellView, T, NavigationDestination>

    var cols: [GridItem] { (0..<config.cols).map { _ in GridItem(spacing: config.itemSpacing) } }

    public var body: some View {
        LazyVGrid(columns: cols, spacing: config.gridSpacing) {
            ForEach(config.cellItems) { item in
                switch config.fullSizeItems {
                case true:
                    NavigationLink(value: item) {
                        FullSizeCell {
                            config.cellView(item)
                        }.background(config.itemBackground)
                            .cornerRadius(config.itemCornerRadius)
                            .shadow(color: .gray.opacity(0.5), radius: 2, x: 0, y: 0)

                    }.simultaneousGesture(TapGesture().onEnded {
                        config.onTap?(item)
                    })
                case false:
                    NavigationLink(value: item) {

                        config.cellView(item)
                            .background(config.itemBackground)
                            .cornerRadius(config.itemCornerRadius)
                            .shadow(color: .gray.opacity(0.5), radius: 2, x: 0, y: 0)

                    }.simultaneousGesture(TapGesture().onEnded {
                        config.onTap?(item)
                    })
                }
            }
        }
    }
}
