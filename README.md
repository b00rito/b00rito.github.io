# b00rito.github.io

Source for [b00rito factory](https://b00rito.github.io) -- a software-security
blog (iOS/macOS internals, reverse engineering, dynamic instrumentation,
fuzzing).

Built with [Jekyll](https://jekyllrb.com). The live site uses the
[Chirpy](https://github.com/cotes2020/jekyll-theme-chirpy) theme; the original
minimalist hacker-blog theme is kept as a switchable fallback (see "Switching
themes" below).

## Requirements

- Ruby 3.1-3.x (Chirpy 7.x requires `~> 3.1`; Ruby 4.x is not yet supported).
  On this machine that is the keg-only Homebrew `ruby@3.4`, which `bin/blog`
  picks up automatically. Otherwise just have a compatible Ruby first on PATH.
- Bundler (`gem install bundler`), then:

```bash
bundle install
```

## Local development

Everything goes through the `bin/blog` wrapper. It selects the Ruby, the
config file(s), and the Bundler groups for whichever theme is active:

```bash
./bin/blog serve             # preview at http://127.0.0.1:4000 (auto-reload)
./bin/blog serve --drafts    # include _drafts/
./bin/blog build             # write ./_site
```

Extra arguments pass straight through to jekyll, e.g.
`./bin/blog serve --port 5000`.

## Writing a post

Create `_posts/YYYY-MM-DD-title-with-dashes.md` with front matter:

```yaml
---
title: "Post title"
date: 2026-09-06 10:00:00 +0000
categories: [Frida]      # usually one; [A, B] means A then B
tags: [frida, ios]       # lowercase
description: One-line summary for the post list and SEO.
# pin: true              # stick to top of home
# mermaid: true          # if the post contains mermaid blocks
---
```

- Chirpy builds the table of contents automatically from the `##` / `###`
  headings; do not add a `{:toc}` block.
- Work-in-progress drafts live in `_drafts/` (no date in the filename) and
  only show with `./bin/blog serve --drafts`.
- Post images go in `assets/img/posts/<slug>/`.

There is also a `new-post` helper skill in `.claude/skills/` for scaffolding.

## Switching themes

The active theme is the single word in `.theme`:

- `chirpy` (default): the Chirpy gem theme; config is `_config.yml`.
- `hackerblog`: the classic theme vendored in `_hackerblog/`; config is
  `_config.yml` plus `_config.hackerblog.yml`.

Edit `.theme`, then re-run `./bin/blog serve` or `./bin/blog build`. A
pristine pre-migration snapshot of the hacker-blog site is on the
`backup/hacker-blog` branch.

Expected `hackerblog` build noise: one `Theme: ... got FalseClass` line and
some Dart Sass `@import` deprecation notices from the vendored
`_hackerblog/_sass`. Neither breaks the build. The `chirpy` build is clean.

## Deployment

`.github/workflows/pages-deploy.yml` builds with Chirpy
(`JEKYLL_ENV=production`), runs htmlproofer, and deploys to GitHub Pages on
every push to `master` (also runnable manually from the Actions tab). It
always builds the `chirpy` theme regardless of `.theme`.

Requires Settings -> Pages -> Source = "GitHub Actions".

## Layout

```
_config.yml               Chirpy config (the default build)
_config.hackerblog.yml    overrides for the hacker-blog fallback
.theme  bin/blog          the theme switch
_posts/  _drafts/         content
_tabs/                    Chirpy nav pages (About, Archives, ...)  Chirpy only
_data/  _plugins/         Chirpy data files / plugins             Chirpy only
_hackerblog/              the classic theme (layouts, includes, sass, pages)
assets/img/               images, avatar
```

## License

Original content is Copyright (c) 2026 b00rito, MIT License (see LICENSE).
Blog posts are also offered under CC BY 4.0. Third-party components and their
licenses are listed in NOTICE.
