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
        self.homeViewModel = HomeViewModel(token: loginViewModel.token)
    }

    var body: some View {
        Text("welcome")
        Button(action: {
            loginViewModel.logoutButtonTouched()
        }, label: {
            Text("Logout")
        })
    }
}
