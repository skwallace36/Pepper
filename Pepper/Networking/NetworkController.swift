//
//  NetworkingAPI.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/16/21.
//

import Combine
import Foundation

enum RequestType: String {
    case post = "POST"
    case get = "GET"
}

protocol NetworkControllerProtocol: class {
    typealias Headers = [String: Any]
    func request<T>(type: T.Type, url: URL, headers: Headers, httpMethod: RequestType, token: String?) -> AnyPublisher<T, Error> where T: Decodable
}

final class NetworkController: NetworkControllerProtocol {

    static let shared = NetworkController()

    func request<T: Decodable>(type: T.Type, url: URL, headers: Headers, httpMethod: RequestType = .get, token: String?) -> AnyPublisher<T, Error> {
        var urlRequest = URLRequest(url: url)
        if let token = token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        headers.forEach { (key, value) in
            if let value = value as? String {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        urlRequest.httpMethod = httpMethod.rawValue
        return URLSession.shared.dataTaskPublisher(for: urlRequest)
            .map(\.data)
            .decode(type: T.self, decoder: JSONDecoder())
            .eraseToAnyPublisher()
    }
}

