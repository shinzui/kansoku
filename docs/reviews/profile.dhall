-- OKF profile descriptor written by `okf profile init`.
--
-- Profile: mori://shinzui/okf-profiles/profiles/reviews (assurance.reviews).
-- Pinned to v0.20.0; requires okf 0.9.0.0 or later.
-- For upgrades, change the tag and regenerate the hash with `dhall freeze`.
-- Never hand-write a sha256 value.
let registry =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.20.0/package.dhall
        sha256:079a5b3679dccafd2070535b3d59a0ffdf28e20bf9cacfe095dca96c8012879a

in  registry.assurance.reviews
