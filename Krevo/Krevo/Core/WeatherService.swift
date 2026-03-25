import Foundation

struct WeatherData: Sendable {
    let temperature: Int
    let icon: String // SF Symbol name
    let description: String
}

/// Fetches current weather for Austin, TX from Open-Meteo (free, no API key).
/// Caches results for 15 minutes to avoid excessive requests.
actor WeatherService {
    private var cached: WeatherData?
    private var lastFetch: ContinuousClock.Instant?
    private let cacheDuration: Duration = .seconds(900) // 15 minutes

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let endpoint = URL(
        string: "https://api.open-meteo.com/v1/forecast?latitude=30.2672&longitude=-97.7431&current=temperature_2m,weather_code&temperature_unit=fahrenheit&timezone=America/Chicago"
    )!

    func fetch() async throws -> WeatherData {
        // Return cache if fresh
        if let cached, let lastFetch, ContinuousClock.now - lastFetch < cacheDuration {
            return cached
        }

        let (data, _) = try await session.data(from: Self.endpoint)
        let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        let weatherData = WeatherData(
            temperature: Int(response.current.temperature_2m.rounded()),
            icon: Self.sfSymbol(for: response.current.weather_code),
            description: Self.weatherDescription(for: response.current.weather_code)
        )

        cached = weatherData
        lastFetch = .now
        return weatherData
    }

    // MARK: - WMO Weather Code → SF Symbol

    private static func sfSymbol(for code: Int) -> String {
        switch code {
        case 0:
            return "sun.max.fill"
        case 1, 2:
            return "cloud.sun.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55, 56, 57:
            return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67:
            return "cloud.rain.fill"
        case 71, 73, 75, 77:
            return "cloud.snow.fill"
        case 80, 81, 82:
            return "cloud.heavyrain.fill"
        case 85, 86:
            return "cloud.snow.fill"
        case 95, 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return "cloud.fill"
        }
    }

    private static func weatherDescription(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Foggy"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67: return "Rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }
}

// MARK: - Open-Meteo Response

private struct OpenMeteoResponse: Decodable {
    let current: Current

    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
    }
}
