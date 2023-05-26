//
//  PepperGrid.swift
//  
//
//  Created by stuart on 5/26/23.
//

import Foundation
import SwiftUI

@available(iOS 16, *)
public struct PepperGrid<ItemView: View, T: ObservableObject, NavigationDestination: View>: View where T: Identifiable, T: Hashable {

    @EnvironmentObject var sizeInfo: SizeInfo
    @EnvironmentObject var config: PepperConfig<ItemView, T, NavigationDestination>

    public init() { }

    public var body: some View {
        switch config.axes {
        case .Horizontal:
            ScrollView(.horizontal, showsIndicators: config.showsIndicators) {
                PepperHGrid<ItemView, T, NavigationDestination>()
                    .padding(.horizontal, config.horizontalPadding)
                    .padding(.vertical, config.verticalPadding)
            }
        case .Vertical:
            ScrollView(.vertical, showsIndicators: config.showsIndicators) {
                PepperVGrid<ItemView, T, NavigationDestination>()
                    .padding(.horizontal, config.horizontalPadding)
                    .padding(.vertical, config.verticalPadding)
            }
        }
    }
}
