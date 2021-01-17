//
//  ContentView.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/16/21.
//


import Combine
import SwiftUI

struct ContentView: View {
    var body: some View {
        let loginHandler = LoginHandler()
        var subscriptions = Set<AnyCancellable>()
        Button(action: {
            loginHandler.fetchToken()
                .sink(receiveCompletion: { (completion) in
                    switch completion {
                    case let .failure(error):
                        print("Couldn't get users: \(error)")
                    case .finished: break
                    }
                }) { users in
                    print(users)
                }
                .store(in: &subscriptions)
        }, label: {
            Text("Button")
        })
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
