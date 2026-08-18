# License map

The repository-level [`LICENSE`](../LICENSE) applies to every file that does
not carry a more specific license notice or live below a directory with its own
license.

| Scope | License |
| --- | --- |
| AfterRay application, daemon, developer CLI, storage, models, UI, site, and documentation | FSL-1.1-ALv2 |
| [`swift-markdown-ui`](https://github.com/gonzalezreal/swift-markdown-ui) (chat Markdown renderer, pulled by `AfterRayRecall`) | MIT — see [MarkdownUI-MIT.txt](MarkdownUI-MIT.txt) |
| [`NetworkImage`](https://github.com/gonzalezreal/NetworkImage) (MarkdownUI transitive; chat never uses its loader) | MIT — see [NetworkImage-MIT.txt](NetworkImage-MIT.txt) |
| [`swift-cmark`](https://github.com/swiftlang/swift-cmark) (MarkdownUI transitive GFM parser) | BSD-2-Clause (plus Houdini MIT in the upstream COPYING) |
| [`crates/afterray-protocol`](../crates/afterray-protocol) | Apache-2.0 |
| Future public SDK packages | Apache-2.0, declared in each package |
| Future official AfterRay Agent Skills | MIT, declared in each Skill directory |

No current file is licensed under MIT solely because MIT is listed as the
planned license for future Agent Skills. Each such Skill will include its own
license when it is published.
