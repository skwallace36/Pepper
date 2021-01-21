//
//  HomeViewModel.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/20/21.
//

import Combine
import Foundation

class HomeViewModel: ObservableObject {

    @Published var selectedVehicle: Vehicle? {
        didSet { fetchSelectedVehicleClimate() }
    }

    @Published var selectedVehicleClimate: ClimateStateResponse?

    let homeNetworking = HomeNetworking()
    var subscriptions = Set<AnyCancellable>()

    var fetchVehiclesResponse: FetchVehiclesResponse?
    var vechicles: [Vehicle]?

    var token: String?

    init() {
        fetchVehicles()
    }

    func fetchVehicles() {
        homeNetworking.getVehicles()
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case let .failure(error):
                    print("Couldn't get users: \(error)")
                case .finished: break
                }
            }) { vehicleResponse in
                self.vechicles = vehicleResponse.response
                DispatchQueue.main.async { [weak self] in
                    self?.selectedVehicle = vehicleResponse.response.first
                }
            }
            .store(in: &subscriptions)
    }

    func fetchSelectedVehicleClimate() {
        guard let id = selectedVehicle?.id else { return }
        homeNetworking.getClimateState(id: id)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case let .failure(error):
                    print("Couldn't get users: \(error)")
                case .finished: break
                }
            }) { climateResponse in
                DispatchQueue.main.async { [ weak self] in
                    self?.selectedVehicleClimate = climateResponse
                }
            }
            .store(in: &subscriptions)
    }

}
