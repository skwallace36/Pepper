//
//  HomeNetworking.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/20/21.
//

import Combine
import Foundation


protocol HomeProtocol: class {
    var networkController: NetworkControllerProtocol { get }
    func getVehicles() -> AnyPublisher<FetchVehiclesResponse, Error>
    func getClimateState(id: Int) -> AnyPublisher<ClimateStateResponse, Error>
}

public class HomeNetworking: HomeProtocol {
    let networkController: NetworkControllerProtocol = NetworkController.shared
}
