//
//  Vehicle.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/20/21.
//

import Combine
import Foundation

extension HomeNetworking {

    func getVehicles() -> AnyPublisher<FetchVehiclesResponse, Error> {
        let endpoint = Endpoint.fetchVehicles()
        return networkController.request(type: FetchVehiclesResponse.self, url: endpoint.url, headers: endpoint.headers, httpMethod: endpoint.httpMethod)
    }
}

struct FetchVehiclesResponse: Codable {
    let response: [Vehicle]
    let count: Int
}

struct Vehicle: Codable {
    let id: Int
    let vin: String
    let display_name: String
}


extension Endpoint {
    static func fetchVehicles() -> Endpoint {
        Endpoint(path: "/api/1/vehicles", httpMethod: .get, parameters: [])
    }
}
