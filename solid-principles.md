# SOLID Principles — Reference Guide

> Source: Robert C. Martin ("Uncle Bob") · [DigitalOcean article](https://www.digitalocean.com/community/conceptual-articles/s-o-l-i-d-the-first-five-principles-of-object-oriented-design)

SOLID is a set of five object-oriented design principles that guide building maintainable, flexible, and testable software. While originally articulated for OOP, they apply equally to Swift protocols, actors, and modules.

---

## S — Single Responsibility Principle (SRP)

> A class/type should have **one and only one reason to change**.

Every type should own exactly one concern. If you can describe two distinct "what would make this change?" answers, split it.

**In Swift:**
- A `ViewModel` handles presentation logic only — not networking or persistence.
- A `VideoRepository` handles data access only — not formatting or display.
- A `PlaybackService` manages playback state only — not UI layout.

**Smell:** A type that imports both `SwiftUI` and `Foundation`-heavy networking, persists to disk, *and* formats strings for display.

---

## O — Open/Closed Principle (OCP)

> Software entities should be **open for extension but closed for modification**.

Add new behaviour by introducing new types that conform to an existing protocol, not by editing existing logic.

**In Swift:**
```swift
// Define the abstraction (closed for modification)
protocol VideoFeedProvider {
    func fetchVideos() async throws -> [Video]
}

// Extend by adding new conforming types (open for extension)
struct RecommendedFeedProvider: VideoFeedProvider { ... }
struct SubscriptionFeedProvider: VideoFeedProvider { ... }
struct TrendingFeedProvider: VideoFeedProvider { ... }
```

A `FeedViewModel` that accepts `VideoFeedProvider` never needs editing when a new feed type is added.

---

## L — Liskov Substitution Principle (LSP)

> Every subtype must be **substitutable** for its supertype without breaking correctness.

In Swift this most commonly surfaces with protocol conformances: any type conforming to a protocol must honour the full contract, not just the method signatures.

**In Swift:**
```swift
protocol Playable {
    /// Must return duration > 0 for valid media.
    var duration: TimeInterval { get }
    func play() async
}

// Bad: AudioOnlyTrack returns 0 for duration, violating the contract.
// Good: every conforming type fully satisfies Playable's semantic contract.
```

When using `async` protocols, ensure error-throwing behaviour is consistent — a conforming type that silently swallows errors where the protocol signals throwing is an LSP violation.

---

## I — Interface Segregation Principle (ISP)

> Clients should **not be forced to implement interfaces they don't use**.

Prefer small, focused protocols over large "fat" ones. Types conform only to what they actually support.

**In Swift:**
```swift
// Bad: forces every data source to implement all methods
protocol MediaDataSource {
    func video(at index: Int) -> Video
    func playlist(at index: Int) -> Playlist
    func channel(at index: Int) -> Channel
}

// Good: segregated protocols
protocol VideoDataSource {
    func video(at index: Int) -> Video
}
protocol PlaylistDataSource {
    func playlist(at index: Int) -> Playlist
}
```

A `SearchResultsViewModel` that only shows videos conforms to `VideoDataSource` — it has no awareness of playlists.

---

## D — Dependency Inversion Principle (DIP)

> High-level modules should **not depend on low-level modules**. Both should depend on **abstractions**.

Inject dependencies through protocols/interfaces; never hardcode concrete types in initializers.

**In Swift:**
```swift
// Bad: ViewModel is tightly coupled to a specific network layer
final class SearchViewModel {
    private let client = YouTubeAPIClient() // concrete dependency
}

// Good: depend on the abstraction
protocol SearchService {
    func search(query: String) async throws -> [SearchResult]
}

@MainActor
final class SearchViewModel: ObservableObject {
    private let searchService: SearchService

    init(searchService: SearchService) {
        self.searchService = searchService
    }
}
```

This makes `SearchViewModel` testable with a mock `SearchService` and decoupled from transport details.

---

## Why SOLID Matters for This Project

| Principle | Practical benefit here |
|-----------|----------------------|
| SRP | Keeps `SmartTubeIOSCore` (Foundation-only) cleanly separated from the SwiftUI layer |
| OCP | New InnerTube client contexts (e.g. WEB, TVHTML5) add without editing existing request logic |
| LSP | Protocol-based networking (`InnerTubeClient`) allows safe substitution in tests |
| ISP | View-specific data protocols prevent SwiftUI views from importing unnecessary heavy types |
| DIP | `AuthService`, `PlayerService`, etc. are injected — making unit testing straightforward |

---

## Further Reading

- [SOLID — DigitalOcean](https://www.digitalocean.com/community/conceptual-articles/s-o-l-i-d-the-first-five-principles-of-object-oriented-design)
- [Clean Architecture — Robert C. Martin](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
