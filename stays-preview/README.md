# Stays

A private iPhone app for logging the hotels we've stayed at and rating them.

- Search for a real hotel (Apple Maps), and it pulls in photos from the hotel's website, Wikipedia and Look Around.
- Each person rates Room, Sleep, Location, Service, Food & drink, Spa, Pool, Atmosphere and Value (1 to 5, or skip). Overall scores are out of 10.
- Shared through one iCloud Drive folder: each person writes only their own file, so nothing is ever overwritten.
- Widgets: Hotel Memories (a photo of a favourite stay) and Our Best Hotels.

Built with XcodeGen and fastlane. A push to `main` builds and sends to TestFlight; it also rebuilds monthly so the TestFlight copy never expires.
