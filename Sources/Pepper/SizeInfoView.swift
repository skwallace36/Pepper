//
//  File.swift
//  
//
//  Created by stuart on 5/25/23.
//

import SwiftUI

@available(iOS 15, *)
public struct SizeInfoView<Content: View>: View {

    @ObservedObject var sizeInfo: SizeInfo
    let content: () -> Content

    public init(
        sizeInfo: SizeInfo,
        @ViewBuilder content: @escaping () -> Content)
    {
        self.sizeInfo = sizeInfo
        self.content = content
    }

    public var body: some View {

        content().background {
            Color.clear.ignoresSafeArea().readSize {
                print($0)
                sizeInfo.viewWidth = $0.width
                sizeInfo.viewHeight = $0.height
            }.readSafeAreaInsets {
                sizeInfo.topSafeArea = $0.top
                sizeInfo.bottomSafeArea = $0.bottom
            }
        }
    }
}
