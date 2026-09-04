# frozen_string_literal: true

source "https://rubygems.org"

# Jekyll itself is shared by both theme builds.
gem "jekyll", "~> 4.3"

# --- Chirpy theme: the default build (.theme = chirpy) --------------------
# Isolated in its own group so the hacker-blog build can exclude it at
# runtime (BUNDLE_WITHOUT=chirpy); the gem auto-loads its assets/plugins
# whenever it is on the load path, even with `theme:` unset.
group :chirpy do
  gem "jekyll-theme-chirpy", "~> 7.6"
end

# --- classic hacker-blog fallback build (.theme = hackerblog) ------------
group :hackerblog do
  gem "jekyll-seo-tag"
  gem "jekyll-sitemap"
end

gem "html-proofer", "~> 5.0", group: :test

platforms :windows, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem "wdm", "~> 0.2.0", :platforms => [:windows]
