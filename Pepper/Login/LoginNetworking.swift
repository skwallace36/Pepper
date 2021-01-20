//
//  Login.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/16/21.
//

import Combine
import Foundation

struct FetchTokenResponse: Codable {
    var access_token: String
    var token_type: String
    var expires_in: Int
    var refresh_token: String
    var created_at: Int
}

protocol LoginProtocol: class {
    var networkController: NetworkControllerProtocol { get }
    func fetchToken(email: String, password: String) -> AnyPublisher<FetchTokenResponse, Error>
}

public class LoginNetworking: LoginProtocol {
    let networkController: NetworkControllerProtocol = NetworkController.shared

    func fetchToken(email: String, password: String) -> AnyPublisher<FetchTokenResponse, Error> {
        let endpoint = Endpoint.fetchToken(email: email, password: password)
        return networkController.request(type: FetchTokenResponse.self, url: endpoint.url, headers: endpoint.headers, httpMethod: .post, token: nil)
    }
}

extension Endpoint {
    static func fetchToken(email: String, password: String) -> Endpoint {
        var parameters: [URLQueryItem] = []
        parameters.append(URLQueryItem(name: "email", value: email))
        parameters.append(URLQueryItem(name: "password", value: password))
        parameters.append(URLQueryItem(name: "grant_type", value: "password"))
        return Endpoint(path: "/oauth/token", httpMethod: .post, parameters: parameters)
    }
}
