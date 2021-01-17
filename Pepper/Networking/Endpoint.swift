//
//  Endpoint.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/16/21.
//

import Foundation

struct Endpoint {
    var path: String
    var httpMethod: String
    var headers: [String: Any] { ["Content-Type": "application/json", "User-Agent": "Pepper Tesla App"] }
    var parameters: [URLQueryItem]
    var queryItems: [URLQueryItem] { parameters + alwaysIncludeParameters }
    var alwaysIncludeParameters: [URLQueryItem] = {
        let clientSecret = "c7257eb71a564034f9419ee651c7d0e5f7aa6bfbd18bafb5c5c033b093bb2fa3"
        let clientId = "81527cff06843c8634fdc09e8ac0abefb46ac849f38fe1e431c2ef2106796384"
        var items: [URLQueryItem] = []
        items.append(.init(name: "client_secret", value: clientSecret))
        items.append(.init(name: "client_id", value: clientId))
        return items
    }()
}

extension Endpoint {
    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "owner-api.teslamotors.com"
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { preconditionFailure("Invalid URL components: \(components)") }
        return url
    }
}
