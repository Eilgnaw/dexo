<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="Dexo App Icon" />
</p>

<h1 align="center">Dexo</h1>

<p align="center">A native iOS client for Discourse forums, built with UIKit + Swift.</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/dexo/id6760928014">
    <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download on the App Store" height="50" />
  </a>
</p>

<p align="center">
  English | <a href="README.zh-CN.md">中文</a>
</p>

## Screenshots

| Home  | Topic Detail | Categories |
|:---:|:---:|:---:|
| ![Home](assets/home.png) | ![Topic Detail](assets/detail.png) | ![Categories](assets/cate.png) |


## Features

- [x] **Multi-Forum Management** — Add, switch, and remove multiple Discourse instances
- [x] **Topic Browsing** — Latest / Top topic lists with infinite scrolling
- [x] **Categories & Tags** — Browse topics by category or tag
- [x] **Topic Detail** — HTML content rendering, image viewer, code blocks, collapsible sections
- [x] **Reply & Create Topic** — Reply to topics or specific posts, publish new topics
- [x] **Notifications** — Real-time notification updates via MessageBus long-polling
- [x] **Private Messages** — View messages with unread indicators, mark as read on tap
- [x] **Secure Auth** — RSA-based Discourse User API Key authentication with Keychain storage
- [x] **Appearance** — System / Light / Dark mode with custom theme color support

## Tech Stack

| Component | Detail |
|-----------|--------|
| Language | Swift 5 |
| UI Framework | UIKit |
| Minimum Target | iOS 15.0 |
| Architecture | MVVM + `@Observable` |
| Build Tool | [Tuist](https://tuist.dev) |
| Database | SQLite ([GRDB](https://github.com/groue/GRDB.swift)) |
| Networking | [Alamofire](https://github.com/Alamofire/Alamofire) |
| Image Loading | [SDWebImage](https://github.com/SDWebImage/SDWebImage) |
| Image Viewer | [Lightbox](https://github.com/hyperoslo/Lightbox) |

## Getting Started

### Prerequisites

- Xcode 16+
- [mise](https://mise.jdx.dev) (runtime version manager)

### Build

```bash
# Install tools, fetch dependencies, and generate the Xcode project
make setup

# Re-generate the project only
make generate

# Clean
make clean
```

Open the generated `dexo.xcodeproj`, select your development team, then build and run.

## Project Structure

```
dexo/
├── Core/
│   ├── Auth/           # Auth flow, Keychain, RSA encryption
│   ├── Networking/     # DoH URLProtocol
│   ├── Observable/     # ObservableViewController base class
│   └── Settings/       # App preferences
├── Database/           # GRDB database manager & models
├── Features/
│   ├── ForumList/      # Forum list
│   ├── ForumDetail/
│   │   ├── Home/       # Latest / Top topics
│   │   ├── Categories/ # Category browsing
│   │   ├── Tags/       # Tag-based browsing
│   │   ├── Messages/   # Private messages
│   │   ├── Notifications/ # Notifications
│   │   └── TopicDetail/   # Topic detail & replies
│   └── Settings/       # Settings
├── Networking/
│   ├── DiscourseAPI.swift    # API client
│   ├── DiscourseRouter.swift # Route definitions
│   └── Models/               # API response models
└── Assets.xcassets/
```

## Related Projects

- **[Dexo Push Relay](https://github.com/Eilgnaw/dexo-push-relay)** — Stateless Web Push to APNs relay

## Links

- **[Linux.do](https://linux.do)**
