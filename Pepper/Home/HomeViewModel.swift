//
//  HomeViewModel.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/20/21.
//

import Combine

class HomeViewModel: ObservableObject {
    let homeHandler = HomeNetworking()
    var subscriptions = Set<AnyCancellable>()

    var fetchVehiclesResponse: FetchVehiclesResponse?

    init(token: String?) {
        fetchVehicles(token: token)
    }

    func fetchVehicles(token: String?) {
        homeHandler.getVehicles(token: token)
        .sink(receiveCompletion: { (completion) in
            switch completion {
            case let .failure(error):
                print("Couldn't get users: \(error)")
            case .finished: break
            }
        }) { vehicleResponse in
            print(vehicleResponse)
        }
        .store(in: &subscriptions)
    }
}
