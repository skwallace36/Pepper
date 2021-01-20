//
//  ContentView.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/16/21.
//


import Combine
import SwiftUI

struct LoginView: View {

    @ObservedObject var loginViewModel = LoginViewModel()

    var body: some View {
        VStack {
            if loginViewModel.loggedIn {
                HomeView(loginViewModel: loginViewModel)
            } else {
                TextField("email", text: $loginViewModel.email).multilineTextAlignment(.center)
                TextField("password", text: $loginViewModel.password).multilineTextAlignment(.center)
                Button(action: {
                    loginViewModel.loginButtonTouched()
                }, label: {
                    Text("Login")
                })
            }
        }.animation(.easeIn)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
    }
}
