//
//  File.swift
//  
//
//  Created by stuart on 5/26/23.
//

import Foundation

public class SizeInfo: ObservableObject {
    @Published var viewWidth: CGFloat = 0.0
    @Published var viewHeight: CGFloat = 0.0
    @Published var topSafeArea: CGFloat = 0.0
    @Published var bottomSafeArea: CGFloat = 0.0
}
