//
//  File.swift
//  
//
//  Created by stuart on 5/25/23.
//

import Foundation
import SwiftUI

extension View {
    func readSize(onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { geometryProxy in
                Color.clear.preference(key: SizePreferenceKey.self, value: geometryProxy.size)
            }
        ).onPreferenceChange(SizePreferenceKey.self, perform: onChange)
    }
}

extension View {
    func readSafeAreaInsets(onChange: @escaping (EdgeInsets) -> Void) -> some View {
        background(
            GeometryReader { geometryProxy in
                Color.clear.preference(key: SafeAreaInsetsPreferenceKey.self, value: geometryProxy.safeAreaInsets)
            }
        ).onPreferenceChange(SafeAreaInsetsPreferenceKey.self, perform: onChange)
    }
}

extension View {
    /// Apply view modifier if the condition is `true`
    /// - Parameters:
    ///   - condition: The condition to evaluate.
    ///   - transform: The transform to apply to the source `View`.
    /// - Returns: Either the original `View` or the modified `View` if the condition is `true`.
    @ViewBuilder func `if`<Content: View>(_ condition: @autoclosure () -> Bool, transform: (Self) -> Content) -> some View {
        if condition() {
            transform(self)
        } else {
            self
        }
    }
}
