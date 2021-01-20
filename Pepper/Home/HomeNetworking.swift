//
//  HomeNetworking.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/20/21.
//

import Combine
import Foundation

struct FetchVehiclesResponse: Codable {
    let response: [Vehicles]
    let count: Int
}

struct Vehicles: Codable {
    let id: Double
//    let vehicleID: Int
//    let vin, displayName, optionCodes: String
//    let color: String?
//    let tokens: [String]
//    let state: String
//    let inService: Bool
//    let idS: String
//    let calendarEnabled: Bool
//    let apiVersion: Int
//    let backseatToken, backseatTokenUpdatedAt: String?

//    enum CodingKeys: String, CodingKey {
//        case id
//        case vehicleID = "vehicle_id"
//        case vin
//        case displayName = "display_name"
//        case optionCodes = "option_codes"
//        case color, tokens, state
//        case inService = "in_service"
//        case idS = "id_s"
//        case calendarEnabled = "calendar_enabled"
//        case apiVersion = "api_version"
//        case backseatToken = "backseat_token"
//        case backseatTokenUpdatedAt = "backseat_token_updated_at"
//    }
}

protocol HomeProtocol: class {
    var networkController: NetworkControllerProtocol { get }
    func getVehicles(token: String?) -> AnyPublisher<FetchVehiclesResponse, Error>
}

public class HomeNetworking: HomeProtocol {
    let networkController: NetworkControllerProtocol = NetworkController.shared

    func getVehicles(token: String?) -> AnyPublisher<FetchVehiclesResponse, Error> {
        let endpoint = Endpoint.fetchVehicles()
        return networkController.request(type: FetchVehiclesResponse.self, url: endpoint.url, headers: endpoint.headers, httpMethod: endpoint.httpMethod, token: token)
    }
}

extension Endpoint {
    static func fetchVehicles() -> Endpoint {
        return Endpoint(path: "/api/1/vehicles", httpMethod: .get, parameters: [])
    }
}
