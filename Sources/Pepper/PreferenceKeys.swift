//
//  File.swift
//  
//
//  Created by stuart on 5/25/23.
//

import Foundation
import SwiftUI

struct SafeAreaInsetsPreferenceKey: PreferenceKey {
    static var defaultValue: EdgeInsets = .init()
    static func reduce(value: inout EdgeInsets, nextValue: () -> EdgeInsets) {}
}

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
}
