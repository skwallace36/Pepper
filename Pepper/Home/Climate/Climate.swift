//
//  ClimateEndpoints.swift
//  Pepper
//
//  Created by Stuart Wallace on 1/20/21.
//

import Combine
import Foundation


extension HomeNetworking {
    func getClimateState(id: Int) -> AnyPublisher<ClimateStateResponse, Error> {
        let endpoint = Endpoint.fetchClimateState(id: id)
        return networkController.request(type: ClimateStateResponse.self, url: endpoint.url, headers: endpoint.headers, httpMethod: endpoint.httpMethod)
    }
}

extension Endpoint {
    static func fetchClimateState(id: Int) -> Endpoint {
        Endpoint(path: "/api/1/vehicles/\(id)/data_request/climate_state", httpMethod: .get, parameters: [])
    }
}

struct ClimateStateResponse: Codable {
    let insideTemp: Double?
    let driverTempSetting, passengerTempSetting: Double
//    let leftTempDirection, rightTempDirection: JSONNull?
    let isFrontDefrosterOn, isRearDefrosterOn: Bool
    let fanStatus: Int
    let isClimateOn: Bool
    let minAvailTemp, maxAvailTemp: Int
    let seatHeaterLeft, seatHeaterRight, seatHeaterRearLeft, seatHeaterRearRight: Bool
    let seatHeaterRearCenter: Bool
    let seatHeaterRearRightBack, seatHeaterRearLeftBack: Int
    let batteryHeater: Bool
//    let batteryHeaterNoPower: JSONNull?
    let steeringWheelHeater, wiperBladeHeater, sideMirrorHeaters, isPreconditioning: Bool
    let smartPreconditioning: Bool
//    let isAutoConditioningOn: JSONNull?
    let timestamp: Int

    enum CodingKeys: String, CodingKey {
        case insideTemp = "inside_temp"
//        case outsideTemp = "outside_temp"
        case driverTempSetting = "driver_temp_setting"
        case passengerTempSetting = "passenger_temp_setting"
//        case leftTempDirection = "left_temp_direction"
//        case rightTempDirection = "right_temp_direction"
        case isFrontDefrosterOn = "is_front_defroster_on"
        case isRearDefrosterOn = "is_rear_defroster_on"
        case fanStatus = "fan_status"
        case isClimateOn = "is_climate_on"
        case minAvailTemp = "min_avail_temp"
        case maxAvailTemp = "max_avail_temp"
        case seatHeaterLeft = "seat_heater_left"
        case seatHeaterRight = "seat_heater_right"
        case seatHeaterRearLeft = "seat_heater_rear_left"
        case seatHeaterRearRight = "seat_heater_rear_right"
        case seatHeaterRearCenter = "seat_heater_rear_center"
        case seatHeaterRearRightBack = "seat_heater_rear_right_back"
        case seatHeaterRearLeftBack = "seat_heater_rear_left_back"
        case batteryHeater = "battery_heater"
//        case batteryHeaterNoPower = "battery_heater_no_power"
        case steeringWheelHeater = "steering_wheel_heater"
        case wiperBladeHeater = "wiper_blade_heater"
        case sideMirrorHeaters = "side_mirror_heaters"
        case isPreconditioning = "is_preconditioning"
        case smartPreconditioning = "smart_preconditioning"
//        case isAutoConditioningOn = "is_auto_conditioning_on"
        case timestamp
    }
}
