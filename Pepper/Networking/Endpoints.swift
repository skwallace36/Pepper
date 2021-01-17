//
//  Endpoints.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/16/21.
//

import Foundation

extension Endpoint {
    static func fetchToken() -> Endpoint {
        var parameters: [URLQueryItem] = []
        parameters.append(URLQueryItem(name: "email", value: Credentials.email))
        parameters.append(URLQueryItem(name: "password", value: Credentials.password))
        parameters.append(URLQueryItem(name: "grant_type", value: "password"))
        return Endpoint(path: "/oauth/token", httpMethod: "POST", parameters: parameters)
    }
}
