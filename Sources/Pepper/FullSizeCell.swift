//
//  FullSizeCell.swift
//  
//
//  Created by stuart on 5/26/23.
//

import Foundation
import SwiftUI

public struct FullSizeCell<Content: View>: View {
    let content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        VStack(spacing: 0.0) {
            Spacer()
            HStack(spacing: 0.0) {
                Spacer()
                content()
                Spacer()
            }.contentShape(Rectangle())
            Spacer()
        }.contentShape(Rectangle())
    }
}
