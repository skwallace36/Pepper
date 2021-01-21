//
//  LoginViewModel.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/20/21.
//

import Combine
import Foundation

class LoginViewModel: ObservableObject {
    let loginNetworking = LoginNetworking()
    var subscriptions = Set<AnyCancellable>()

    @Published var loggedIn = false
    @Published var email: String = Credentials.email
    @Published var password: String = Credentials.password

    func loginButtonTouched() {
        loginNetworking.fetchToken(email: email, password: password)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case let .failure(error):
                    print("Couldn't get users: \(error)")
                case .finished: break
                }
            }) { tokenResponse in
                DispatchQueue.main.async { [weak self] in
                    NetworkController.shared.token = tokenResponse.access_token
                    self?.loggedIn = true
                }
                self.subscriptions.removeAll()
            }
            .store(in: &subscriptions)
    }

    func logoutButtonTouched() {
        loggedIn = false
    }
    
}
