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
    func fetchToken() -> AnyPublisher<FetchTokenResponse, Error>
}

public class LoginHandler: LoginProtocol {
    let networkController: NetworkControllerProtocol = NetworkController.shared

    func fetchToken() -> AnyPublisher<FetchTokenResponse, Error> {
        let endpoint = Endpoint.fetchToken()
        return networkController.request(type: FetchTokenResponse.self, url: endpoint.url, headers: endpoint.headers, httpMethod: .post)
    }
}
