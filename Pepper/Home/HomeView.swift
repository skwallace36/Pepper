//
//  HomeView.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/20/21.
//

import Combine
import SwiftUI

struct HomeView: View {

    @ObservedObject var homeViewModel: HomeViewModel
    @ObservedObject var loginViewModel = LoginViewModel()

    init(loginViewModel: LoginViewModel) {
        self.loginViewModel = loginViewModel
        self.homeViewModel = HomeViewModel()
    }

    var body: some View {
        VStack {
            Text(homeViewModel.selectedVehicle?.display_name ?? "").animation(.none)
            Text("\(homeViewModel.selectedVehicleClimate?.insideTemp ?? 0.0)").animation(.none)
        }
    }
}
